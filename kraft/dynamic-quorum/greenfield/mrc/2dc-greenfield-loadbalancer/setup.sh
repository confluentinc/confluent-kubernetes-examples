#!/bin/bash
# MRC Greenfield Dynamic Quorum Setup (True Multi-Cluster, Secured, LoadBalancer)
# Region 1 (central) -> my-cluster cluster (3 controllers, 2 brokers)
# Region 2 (east)    -> my-clusterdev cluster (3 controllers, 2 brokers)
# Total: 6 controllers (dynamic quorum), quorum needs 4
#
# Security: TLS (secretRef) + SASL/PLAIN + RBAC with OAuth MDS (Keycloak)
#
# Steps:
#   1. Deploy bootstrap ConfigMap + RBAC in Region 1
#   2. Deploy KRaft Region 1 (bootstrap pod formats quorum)
#   3. Get clusterID from Region 1
#   4. Deploy KRaft Region 2 (observers join quorum)
#   5. Promote all non-bootstrap controllers to voters
#   6. Deploy Kafka in both regions (quorum fully formed, no MDS restart loop)
#   7. Verify quorum + data validation

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
TEST_TOPIC="greenfield-test"
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
    echo "MRC Greenfield Dynamic Quorum Deployment (LoadBalancer)"
    echo "True multi-cluster: my-cluster (central) + my-clusterdev (east)"
    echo "Security: TLS + SASL/PLAIN + RBAC with OAuth MDS (Keycloak)"
    echo ""
    echo "Commands:"
    echo "  (no args)    Run all steps sequentially (interactive)"
    echo "  region1      Deploy Region 1 KRaft only (bootstrap)"
    echo "  region2      Deploy Region 2 KRaft only (observer)"
    echo "  promote      Promote observers to voters"
    echo "  kafka        Deploy Kafka in both regions"
    echo "  verify       Verify quorum and data"
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
# Step 1: Deploy Bootstrap ConfigMap & RBAC (Region 1)
# ============================================================
deploy_bootstrap() {
    echo_step "=== Step 1: Deploy Bootstrap ConfigMap & RBAC (Region 1) ==="
    echo ""
    echo "Required for dynamic quorum bootstrap in central region."
    echo "  - ConfigMap: kraftcontroller-dynamic-quorum (tracks bootstrap status)"
    echo "  - RBAC: ServiceAccount + Role + RoleBinding for ConfigMap access"
    echo ""

    echo_info "Deploying bootstrap ConfigMap in Region 1 (my-cluster)..."
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/bootstrap-configmap.yaml"

    echo_info "Deploying RBAC in Region 1 (my-cluster)..."
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/rbac.yaml"
}

# ============================================================
# Step 2: Deploy Region 1 (KRaft bootstrap + Kafka)
# ============================================================
deploy_kraft_region1() {
    echo_step "=== Step 2: Deploy KRaft in Region 1 (my-cluster, bootstrap) ==="
    echo ""
    echo "This will:"
    echo "  - Deploy KRaftController with dynamic quorum (bootstrapPod: 0)"
    echo "  - Security: TLS + SASL/PLAIN + RBAC"
    echo "  - CFK creates LoadBalancer services, external-dns syncs DNS"
    echo "  - Bootstrap pod (pod-0) formats quorum with --standalone"
    echo ""

    echo_info "Deploying KRaftController in Region 1 (my-cluster, bootstrap)..."
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/kraftcontroller.yaml"

    echo_info "Waiting for KRaftController to be ready in Region 1..."
    run_cmd kube1 wait --for=condition=platform.confluent.io/cluster-ready \
        kraftcontroller/"$KRAFTCONTROLLER_NAME" -n "$REGION1_NS" --timeout=10m

    echo_info "Region 1 KRaft deployment complete."
}

# ============================================================
# Step 3: Get Cluster ID from Region 1
# ============================================================
get_cluster_id() {
    echo_step "=== Step 3: Get Cluster ID from Region 1 ==="
    echo ""

    CLUSTER_ID=$(kube1 get kraftcontroller "$KRAFTCONTROLLER_NAME" -n "$REGION1_NS" \
        -o jsonpath='{.status.clusterID}' 2>/dev/null)

    if [ -z "$CLUSTER_ID" ]; then
        echo_error "Failed to get cluster ID from Region 1"
        echo "Make sure Region 1 KRaft is deployed and ready."
        exit 1
    fi

    echo_info "Cluster ID: $CLUSTER_ID"

    # Update Region 2 YAML with cluster ID
    REGION2_KC_YAML="$SCRIPT_DIR/region2/resources/kraftcontroller.yaml"
    if grep -q "clusterID:" "$REGION2_KC_YAML"; then
        sed -i '' "s/clusterID: .*/clusterID: $CLUSTER_ID/" "$REGION2_KC_YAML"
        echo_info "Updated $REGION2_KC_YAML with cluster ID: $CLUSTER_ID"
    fi
}

# ============================================================
# Step 4: Deploy Region 2 (KRaft observer + Kafka)
# ============================================================
deploy_kraft_region2() {
    echo_step "=== Step 4: Deploy KRaft in Region 2 (my-clusterdev, observer) ==="
    echo ""
    echo "This will:"
    echo "  - Deploy KRaftController as observer (no bootstrapPod, joins existing quorum)"
    echo "  - Uses clusterID from Region 1"
    echo ""

    echo_info "Deploying KRaftController in Region 2 (my-clusterdev, observer)..."
    run_cmd kube2 apply -f "$SCRIPT_DIR/region2/resources/kraftcontroller.yaml"

    echo_info "Waiting for KRaftController to be ready in Region 2..."
    run_cmd kube2 wait --for=condition=platform.confluent.io/cluster-ready \
        kraftcontroller/"$KRAFTCONTROLLER_NAME" -n "$REGION2_NS" --timeout=10m

    echo_info "Region 2 KRaft deployment complete. Controllers joined as observers."
}

# ============================================================
# Step 5: Promote Observers to Voters
# ============================================================
# (moved here — promote before deploying Kafka so quorum is fully formed)

# ============================================================
# Step 6: Deploy Kafka in Both Regions
# ============================================================
deploy_kafka() {
    echo_step "=== Step 6: Deploy Kafka in Both Regions ==="
    echo ""
    echo "This will:"
    echo "  - Deploy Kafka brokers with MDS (OAuth/Keycloak) in both regions"
    echo "  - Security: TLS + SASL/PLAIN + RBAC"
    echo "  - Quorum is fully formed (all 6 voters) — Kafka can start cleanly"
    echo ""

    echo_info "Deploying Kafka in Region 1 (my-cluster)..."
    run_cmd kube1 apply -f "$SCRIPT_DIR/region1/resources/kafka.yaml"

    echo_info "Deploying Kafka in Region 2 (my-clusterdev)..."
    run_cmd kube2 apply -f "$SCRIPT_DIR/region2/resources/kafka.yaml"

    echo_info "Waiting for Kafka to be ready in Region 1..."
    run_cmd kube1 wait --for=condition=platform.confluent.io/cluster-ready \
        kafka/kafka -n "$REGION1_NS" --timeout=10m

    echo_info "Waiting for Kafka to be ready in Region 2..."
    run_cmd kube2 wait --for=condition=platform.confluent.io/cluster-ready \
        kafka/kafka -n "$REGION2_NS" --timeout=10m

    # Verify DNS
    echo ""
    echo_info "Checking DNS (external-dns must sync LB IPs)..."
    run_cmd "$SCRIPT_DIR/check-dns-sync.sh" watch

    echo_info "Kafka deployment complete in both regions."
}

# ============================================================
# Step 5: Promote Observers to Voters
# ============================================================
promote_observers() {
    echo_step "=== Step 5: Promote Non-Bootstrap Controllers to Voters ==="
    echo ""
    echo "All controllers except bootstrap pod (central-0) joined as observers."
    echo "They must be promoted to voters via kafka-metadata-quorum add-controller."
    echo ""
    echo "Controllers to promote (5 total):"
    echo "  - kraftcontroller-1 in $REGION1_NS on my-cluster (ID 101)"
    echo "  - kraftcontroller-2 in $REGION1_NS on my-cluster (ID 102)"
    echo "  - kraftcontroller-0 in $REGION2_NS on my-clusterdev (ID 200)"
    echo "  - kraftcontroller-1 in $REGION2_NS on my-clusterdev (ID 201)"
    echo "  - kraftcontroller-2 in $REGION2_NS on my-clusterdev (ID 202)"
    echo ""

    # Ensure admin configs exist
    ensure_admin_configs

    echo_info "Current quorum status before promotion:"
    get_replication_info
    echo ""

    BOOTSTRAP_ENDPOINT="kraft-central0.${DOMAIN}:9074"

    # Promote central-1 (ID 101) — on my-cluster
    echo_info "Promoting kraftcontroller-1 in $REGION1_NS on my-cluster (ID 101)..."
    create_admin_config "kube1" "${KRAFTCONTROLLER_NAME}-1" "$REGION1_NS"
    run_cmd kube1 exec "${KRAFTCONTROLLER_NAME}-1" -n "$REGION1_NS" -- \
        kafka-metadata-quorum --bootstrap-controller "$BOOTSTRAP_ENDPOINT" \
        --command-config "$KRAFT_CMD_CONFIG" \
        add-controller
    echo_info "Controller 101 promoted"

    # Promote central-2 (ID 102) — on my-cluster
    echo_info "Promoting kraftcontroller-2 in $REGION1_NS on my-cluster (ID 102)..."
    create_admin_config "kube1" "${KRAFTCONTROLLER_NAME}-2" "$REGION1_NS"
    run_cmd kube1 exec "${KRAFTCONTROLLER_NAME}-2" -n "$REGION1_NS" -- \
        kafka-metadata-quorum --bootstrap-controller "$BOOTSTRAP_ENDPOINT" \
        --command-config "$KRAFT_CMD_CONFIG" \
        add-controller
    echo_info "Controller 102 promoted"

    # Promote east-0 (ID 200) — on my-clusterdev
    echo_info "Promoting kraftcontroller-0 in $REGION2_NS on my-clusterdev (ID 200)..."
    create_admin_config "kube2" "${KRAFTCONTROLLER_NAME}-0" "$REGION2_NS"
    run_cmd kube2 exec "${KRAFTCONTROLLER_NAME}-0" -n "$REGION2_NS" -- \
        kafka-metadata-quorum --bootstrap-controller "$BOOTSTRAP_ENDPOINT" \
        --command-config "$KRAFT_CMD_CONFIG" \
        add-controller
    echo_info "Controller 200 promoted"

    # Promote east-1 (ID 201) — on my-clusterdev
    echo_info "Promoting kraftcontroller-1 in $REGION2_NS on my-clusterdev (ID 201)..."
    create_admin_config "kube2" "${KRAFTCONTROLLER_NAME}-1" "$REGION2_NS"
    run_cmd kube2 exec "${KRAFTCONTROLLER_NAME}-1" -n "$REGION2_NS" -- \
        kafka-metadata-quorum --bootstrap-controller "$BOOTSTRAP_ENDPOINT" \
        --command-config "$KRAFT_CMD_CONFIG" \
        add-controller
    echo_info "Controller 201 promoted"

    # Promote east-2 (ID 202) — on my-clusterdev
    echo_info "Promoting kraftcontroller-2 in $REGION2_NS on my-clusterdev (ID 202)..."
    create_admin_config "kube2" "${KRAFTCONTROLLER_NAME}-2" "$REGION2_NS"
    run_cmd kube2 exec "${KRAFTCONTROLLER_NAME}-2" -n "$REGION2_NS" -- \
        kafka-metadata-quorum --bootstrap-controller "$BOOTSTRAP_ENDPOINT" \
        --command-config "$KRAFT_CMD_CONFIG" \
        add-controller
    echo_info "Controller 202 promoted"

    echo ""
    echo_info "Waiting for promotions to take effect..."
    sleep 5
}

# ============================================================
# Step 6: Verify Quorum and Data
# ============================================================
verify() {
    echo_step "=== Step 6: Verify Quorum and Data ==="
    echo ""

    ensure_admin_configs

    echo_info "kraft.version:"
    get_kraft_version
    echo ""

    echo_info "Quorum status (all 6 should be voters):"
    get_quorum_status
    echo ""

    echo_info "Quorum replication info:"
    get_replication_info
    echo ""

    # Data validation
    validate_data "greenfield"

    echo_info "Verification complete."
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
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  MRC Greenfield (LoadBalancer) - Setup${NC}"
    echo -e "${BLUE}  (True Multi-Cluster, Secured)${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "This script will deploy a greenfield MRC cluster with dynamic quorum:"
    echo "  - Region 1 (central): 3 KRaft controllers (bootstrap) + 2 Kafka brokers"
    echo "  - Region 2 (east):    3 KRaft controllers (observer)  + 2 Kafka brokers"
    echo "  - Total: 6 controllers, quorum needs 4"
    echo ""
    echo "Security: TLS + SASL/PLAIN + RBAC with OAuth MDS (Keycloak)"
    echo ""

    deploy_bootstrap
    deploy_kraft_region1
    get_cluster_id
    deploy_kraft_region2
    promote_observers
    deploy_kafka
    verify

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Greenfield Setup Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Deployed (3+3 true multi-cluster with full security):"
    echo "  - my-cluster  ($REGION1_NS): 3 KRaft controllers (IDs 100-102) + 2 Kafka brokers (IDs 30-31)"
    echo "  - my-clusterdev ($REGION2_NS): 3 KRaft controllers (IDs 200-202) + 2 Kafka brokers (IDs 10-11)"
    echo "  - Total: 6 controllers (all voters), quorum requires 4"
    echo ""
    echo "Next steps:"
    echo "  1. Check status:  ./setup.sh status"
    echo "  2. Cleanup:       ./cleanup.sh"
    echo ""
}

# ============================================================
# Main
# ============================================================
COMMAND="${1:-}"

case "$COMMAND" in
    region1)   deploy_bootstrap; deploy_kraft_region1 ;;
    region2)   get_cluster_id; deploy_kraft_region2 ;;
    kafka)     deploy_kafka ;;
    promote)   promote_observers ;;
    verify)    verify ;;
    status)    show_status ;;
    "")        run_all ;;
    -h|--help|help) usage ;;
    *)         echo_error "Unknown command: $COMMAND"; usage ;;
esac
