#!/bin/bash
# MRC ZK->KRaft Migration with Dynamic Quorum (True Multi-Cluster, Secured)
# Region 1 (central) -> my-cluster cluster (3 ZK, 2 brokers, 3 controllers)
# Region 2 (east)    -> my-clusterdev cluster (2 ZK, 2 brokers, 3 controllers)
# Total: 5 ZK nodes (odd for quorum), 4 Kafka brokers, 6 KRaft controllers
#
# Security: TLS (secretRef) + SASL/PLAIN + Digest (ZK) + RBAC with OAuth MDS (Keycloak)
#
# Steps:
#   step1  - Deploy ZooKeeper on both clusters
#   step2  - Deploy Kafka with ZK dependency on both clusters
#   step3  - Deploy bootstrap ConfigMap + RBAC for dynamic quorum
#   step4  - Deploy KRaftController with dynamic quorum on both clusters
#   step5  - Create KRaftMigrationJob on both clusters
#   step6  - Monitor migration (poll KMJ status)
#   step7  - Promote observers to voters during DUAL_WRITE
#   step8  - Finalize migration
#   step9  - Switch Kafka from ZK to KRaft dependency
#   step10 - Verify and decommission ZooKeeper

set -e

# ============================================================
# Configuration
# ============================================================
REGION1_NS="${REGION1_NS:-central}"
REGION2_NS="${REGION2_NS:-east}"
REGION1_CONTEXT="${REGION1_CONTEXT:-<your-region1-k8s-context>}"
REGION2_CONTEXT="${REGION2_CONTEXT:-<your-region2-k8s-context>}"
KRAFTCONTROLLER_NAME="${KRAFTCONTROLLER_NAME:-kraftcontroller}"
KAFKA_NAME="${KAFKA_NAME:-kafka}"
TEST_TOPIC="migration-test"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="my-domain.example.com"

# Admin command config — KRaft's kafka.properties only has listener-level configs
# (listener.name.controller.sasl.*) which admin clients don't read. We need global
# client configs (security.protocol, sasl.mechanism, ssl.truststore.*).
create_admin_config() {
    local kube_fn="$1"
    local pod="$2"
    local namespace="$3"

    $kube_fn exec "$pod" -n "$namespace" -- bash -c '
cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
cat /mnt/admin-config/security.properties >> /tmp/admin.properties
' 2>/dev/null
}

KRAFT_CMD_CONFIG="/tmp/admin.properties"

# ============================================================
# Colors + helpers
# ============================================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }
echo_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

run_cmd() {
    echo ""
    echo -e "${BLUE}  \$ $*${NC}"
    echo -en "${YELLOW}  Run? [Y/n]${NC} > "
    read -r REPLY
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo_info "  Skipped."
        return 0
    fi
    "$@"
}

show_cmd() {
    echo -e "${BLUE}  \$ $*${NC}"
    echo -e "${YELLOW}  Running...${NC}"
    "$@"
}

ask_step() {
    while true; do
        read -p "$1 (y/n): " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

# Helpers: kubectl scoped to each cluster
kube1() { kubectl --context "$REGION1_CONTEXT" "$@"; }
kube2() { kubectl --context "$REGION2_CONTEXT" "$@"; }

# ============================================================
# Usage
# ============================================================
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "MRC ZK->KRaft Migration with Dynamic Quorum"
    echo "True multi-cluster: my-cluster (central) + my-clusterdev (east)"
    echo "Security: TLS + SASL/PLAIN + Digest (ZK) + RBAC with OAuth MDS (Keycloak)"
    echo ""
    echo "Commands:"
    echo "  (no args)    Run all steps sequentially (interactive)"
    echo "  step1        Deploy ZooKeeper on both clusters"
    echo "  step2        Deploy Kafka with ZK dependency on both clusters"
    echo "  step3        Deploy bootstrap ConfigMap + RBAC for dynamic quorum"
    echo "  step4        Deploy KRaftController on both clusters"
    echo "  step5        Create KRaftMigrationJob on both clusters"
    echo "  step6        Monitor migration progress"
    echo "  step7        Promote observers to voters during DUAL_WRITE"
    echo "  step8        Finalize migration"
    echo "  step9        Switch Kafka from ZK to KRaft dependency"
    echo "  step10       Verify and decommission ZooKeeper"
    echo "  status       Show cluster status on both clusters"
    echo ""
    echo "Typical flow:"
    echo "  ./pre-setup.sh          # One-time: namespaces, certs, secrets, Keycloak, operator"
    echo "  ./setup.sh              # Runs all steps interactively"
    echo "  ./cleanup.sh            # Phased teardown"
    echo ""
    exit 1
}

# ============================================================
# Health check helpers
# ============================================================
ensure_admin_configs() {
    create_admin_config "kube1" "${KRAFTCONTROLLER_NAME}-0" "$REGION1_NS"
    create_admin_config "kube2" "${KRAFTCONTROLLER_NAME}-0" "$REGION2_NS"
}

get_kraft_version() {
    echo_info "kraft.version (trying both regions — leader may be in either):"
    ensure_admin_configs
    local output
    output=$(kube1 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION1_NS" -- \
        kafka-features --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" describe 2>/dev/null) && {
        echo "$output" | grep kraft.version
        return
    }
    output=$(kube2 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION2_NS" -- \
        kafka-features --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" describe 2>/dev/null) && {
        echo "$output" | grep kraft.version
        return
    }
    echo "  (unable to retrieve kraft.version from either region)"
}

get_quorum_status() {
    echo_info "Quorum status (trying both regions):"
    kube1 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION1_NS" -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" \
        describe --status 2>/dev/null && return
    kube2 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION2_NS" -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" \
        describe --status 2>/dev/null && return
    echo "  (unable to retrieve quorum status from either region)"
}

get_replication_info() {
    echo_info "Quorum replication info (trying both regions):"
    kube1 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION1_NS" -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" \
        describe --replication 2>/dev/null && return
    kube2 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION2_NS" -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" \
        describe --replication 2>/dev/null && return
    echo "  (unable to retrieve replication info from either region)"
}

# Create a client properties file on a Kafka pod for secure produce/consume
create_kafka_client_config() {
    local kube_fn="$1"
    local pod="$2"
    local namespace="$3"

    $kube_fn exec "$pod" -n "$namespace" -- bash -c "
cat > /tmp/client.properties <<'CLIENTEOF'
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"kafka\" password=\"kafka-secret\";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
ssl.truststore.type=PKCS12
CLIENTEOF
" 2>/dev/null
}

# Data validation: produce/consume on Region 1 Kafka
KAFKA_EXTERNAL_BOOTSTRAP="kafka-central-ext.${DOMAIN}:9092"

validate_data() {
    local phase_label="$1"
    local topic="${TEST_TOPIC}-${phase_label}-$(date +%s)"
    local msg="phase=${phase_label},ts=$(date +%s)"

    echo_info "=== Data Validation ($phase_label) ==="

    create_kafka_client_config "kube1" "${KAFKA_NAME}-0" "$REGION1_NS"

    echo_info "Creating topic '$topic'..."
    kube1 exec "${KAFKA_NAME}-0" -n "$REGION1_NS" -- \
        kafka-topics --bootstrap-server "$KAFKA_EXTERNAL_BOOTSTRAP" \
        --command-config /tmp/client.properties \
        --create --topic "$topic" --partitions 3 --replication-factor 2 \
        2>/dev/null || true

    echo_info "Producing message: $msg"
    kube1 exec "${KAFKA_NAME}-0" -n "$REGION1_NS" -- \
        bash -c "echo '${msg}' | kafka-console-producer --bootstrap-server ${KAFKA_EXTERNAL_BOOTSTRAP} \
        --producer.config /tmp/client.properties --topic ${topic}" 2>/dev/null

    echo_info "Consuming messages from '$topic'..."
    CONSUMED=$(kube1 exec "${KAFKA_NAME}-0" -n "$REGION1_NS" -- \
        kafka-console-consumer --bootstrap-server "$KAFKA_EXTERNAL_BOOTSTRAP" \
        --consumer.config /tmp/client.properties \
        --topic "$topic" --from-beginning --timeout-ms 10000 2>/dev/null) || true

    if echo "$CONSUMED" | grep -q "$phase_label"; then
        echo_info "Data validation passed — produced and consumed successfully"
    else
        echo_warn "Could not verify message consumption (may need more time)"
    fi

    local count
    count=$(echo "$CONSUMED" | grep -c "phase=" 2>/dev/null) || count=0
    echo_info "Total messages consumed: $count"
    echo ""
}

# ============================================================
# Step 1: Deploy ZooKeeper
# ============================================================
step1() {
    echo_step "=== Step 1: Deploy ZooKeeper (3 per region, 6 total) ==="
    echo ""
    echo "This will:"
    echo "  - Deploy ZooKeeper with TLS (autoGeneratedCerts) + digest auth"
    echo "  - 3 nodes per region, cross-cluster peers via LoadBalancer DNS"
    echo ""

    echo_info "Deploying ZooKeeper in Region 1 (my-cluster)..."
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/zookeeper.yaml"

    echo_info "Deploying ZooKeeper in Region 2 (my-clusterdev)..."
    run_cmd kube2 apply -f "$SCRIPT_DIR/region2/resources/zookeeper.yaml"

    echo_info "Waiting for ZooKeeper in Region 1..."
    run_cmd kube1 wait --for=condition=platform.confluent.io/cluster-ready \
        zookeeper/zookeeper -n "$REGION1_NS" --timeout=10m
    echo_info "Waiting for ZooKeeper in Region 2..."
    run_cmd kube2 wait --for=condition=platform.confluent.io/cluster-ready \
        zookeeper/zookeeper -n "$REGION2_NS" --timeout=10m

    # Verify ZK DNS
    echo ""
    echo_info "Checking ZooKeeper DNS (external-dns must sync LB IPs)..."
    run_cmd "$SCRIPT_DIR/check-dns-sync.sh"

    echo_info "Step 1 complete. ZooKeeper cluster running on both clusters."
}

# ============================================================
# Step 2: Deploy Kafka (ZK dependency)
# ============================================================
step2() {
    echo_step "=== Step 2: Deploy Kafka with ZK Dependency (2 per region, 4 total) ==="
    echo ""
    echo "This will:"
    echo "  - Deploy Kafka with ZooKeeper dependency"
    echo "  - Security: TLS + SASL/PLAIN + RBAC + OAuth MDS (Keycloak)"
    echo "  - IBP 3.9 annotation for dynamic quorum compatibility"
    echo ""

    echo_info "Deploying Kafka in Region 1 (my-cluster)..."
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/kafka.yaml"

    echo_info "Deploying Kafka in Region 2 (my-clusterdev)..."
    run_cmd kube2 apply -f "$SCRIPT_DIR/region2/resources/kafka.yaml"

    echo_info "Waiting for Kafka in Region 1..."
    run_cmd kube1 wait --for=condition=platform.confluent.io/cluster-ready \
        kafka/kafka -n "$REGION1_NS" --timeout=10m
    echo_info "Waiting for Kafka in Region 2..."
    run_cmd kube2 wait --for=condition=platform.confluent.io/cluster-ready \
        kafka/kafka -n "$REGION2_NS" --timeout=10m

    # Verify Kafka DNS
    echo ""
    echo_info "Checking Kafka DNS (external-dns must sync LB IPs)..."
    run_cmd "$SCRIPT_DIR/check-dns-sync.sh"

    if ask_step "Run produce/consume health check?"; then
        validate_data "step2-zk"
    fi

    echo_info "Step 2 complete. Kafka running on ZooKeeper on both clusters."
}

# ============================================================
# Step 3: Deploy Bootstrap ConfigMap + RBAC
# ============================================================
step3() {
    echo_step "=== Step 3: Deploy Dynamic Quorum Bootstrap ConfigMap + RBAC ==="
    echo ""
    echo "This will:"
    echo "  - Create ConfigMap to track bootstrap formatting status"
    echo "  - Create ServiceAccount + RBAC for KRaftController to update ConfigMap"
    echo "  - Only needed in Region 1 (bootstrapPod is in Region 1)"
    echo ""

    echo_info "Deploying ConfigMap and RBAC in Region 1..."
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/bootstrap-configmap.yaml"
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/rbac.yaml"

    echo_info "Step 3 complete. Bootstrap ConfigMap and RBAC created (Region 1 only — observers don't need it)."
}

# ============================================================
# Step 4: Deploy KRaftController
# ============================================================
step4() {
    echo_step "=== Step 4: Deploy KRaftController (3 per region, 6 total, Dynamic Quorum) ==="
    echo ""
    echo "This will:"
    echo "  - Deploy KRaftController with dynamic quorum on both clusters"
    echo "  - Region 1: bootstrapPod=0 (starts the quorum)"
    echo "  - Region 2: observer (joins quorum started by Region 1)"
    echo "  - Held via kraft-migration-hold-krc-creation annotation until KMJ triggers"
    echo ""
    echo "IMPORTANT: If redeploying, reset the ConfigMap first:"
    echo "  kubectl --context $REGION1_CONTEXT patch configmap kraftcontroller-dynamic-quorum -n $REGION1_NS \\"
    echo "    --type='json' -p='[{\"op\": \"replace\", \"path\": \"/data/bootstrap-status\", \"value\": \"{\\\"bootstrap_formatted\\\":false}\"}]'"
    echo ""

    echo_info "Deploying KRaftController in Region 1 (my-cluster)..."
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/kraftcontroller.yaml"

    echo_info "Deploying KRaftController in Region 2 (my-clusterdev)..."
    run_cmd kube2 apply -f "$SCRIPT_DIR/region2/resources/kraftcontroller.yaml"

    echo_info "Step 4 complete. KRaftControllers deployed (holding for migration job)."
}

# ============================================================
# Step 5: Create KRaftMigrationJob
# ============================================================
step5() {
    echo_step "=== Step 5: Create KRaftMigrationJob (one region at a time) ==="
    echo ""
    echo "IMPORTANT: Apply KRaftMigrationJob one region at a time and wait for each"
    echo "region's broker rolls to complete before proceeding to the next."
    echo "Triggering multiple regions simultaneously can cause brokers holding"
    echo "replicas of the same partition to restart at the same time."
    echo ""
    echo "Wait for each region to reach MIGRATE phase with subphase"
    echo "MigrateMonitorMigrationProgress before applying the next."
    echo ""

    echo_info "Creating KRaftMigrationJob in Region 1 (my-cluster)..."
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/kraftmigrationjob.yaml"

    echo_info "Waiting for Region 1 to reach MIGRATE/MigrateMonitorMigrationProgress..."
    echo_info "Monitor: kubectl --context $REGION1_CONTEXT get kmj kraftmigrationjob -n $REGION1_NS -w -oyaml"
    if ! ask_step "Has Region 1 reached MIGRATE/MigrateMonitorMigrationProgress? Proceed to Region 2?"; then
        echo_info "Paused. Re-run 'step5' when ready to continue."
        return 0
    fi

    echo_info "Creating KRaftMigrationJob in Region 2 (my-clusterdev)..."
    run_cmd kube2 apply -f "$SCRIPT_DIR/region2/resources/kraftmigrationjob.yaml"

    echo_info "Step 5 complete. KRaftMigrationJobs created on both clusters."
    echo_info "Once Region 2 completes broker rolls, both regions will transition to DUAL-WRITE."
}

# ============================================================
# Step 6: Monitor Migration
# ============================================================
step6() {
    echo_step "=== Step 6: Monitor Migration Progress ==="
    echo ""
    echo "Migration will go through: SETUP -> MIGRATE -> DUAL_WRITE"
    echo "Polling both regions every 15s..."
    echo ""

    if ask_step "Poll KRaftMigrationJob status until DUAL_WRITE?"; then
        echo_info "Polling every 15s... (Ctrl+C to stop, re-run to continue)"
        while true; do
            PHASE1=$(kube1 get kraftmigrationjob kraftmigrationjob -n "$REGION1_NS" \
                -o jsonpath='{.status.phase}' 2>/dev/null)
            SUBPHASE1=$(kube1 get kraftmigrationjob kraftmigrationjob -n "$REGION1_NS" \
                -o jsonpath='{.status.subPhase}' 2>/dev/null)
            PHASE2=$(kube2 get kraftmigrationjob kraftmigrationjob -n "$REGION2_NS" \
                -o jsonpath='{.status.phase}' 2>/dev/null)
            SUBPHASE2=$(kube2 get kraftmigrationjob kraftmigrationjob -n "$REGION2_NS" \
                -o jsonpath='{.status.subPhase}' 2>/dev/null)

            echo_info "Region 1: Phase=$PHASE1 SubPhase=$SUBPHASE1 | Region 2: Phase=$PHASE2 SubPhase=$SUBPHASE2"

            if [[ "$PHASE1" == "DUAL_WRITE" && "$PHASE2" == "DUAL_WRITE" ]]; then
                echo_info "Both regions reached DUAL_WRITE phase!"
                break
            fi
            if [[ "$PHASE1" == "FAILED" || "$PHASE1" == "ERROR" || "$PHASE2" == "FAILED" || "$PHASE2" == "ERROR" ]]; then
                echo_error "Migration failed! Check:"
                echo "  kubectl --context $REGION1_CONTEXT describe kraftmigrationjob kraftmigrationjob -n $REGION1_NS"
                echo "  kubectl --context $REGION2_CONTEXT describe kraftmigrationjob kraftmigrationjob -n $REGION2_NS"
                break
            fi
            sleep 15
        done
    else
        echo_info "Skipped polling. Check manually:"
        echo "  kubectl --context $REGION1_CONTEXT get kraftmigrationjob -n $REGION1_NS"
        echo "  kubectl --context $REGION2_CONTEXT get kraftmigrationjob -n $REGION2_NS"
    fi
}

# ============================================================
# Step 7: Verify and Promote Observers
# ============================================================
step7() {
    echo_step "=== Step 7: Verify kraft.version and Promote Observers ==="
    echo ""
    echo "In DUAL_WRITE phase, kraftcontroller-0 in region1 is a voter (bootstrap)."
    echo "All other controllers are observers. Promote them to voters."
    echo ""

    if ask_step "Check kraft.version and quorum status?"; then
        ensure_admin_configs
        get_kraft_version
        echo ""
        get_quorum_status
        echo ""
        get_replication_info
    fi

    echo ""
    echo_info "Promoting observers to voters..."
    echo "  Region 1: kraftcontroller-1 and kraftcontroller-2"
    echo "  Region 2: kraftcontroller-0, kraftcontroller-1, and kraftcontroller-2"
    echo ""

    # Region 1: promote kraftcontroller-1 and kraftcontroller-2
    for i in 1 2; do
        if ask_step "Promote Region 1 kraftcontroller-${i} to voter?"; then
            create_admin_config "kube1" "${KRAFTCONTROLLER_NAME}-${i}" "$REGION1_NS"
            echo_info "Promoting ${KRAFTCONTROLLER_NAME}-${i} in Region 1..."
            run_cmd kube1 exec "${KRAFTCONTROLLER_NAME}-${i}" -n "$REGION1_NS" -- \
                kafka-metadata-quorum --bootstrap-controller \
                kraft-central0.${DOMAIN}:9074 \
                --command-config "$KRAFT_CMD_CONFIG" \
                add-controller
        fi
    done

    # Region 2: promote all 3
    for i in 0 1 2; do
        if ask_step "Promote Region 2 kraftcontroller-${i} to voter?"; then
            create_admin_config "kube2" "${KRAFTCONTROLLER_NAME}-${i}" "$REGION2_NS"
            echo_info "Promoting ${KRAFTCONTROLLER_NAME}-${i} in Region 2..."
            run_cmd kube2 exec "${KRAFTCONTROLLER_NAME}-${i}" -n "$REGION2_NS" -- \
                kafka-metadata-quorum --bootstrap-controller \
                kraft-central0.${DOMAIN}:9074 \
                --command-config "$KRAFT_CMD_CONFIG" \
                add-controller
        fi
    done

    echo ""
    if ask_step "Verify all controllers are voters?"; then
        ensure_admin_configs
        echo_info "Quorum status after promotion:"
        get_quorum_status
        echo ""
        get_replication_info
    fi
}

# ============================================================
# Step 8: Finalize Migration
# ============================================================
step8() {
    echo_step "=== Step 8: Finalize Migration (KRaft takes over from ZooKeeper) ==="
    echo ""
    echo "IMPORTANT: Finalize one region at a time. Wait for each region to reach"
    echo "COMPLETE before proceeding to the next. Finalization is irreversible —"
    echo "once ZooKeeper is removed from a region's brokers, that region cannot"
    echo "roll back to ZooKeeper mode."
    echo ""
    echo "Ensure all 6 controllers are voters before finalizing!"
    echo ""

    if ask_step "Finalize migration on Region 1?"; then
        echo_info "Finalizing Region 1..."
        run_cmd kube1 annotate kraftmigrationjob kraftmigrationjob -n "$REGION1_NS" \
            platform.confluent.io/kraft-migration-trigger-finalize-to-kraft='true'

        echo_info "Waiting for Kafka to be ready in Region 1..."
        run_cmd kube1 wait --for=condition=platform.confluent.io/cluster-ready \
            kafka/kafka -n "$REGION1_NS" --timeout=10m

        echo_info "Region 1 finalization complete."
        echo_info "Monitor: kubectl --context $REGION1_CONTEXT get kmj kraftmigrationjob -n $REGION1_NS -oyaml"
    fi

    if ! ask_step "Has Region 1 reached COMPLETE? Proceed to finalize Region 2?"; then
        echo_info "Paused. Re-run 'step8' when ready to continue."
        return 0
    fi

    if ask_step "Finalize migration on Region 2?"; then
        echo_info "Finalizing Region 2..."
        run_cmd kube2 annotate kraftmigrationjob kraftmigrationjob -n "$REGION2_NS" \
            platform.confluent.io/kraft-migration-trigger-finalize-to-kraft='true'

        echo_info "Waiting for Kafka to be ready in Region 2..."
        run_cmd kube2 wait --for=condition=platform.confluent.io/cluster-ready \
            kafka/kafka -n "$REGION2_NS" --timeout=10m

        echo_info "Migration finalized on both clusters."
    fi
}

# ============================================================
# Step 9: Switch Kafka from ZK to KRaft Dependency
# ============================================================
step9() {
    echo_step "=== Step 9: Switch Kafka Dependency from ZooKeeper to KRaft ==="
    echo ""
    echo "This will:"
    echo "  - Apply kafka-kraft-dependency.yaml on both clusters"
    echo "  - Kafka switches from ZK to KRaft dependency"
    echo ""

    if ask_step "Switch Kafka to KRaft dependency on both clusters?"; then
        echo_info "Switching Region 1 Kafka to KRaft dependency..."
        run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/kafka-kraft-dependency.yaml"

        echo_info "Switching Region 2 Kafka to KRaft dependency..."
        run_cmd kube2 apply -f "$SCRIPT_DIR/region2/resources/kafka-kraft-dependency.yaml"

        echo_info "Waiting for Kafka in Region 1..."
        run_cmd kube1 wait --for=condition=platform.confluent.io/cluster-ready \
            kafka/kafka -n "$REGION1_NS" --timeout=10m
        echo_info "Waiting for Kafka in Region 2..."
        run_cmd kube2 wait --for=condition=platform.confluent.io/cluster-ready \
            kafka/kafka -n "$REGION2_NS" --timeout=10m

        echo_info "Kafka now depends on KRaft on both clusters."
    fi
}

# ============================================================
# Step 10: Verify and Decommission ZooKeeper
# ============================================================
step10() {
    echo_step "=== Step 10: Verify and Decommission ZooKeeper ==="
    echo ""

    if ask_step "Verify kraft.version and quorum status?"; then
        ensure_admin_configs
        get_kraft_version
        echo ""
        get_quorum_status
        echo ""
        get_replication_info
    fi

    echo ""
    if ask_step "Run produce/consume data validation?"; then
        validate_data "step10-post-migration"
    fi

    echo ""
    if ask_step "Decommission ZooKeeper on both clusters?"; then
        echo_warn "Deleting ZooKeeper in Region 1..."
        run_cmd kube1 delete zookeeper zookeeper -n "$REGION1_NS" --timeout=5m
        echo_warn "Deleting ZooKeeper in Region 2..."
        run_cmd kube2 delete zookeeper zookeeper -n "$REGION2_NS" --timeout=5m
        echo_info "ZooKeeper decommissioned on both clusters."
    fi
}

# ============================================================
# Show status
# ============================================================
show_status() {
    echo_step "=== Cluster Status ==="
    echo ""

    echo_info "=== Region 1 ($REGION1_NS on my-cluster) ==="
    echo_info "ZooKeeper:"
    show_cmd kube1 get zookeeper zookeeper -n "$REGION1_NS" 2>/dev/null || echo_warn "ZooKeeper not found"
    echo ""
    echo_info "Kafka:"
    show_cmd kube1 get kafka kafka -n "$REGION1_NS" 2>/dev/null || echo_warn "Kafka not found"
    echo ""
    echo_info "KRaftController:"
    show_cmd kube1 get kraftcontroller "$KRAFTCONTROLLER_NAME" -n "$REGION1_NS" 2>/dev/null || echo_warn "KRaftController not found"
    echo ""
    echo_info "KRaftMigrationJob:"
    show_cmd kube1 get kraftmigrationjob -n "$REGION1_NS" 2>/dev/null || echo_warn "KRaftMigrationJob not found"
    echo ""
    echo_info "Pods:"
    show_cmd kube1 get pods -n "$REGION1_NS" -o wide 2>/dev/null || echo_warn "No pods found"
    echo ""

    echo_info "=== Region 2 ($REGION2_NS on my-clusterdev) ==="
    echo_info "ZooKeeper:"
    show_cmd kube2 get zookeeper zookeeper -n "$REGION2_NS" 2>/dev/null || echo_warn "ZooKeeper not found"
    echo ""
    echo_info "Kafka:"
    show_cmd kube2 get kafka kafka -n "$REGION2_NS" 2>/dev/null || echo_warn "Kafka not found"
    echo ""
    echo_info "KRaftController:"
    show_cmd kube2 get kraftcontroller "$KRAFTCONTROLLER_NAME" -n "$REGION2_NS" 2>/dev/null || echo_warn "KRaftController not found"
    echo ""
    echo_info "KRaftMigrationJob:"
    show_cmd kube2 get kraftmigrationjob -n "$REGION2_NS" 2>/dev/null || echo_warn "KRaftMigrationJob not found"
    echo ""
    echo_info "Pods:"
    show_cmd kube2 get pods -n "$REGION2_NS" -o wide 2>/dev/null || echo_warn "No pods found"
    echo ""

    echo_info "=== Quorum ==="
    ensure_admin_configs
    get_kraft_version
    echo ""
    get_quorum_status
    echo ""
    get_replication_info
}

# ============================================================
# Run all steps sequentially
# ============================================================
run_all() {
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  MRC ZK->KRaft Migration Setup${NC}"
    echo -e "${BLUE}  (True Multi-Cluster, Secured)${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo ""
    echo "This script guides you through ZK-to-KRaft migration with full security."
    echo "Each step is interactive — you can skip steps already completed."
    echo ""
    echo "Security:"
    echo "  - TLS: secretRef (Kafka, KRaft), autoGeneratedCerts (ZK)"
    echo "  - Auth: SASL/PLAIN (Kafka, KRaft) + Digest (ZK)"
    echo "  - RBAC: Kafka + KRaft"
    echo "  - MDS: OAuth (Keycloak)"
    echo ""

    step1
    step2
    step3
    step4
    step5
    step6
    step7
    step8
    step9
    step10

    echo ""
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}  Migration Complete!${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo ""
    echo "Final state:"
    echo "  - Kafka: 4 brokers (2+2) on KRaft (dynamic quorum)"
    echo "  - KRaftController: 6 voters (3+3)"
    echo "  - ZooKeeper: decommissioned"
    echo ""
    echo "Verification:"
    echo "  ./setup.sh status"
    echo "  ./quorum-status.sh"
    echo ""
    echo "Cleanup:"
    echo "  ./cleanup.sh"
    echo ""
}

# ============================================================
# Main
# ============================================================
COMMAND="${1:-}"

case "$COMMAND" in
    step1)   step1 ;;
    step2)   step2 ;;
    step3)   step3 ;;
    step4)   step4 ;;
    step5)   step5 ;;
    step6)   step6 ;;
    step7)   step7 ;;
    step8)   step8 ;;
    step9)   step9 ;;
    step10)  step10 ;;
    status)  show_status ;;
    "")      run_all ;;
    -h|--help|help) usage ;;
    *)       echo_error "Unknown command: $COMMAND"; usage ;;
esac
