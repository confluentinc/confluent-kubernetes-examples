#!/bin/bash
# MRC Static→Dynamic Quorum Migration (True Multi-Cluster, Secured)
# Region 1 (central) -> my-cluster cluster (3 controllers, 2 brokers)
# Region 2 (east)    -> my-clusterdev cluster (3 controllers, 2 brokers)
# Total: 6 controllers (static quorum), quorum needs 4
#
# Security: TLS (secretRef) + SASL/PLAIN + RBAC with OAuth MDS (Keycloak)
#
# Phases (Path C — confirmed with KRaft team):
#   phase0  - Deploy static quorum cluster (kraft.version=0) on both clusters
#   phase1  - Add advertisedListenersEnabled on KRaft (rolling restart, needs manual-roll)
#   phase2  - Upgrade kraft.version=0 → 1
#   phase3  - KRaft: switch voters → bootstrap.servers (add dynamicQuorumConfig)
#   phase4  - Kafka: force roll to pick up bootstrap.servers from KRaft dependency
#   verify  - Prove dynamic quorum works (remove + re-add controller)

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
# This function creates /tmp/admin.properties on a pod with the right config.
create_admin_config() {
    local kube_fn="$1"
    local pod="$2"
    local namespace="$3"

    # Copy server properties (has node.id, process.roles, log.dirs needed for add-controller)
    # then append mounted security config (persists across restarts via ConfigMap)
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

# Helpers: kubectl scoped to each cluster
kube1() { kubectl --context "$REGION1_CONTEXT" "$@"; }
kube2() { kubectl --context "$REGION2_CONTEXT" "$@"; }

# ============================================================
# Usage
# ============================================================
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "MRC Static→Dynamic Quorum Migration (kraft.version 0 → 1)"
    echo "True multi-cluster: my-cluster (central) + my-clusterdev (east)"
    echo "Security: TLS + SASL/PLAIN + RBAC with OAuth MDS (Keycloak)"
    echo ""
    echo "Commands:"
    echo "  (no args)    Run all phases sequentially (interactive)"
    echo "  phase0       Deploy static quorum on both clusters (kraft.version=0)"
    echo "  phase1       Add advertisedListenersEnabled on KRaft (roll)"
    echo "  phase2       Upgrade kraft.version=0 → 1"
    echo "  phase3       KRaft: switch voters → bootstrap.servers (roll)"
    echo "  phase4       Kafka: force roll to pick up bootstrap.servers"
    echo "  verify       Verify dynamic quorum works (remove + re-add controller)"
    echo "  status       Show cluster status on both clusters"
    echo ""
    echo "Typical flow:"
    echo "  ./pre-setup.sh          # One-time: namespaces, certs, secrets, Keycloak, operator"
    echo "  ./setup.sh              # Runs all phases interactively"
    echo "  ./cleanup.sh            # Phased teardown"
    echo ""
    exit 1
}

# ============================================================
# Health check helpers
# ============================================================
# NOTE: All admin commands use --command-config for SASL/PLAIN + TLS authentication.
# KRaft's kafka.properties only has listener-level configs, so we create a separate
# admin config file with global client security properties on each pod before use.
# Without advertisedListenersEnabled (phase0), admin client commands
# only work from the cluster where the leader is. We try region1 first,
# Without advertisedListenersEnabled (phase0 only), admin commands may only work
# from the leader's cluster. After phase1 (advertisedListeners enabled), both work.

# Ensure admin config exists on both KRaft-0 pods
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

wait_for_kraftcontroller_ready_region1() {
    echo_info "Waiting for KRaftController to be ready in Region 1..."
    run_cmd kube1 wait --for=condition=platform.confluent.io/cluster-ready \
        kraftcontroller/"$KRAFTCONTROLLER_NAME" -n "$REGION1_NS" --timeout=10m
}

wait_for_kraftcontroller_ready_region2() {
    echo_info "Waiting for KRaftController to be ready in Region 2..."
    run_cmd kube2 wait --for=condition=platform.confluent.io/cluster-ready \
        kraftcontroller/"$KRAFTCONTROLLER_NAME" -n "$REGION2_NS" --timeout=10m
}

# Create a client properties file on a Kafka pod for secure produce/consume
# Uses SASL_SSL with the kafka superuser credentials
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
# Must use EXTERNAL listener (public DNS) — internal listener discovers cross-cluster
# brokers via internal DNS which can't resolve from this cluster.
KAFKA_EXTERNAL_BOOTSTRAP="kafka-central-ext.${DOMAIN}:9092"

validate_data() {
    local phase_label="$1"
    local topic="${TEST_TOPIC}-${phase_label}-$(date +%s)"
    local msg="phase=${phase_label},ts=$(date +%s)"

    echo_info "=== Data Validation ($phase_label) ==="

    # Create client config on the kafka pod
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
# Phase 0: Deploy Static Quorum Cluster
# ============================================================
phase0() {
    echo_step "=== Phase 0: Deploy Static Quorum Cluster (kraft.version=0) ==="
    echo ""
    echo "This will:"
    echo "  - Deploy KRaftController with static quorum on both clusters"
    echo "  - Security: TLS + SASL/PLAIN + RBAC"
    echo "  - CFK creates LoadBalancer services, external-dns syncs DNS"
    echo "  - Deploy Kafka brokers with MDS (OAuth/Keycloak) on both clusters"
    echo "  - Verify kraft.version=0 and quorum status"
    echo ""

    # Deploy KRaft on both clusters first
    # Note: mdsKafkaCluster dependency is config-only — CFK doesn't block on Kafka reachability.
    # KRaft pods will retry MDS connection at runtime until Kafka is up.
    echo_info "Deploying KRaftController in Region 1 (my-cluster, static quorum)..."
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/kraftcontroller-phase0-static.yaml"

    echo ""
    echo_info "Deploying KRaftController in Region 2 (my-clusterdev, static quorum)..."
    run_cmd kube2 apply -f "$SCRIPT_DIR/region2/resources/kraftcontroller-phase0-static.yaml"

    wait_for_kraftcontroller_ready_region1
    wait_for_kraftcontroller_ready_region2

    # Verify KRaft DNS
    echo ""
    echo_info "Checking KRaft controller DNS (external-dns must sync LB IPs)..."
    run_cmd "$SCRIPT_DIR/check-dns-sync.sh"

    # Verify kraft.version=0 (confirms static quorum) — try both regions
    echo ""
    echo_info "=== Verification ==="
    get_kraft_version
    KRAFT_VERSION_OUTPUT=$(kube1 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION1_NS" -- \
        kafka-features --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" describe 2>/dev/null) || \
    KRAFT_VERSION_OUTPUT=$(kube2 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION2_NS" -- \
        kafka-features --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" describe 2>/dev/null) || true
    if echo "$KRAFT_VERSION_OUTPUT" | grep -q "kraft.version.*FinalizedVersionLevel: 0"; then
        echo_info "Confirmed: kraft.version=0 (static quorum)"
    else
        echo_warn "kraft.version may not be 0 — check output above"
    fi
    echo ""
    get_replication_info
    echo ""

    # Test that remove-controller fails (static quorum) — try both regions
    echo_info "Testing remove-controller (should FAIL on static quorum)..."
    REPLICATION_OUTPUT=$(kube1 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION1_NS" -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" \
        describe --replication 2>/dev/null) || \
    REPLICATION_OUTPUT=$(kube2 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION2_NS" -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" \
        describe --replication 2>/dev/null) || true

    REMOVE_ID=$(echo "$REPLICATION_OUTPUT" | awk 'NR>1 && $1>=100 {id=$1} END{print id}')
    REMOVE_DIR_ID=$(echo "$REPLICATION_OUTPUT" | awk -v rid="$REMOVE_ID" 'NR>1 && $1==rid {print $2}')

    if [[ -n "$REMOVE_ID" && -n "$REMOVE_DIR_ID" ]]; then
        echo_info "Using controller-id=$REMOVE_ID, directory-id=$REMOVE_DIR_ID"
        # Try region1 first, then region2
        if kube1 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION1_NS" -- \
            kafka-metadata-quorum --bootstrap-controller localhost:9074 \
            --command-config "$KRAFT_CMD_CONFIG" \
            remove-controller --controller-id "$REMOVE_ID" --controller-directory-id "$REMOVE_DIR_ID" 2>&1; then
            echo_warn "remove-controller unexpectedly succeeded"
        elif kube2 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION2_NS" -- \
            kafka-metadata-quorum --bootstrap-controller localhost:9074 \
            --command-config "$KRAFT_CMD_CONFIG" \
            remove-controller --controller-id "$REMOVE_ID" --controller-directory-id "$REMOVE_DIR_ID" 2>&1; then
            echo_warn "remove-controller unexpectedly succeeded"
        else
            echo_info "remove-controller correctly failed — static quorum does not support dynamic operations"
        fi
    fi

    # Deploy Kafka
    echo ""
    echo_info "Deploying Kafka brokers (with OAuth MDS + RBAC)..."
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/kafka.yaml"
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
    echo_info "If mismatches found, clean stale records in Cloud DNS and restart external-dns."
    run_cmd "$SCRIPT_DIR/check-dns-sync.sh"

    # Data validation
    validate_data "phase0"

    echo_info "Phase 0 complete. Static quorum cluster running on both clusters (secured)."
}

# ============================================================
# Phase 1: Add advertised listeners on KRaft
# ============================================================
phase1() {
    echo_step "=== Phase 1: Add Advertised Listeners on KRaft ==="
    echo ""
    echo "This will:"
    echo "  - Add advertisedListenersEnabled: true on KRaftControllers"
    echo "  - Needs manual-roll annotation (advListeners alone doesn't trigger auto-roll)"
    echo "  - KRaft rolls. Kafka does NOT roll (no change to Kafka)"
    echo "  - kraft.version stays at 0"
    echo ""

    echo_info "Applying Phase 1 YAML to Region 1 (my-cluster)..."
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/kraftcontroller-phase1-advlisteners.yaml"
    wait_for_kraftcontroller_ready_region1

    echo_info "Applying Phase 1 YAML to Region 2 (my-clusterdev)..."
    run_cmd kube2 apply -f "$SCRIPT_DIR/region2/resources/kraftcontroller-phase1-advlisteners.yaml"
    wait_for_kraftcontroller_ready_region2

    # Verify
    echo ""
    echo_info "=== Verification ==="
    echo_info "kraft.version (should still be 0):"
    get_kraft_version
    echo ""
    get_quorum_status

    validate_data "phase1"

    echo_info "Phase 1 complete. Advertised listeners enabled on KRaft. kraft.version still 0."
}

# ============================================================
# Phase 2: Upgrade kraft.version to 1
# ============================================================
phase2() {
    echo_step "=== Phase 2: Upgrade kraft.version=0 → 1 ==="
    echo ""
    echo "This will:"
    echo "  - Run kafka-features upgrade --feature kraft.version=1"
    echo "  - This makes the quorum dynamic"
    echo "  - No YAML change needed — metadata-level upgrade"
    echo "  - Run from Region 1 kraftcontroller-0"
    echo ""

    echo_info "Current kraft.version:"
    get_kraft_version
    echo ""

    echo_info "Upgrading kraft.version to 1 (advertisedListeners enabled — can run from either region)..."
    if ! run_cmd kube1 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION1_NS" -- \
        kafka-features --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" \
        upgrade --feature kraft.version=1 2>/dev/null; then
        echo_warn "Region 1 failed (leader may be in Region 2), trying Region 2..."
        run_cmd kube2 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION2_NS" -- \
            kafka-features --bootstrap-controller localhost:9074 \
            --command-config "$KRAFT_CMD_CONFIG" \
            upgrade --feature kraft.version=1
    fi

    echo ""
    echo_info "=== Verification ==="
    echo_info "kraft.version (should be 1):"
    get_kraft_version
    echo ""
    get_quorum_status

    validate_data "phase2"

    echo_info "Phase 2 complete. kraft.version=1 — dynamic quorum is now active."
}

# ============================================================
# Phase 3: KRaft switch voters → bootstrap.servers
# ============================================================
phase3() {
    echo_step "=== Phase 3: KRaft Switch to Dynamic Quorum ==="
    echo ""
    echo "This will:"
    echo "  - Add dynamicQuorumConfig.enabled on KRaftControllers"
    echo "  - CFK generates bootstrap.servers instead of voters"
    echo "  - KRaft rolls. Kafka does NOT roll yet (phase 4)"
    echo ""
    echo "  IMPORTANT: Do this promptly after phase 2 (kraft.version upgrade)."
    echo "  KRaft at v1 with voters property is a cautious state — minimize time here."
    echo ""

    echo_info "Applying Phase 3 YAML to Region 1 (my-cluster)..."
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/kraftcontroller-phase3-dynamic.yaml"
    wait_for_kraftcontroller_ready_region1

    echo_info "Applying Phase 3 YAML to Region 2 (my-clusterdev)..."
    run_cmd kube2 apply -f "$SCRIPT_DIR/region2/resources/kraftcontroller-phase3-dynamic.yaml"
    wait_for_kraftcontroller_ready_region2

    # Verify
    echo ""
    echo_info "=== Verification ==="
    echo_info "kraft.version (should be 1):"
    get_kraft_version
    echo ""
    get_quorum_status

    validate_data "phase3"

    echo_info "Phase 3 complete. KRaft now on bootstrap.servers. Proceed to phase4 to update Kafka."
}

# ============================================================
# Phase 4: Kafka force roll to pick up bootstrap.servers
# ============================================================
phase4() {
    echo_step "=== Phase 4: Kafka Switch to bootstrap.servers ==="
    echo ""
    echo "This will:"
    echo "  - Force roll Kafka brokers via manual-roll annotation"
    echo "  - CFK regenerates Kafka config with bootstrap.servers (from KRaft dependency)"
    echo "  - Voters property removed, bootstrap.servers takes over"
    echo ""

    echo_info "Force rolling Kafka in Region 1 (my-cluster)..."
    run_cmd kube1 patch kafka kafka -n "$REGION1_NS" --type merge \
        -p '{"spec":{"podTemplate":{"annotations":{"kafkacluster-manual-roll":"phase4"}}}}'
    echo_info "Waiting for Kafka in Region 1..."
    run_cmd kube1 wait --for=condition=platform.confluent.io/cluster-ready \
        kafka/kafka -n "$REGION1_NS" --timeout=10m

    echo_info "Force rolling Kafka in Region 2 (my-clusterdev)..."
    run_cmd kube2 patch kafka kafka -n "$REGION2_NS" --type merge \
        -p '{"spec":{"podTemplate":{"annotations":{"kafkacluster-manual-roll":"phase4"}}}}'
    echo_info "Waiting for Kafka in Region 2..."
    run_cmd kube2 wait --for=condition=platform.confluent.io/cluster-ready \
        kafka/kafka -n "$REGION2_NS" --timeout=10m

    # Verify
    echo ""
    echo_info "=== Verification ==="
    get_kraft_version
    echo ""
    get_quorum_status

    validate_data "phase4"

    echo_info "Phase 4 complete. Kafka now on bootstrap.servers. Migration done."
}

# ============================================================
# Verify: Prove dynamic quorum works
# ============================================================
verify() {
    echo_step "=== Verify: Dynamic Quorum Operations ==="
    echo ""
    echo "This will:"
    echo "  - Show current quorum status"
    echo "  - Remove a controller from the quorum"
    echo "  - Verify removal"
    echo "  - Provide commands to re-add the controller"
    echo ""

    # Confirm kraft.version=1 (dynamic quorum) — try both regions
    get_kraft_version
    KRAFT_VERSION_OUTPUT=$(kube1 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION1_NS" -- \
        kafka-features --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" describe 2>/dev/null) || \
    KRAFT_VERSION_OUTPUT=$(kube2 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION2_NS" -- \
        kafka-features --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" describe 2>/dev/null) || true
    if echo "$KRAFT_VERSION_OUTPUT" | grep -q "kraft.version.*FinalizedVersionLevel: 1"; then
        echo_info "Confirmed: kraft.version=1 (dynamic quorum)"
    else
        echo_warn "kraft.version may not be 1 — dynamic operations may fail"
    fi
    echo ""

    echo_info "Current quorum status:"
    get_quorum_status
    echo ""

    echo_info "Quorum replication info:"
    get_replication_info
    echo ""

    # Parse a controller to remove — try both regions
    REPLICATION_OUTPUT=$(kube1 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION1_NS" -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" \
        describe --replication 2>/dev/null) || \
    REPLICATION_OUTPUT=$(kube2 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION2_NS" -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        --command-config "$KRAFT_CMD_CONFIG" \
        describe --replication 2>/dev/null) || true

    REMOVE_ID=$(echo "$REPLICATION_OUTPUT" | awk 'NR>1 && $1>=100 {id=$1} END{print id}')
    REMOVE_DIR_ID=$(echo "$REPLICATION_OUTPUT" | awk -v rid="$REMOVE_ID" 'NR>1 && $1==rid {print $2}')

    if [[ -n "$REMOVE_ID" && -n "$REMOVE_DIR_ID" ]]; then
        echo_info "Will attempt to remove controller-id=$REMOVE_ID, directory-id=$REMOVE_DIR_ID"
        echo ""

        echo_info "Step 1: Remove controller from quorum (trying both regions)"
        if ! run_cmd kube1 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION1_NS" -- \
            kafka-metadata-quorum --bootstrap-controller localhost:9074 \
            --command-config "$KRAFT_CMD_CONFIG" \
            remove-controller --controller-id "$REMOVE_ID" --controller-directory-id "$REMOVE_DIR_ID" 2>/dev/null; then
            echo_warn "Region 1 failed (leader may be in Region 2), trying Region 2..."
            run_cmd kube2 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION2_NS" -- \
                kafka-metadata-quorum --bootstrap-controller localhost:9074 \
                --command-config "$KRAFT_CMD_CONFIG" \
                remove-controller --controller-id "$REMOVE_ID" --controller-directory-id "$REMOVE_DIR_ID"
        fi

        echo ""
        echo_info "Step 2: Verify removal"
        get_replication_info
        echo ""

        echo_info "Step 3: Re-add the controller"
        echo_warn "Determine which pod had controller-id=$REMOVE_ID, then run add-controller from it."
        echo ""

        # Determine which cluster the removed controller is on
        if [[ "$REMOVE_ID" -ge 200 ]]; then
            local POD_INDEX=$((REMOVE_ID - 200))
            echo "  kubectl --context $REGION2_CONTEXT exec kraftcontroller-${POD_INDEX} -n $REGION2_NS -- \\"
            echo "    kafka-metadata-quorum --bootstrap-controller \\"
            echo "    kraft-central0.${DOMAIN}:9074 \\"
            echo "    --command-config ${KRAFT_CMD_CONFIG} \\"
            echo "    add-controller"
        else
            local POD_INDEX=$((REMOVE_ID - 100))
            echo "  kubectl --context $REGION1_CONTEXT exec kraftcontroller-${POD_INDEX} -n $REGION1_NS -- \\"
            echo "    kafka-metadata-quorum --bootstrap-controller \\"
            echo "    kraft-central0.${DOMAIN}:9074 \\"
            echo "    --command-config ${KRAFT_CMD_CONFIG} \\"
            echo "    add-controller"
        fi
        echo ""
        echo "  # Then verify:"
        echo "  ./setup.sh status"
    else
        echo_warn "Could not parse controller IDs from replication output."
        echo_warn "Run manually: ./setup.sh status"
    fi
}

# ============================================================
# Show status
# ============================================================
show_status() {
    echo_step "=== Cluster Status ==="
    echo ""

    echo_info "=== Region 1 ($REGION1_NS on my-cluster) ==="
    echo_info "KRaftController:"
    show_cmd kube1 get kraftcontroller "$KRAFTCONTROLLER_NAME" -n "$REGION1_NS" 2>/dev/null || echo_warn "KRaftController not found"
    echo ""
    echo_info "Kafka:"
    show_cmd kube1 get kafka kafka -n "$REGION1_NS" 2>/dev/null || echo_warn "Kafka not found"
    echo ""
    echo_info "Pods:"
    show_cmd kube1 get pods -n "$REGION1_NS" -o wide 2>/dev/null || echo_warn "No pods found"
    echo ""

    echo_info "=== Region 2 ($REGION2_NS on my-clusterdev) ==="
    echo_info "KRaftController:"
    show_cmd kube2 get kraftcontroller "$KRAFTCONTROLLER_NAME" -n "$REGION2_NS" 2>/dev/null || echo_warn "KRaftController not found"
    echo ""
    echo_info "Kafka:"
    show_cmd kube2 get kafka kafka -n "$REGION2_NS" 2>/dev/null || echo_warn "Kafka not found"
    echo ""
    echo_info "Pods:"
    show_cmd kube2 get pods -n "$REGION2_NS" -o wide 2>/dev/null || echo_warn "No pods found"
    echo ""

    echo_info "=== Quorum ==="
    get_kraft_version
    echo ""
    get_quorum_status
    echo ""
    get_replication_info
}

# ============================================================
# Run all phases sequentially
# ============================================================
run_all() {
    phase0
    phase1
    phase2
    phase3
    phase4
    verify
    echo ""
    echo_info "All phases complete. Migration from kraft.version=0 to 1 is done."
    echo_info "Run ./cleanup.sh when ready to tear down."
}

# ============================================================
# Main
# ============================================================
COMMAND="${1:-}"

case "$COMMAND" in
    phase0)  phase0 ;;
    phase1)  phase1 ;;
    phase2)  phase2 ;;
    phase3)  phase3 ;;
    phase4)  phase4 ;;
    verify)  verify ;;
    status)  show_status ;;
    "")      run_all ;;
    -h|--help|help) usage ;;
    *)       echo_error "Unknown command: $COMMAND"; usage ;;
esac
