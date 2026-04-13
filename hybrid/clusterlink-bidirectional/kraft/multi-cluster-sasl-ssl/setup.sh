#!/bin/bash
# MRC Bidirectional Cluster Link Setup (True Multi-Cluster, SASL-SSL, LoadBalancer)
#
# Central cluster -> <central-cluster> (us-central1)
# East cluster    -> <east-cluster> (us-east4)
#
# Security: TLS + SASL/PLAIN on Kafka listeners, Basic auth on REST API
# External access: LoadBalancer with ExternalDNS
#
# Modes:
#   outbound  (Case 3): Both clusters use OUTBOUND connection mode (no firewall)
#   private   (Case 4): Central=OUTBOUND, East=INBOUND (east behind firewall)
#
# Prerequisites:
#   - CFK operator installed on both clusters
#   - TLS secrets already created: tls-kafka, tls-kraftcontroller, ca-pair-sslcerts
#
# Phases:
#   Phase 1: Create secrets (SASL creds, REST server/client creds, password encoder, cross-cluster)
#   Phase 2: Deploy KRaft controllers (both clusters)
#   Phase 3: Deploy Kafka clusters (both clusters, with LB external access)
#   Phase 4: Wait for DNS resolution (REST LB + Kafka LB endpoints)
#   Phase 5: Deploy KafkaRestClass (local + mode-specific remote on each cluster)
#   Phase 6: Create topics (from mode-specific directory)
#   Phase 7: Create ClusterLinks (outbound: direct apply; private: clusterID + ordered apply)
#   Phase 8: Validate bidirectional mirroring

set -e

# ============================================================
# Configuration
# ============================================================
CENTRAL_NS="${CENTRAL_NS:-central}"
EAST_NS="${EAST_NS:-east}"
CENTRAL_CONTEXT="${CENTRAL_CONTEXT:-<central-cluster-context>}"
EAST_CONTEXT="${EAST_CONTEXT:-<east-cluster-context>}"
MODE="${MODE:-outbound-outbound}"  # outbound-outbound (both reachable) or outbound-inbound (one firewalled)
DOMAIN="my-domain.example.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/manifests"

# Mode-specific manifest directory
case "$MODE" in
    outbound-outbound) MODE_DIR="$MANIFESTS_DIR/bidirectional-cl/outbound-outbound" ;;
    outbound-inbound)  MODE_DIR="$MANIFESTS_DIR/bidirectional-cl/outbound-inbound" ;;
    *)        echo "ERROR: Invalid MODE '$MODE'. Must be 'outbound-outbound' or 'outbound-inbound'."; exit 1 ;;
esac

# External endpoints (set by ExternalDNS from LoadBalancer)
CENTRAL_KAFKA_BOOTSTRAP="kafka-central.${DOMAIN}:9092"
EAST_KAFKA_BOOTSTRAP="kafka-east.${DOMAIN}:9092"
CENTRAL_REST_ENDPOINT="kafka-central-rest.${DOMAIN}"
EAST_REST_ENDPOINT="kafka-east-rest.${DOMAIN}"

# Credentials
CENTRAL_KAFKA_USER="central-kafka"
CENTRAL_KAFKA_PASS="<central-kafka-password>"
EAST_KAFKA_USER="east-kafka"
EAST_KAFKA_PASS="<east-kafka-password>"
PASSWORD_ENCODER_PASS="<encoder-password>"

# ============================================================
# Colors + helpers
# ============================================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step()    { echo -e "\n${BLUE}[STEP]${NC} $1"; }
print_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

ask_yes_no() {
    local prompt="$1"
    echo -en "${YELLOW}${prompt} [Y/n]${NC} > "
    read -r REPLY
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        return 1
    fi
    return 0
}

# Helpers: kubectl scoped to each cluster
kube1() { kubectl --context "$CENTRAL_CONTEXT" "$@"; }
kube2() { kubectl --context "$EAST_CONTEXT" "$@"; }

# ============================================================
# Phase 1: Create Secrets
# ============================================================
phase1_create_secrets() {
    print_step "=== Phase 1: Create Secrets ==="
    echo ""
    echo "This will create the following secrets on each cluster:"
    echo ""
    echo "  SECRET TYPE 1: SASL/PLAIN credentials for Kafka listeners"
    echo "    Secret: 'credential' (one per cluster, different usernames)"
    echo "    Format: plain.txt (username=x, password=y), plain-users.json, plain-interbroker.txt"
    echo "    - Central: user=$CENTRAL_KAFKA_USER"
    echo "    - East:    user=$EAST_KAFKA_USER"
    echo ""
    echo "  SECRET TYPE 2: Cross-cluster SASL credentials (for ClusterLink to auth to remote Kafka)"
    echo "    Secret: 'east-credential' on central (east's creds), 'central-credential' on east"
    echo "    Format: same as type 1 (plain.txt with remote cluster's username/password)"
    echo ""
    echo "  SECRET TYPE 3: Kafka REST server credentials (Jetty PropertyFileLoginModule format)"
    echo "    Secret: 'kafkarest-credential' (one per cluster)"
    echo "    Format: basic.txt with 'user: pass,role' (note: colon+space, not equals)"
    echo ""
    echo "  SECRET TYPE 4: KafkaRestClass client credentials (CFK basic auth format)"
    echo "    Secret: 'local-rest-credential' (local REST), 'east-rest-credential'/'central-rest-credential' (remote REST)"
    echo "    Format: basic.txt with 'username=x, password=y'"
    echo ""
    echo "  SECRET TYPE 5: Password encoder secret"
    echo "    Secret: 'password-encoder-secret'"
    echo "    Format: password-encoder.txt with 'password=<value>'"
    echo ""

    if ! ask_yes_no "Create secrets?"; then
        print_info "Skipped Phase 1."
        return
    fi

    # --- Central cluster secrets ---
    print_info "Creating secrets on central cluster ($CENTRAL_NS)..."

    # Type 1: SASL/PLAIN credential for central Kafka listeners
    print_info "  Creating 'credential' (SASL/PLAIN for central Kafka)..."
    kube1 create secret generic credential -n "$CENTRAL_NS" \
        --from-literal=plain.txt="username=$CENTRAL_KAFKA_USER
password=$CENTRAL_KAFKA_PASS" \
        --from-literal=plain-users.json="{\"$CENTRAL_KAFKA_USER\":\"$CENTRAL_KAFKA_PASS\"}" \
        --from-literal=plain-interbroker.txt="username=$CENTRAL_KAFKA_USER
password=$CENTRAL_KAFKA_PASS" \
        --dry-run=client -o yaml | kube1 apply -f -

    # Type 2: Cross-cluster credential (east's creds, so central CL can auth to east Kafka)
    print_info "  Creating 'east-credential' (east SASL creds for cross-cluster ClusterLink)..."
    kube1 create secret generic east-credential -n "$CENTRAL_NS" \
        --from-literal=plain.txt="username=$EAST_KAFKA_USER
password=$EAST_KAFKA_PASS" \
        --from-literal=plain-users.json="{\"$EAST_KAFKA_USER\":\"$EAST_KAFKA_PASS\"}" \
        --from-literal=plain-interbroker.txt="username=$EAST_KAFKA_USER
password=$EAST_KAFKA_PASS" \
        --dry-run=client -o yaml | kube1 apply -f -

    # Type 3: REST server credential (Jetty format: "user: pass,role")
    print_info "  Creating 'kafkarest-credential' (REST server, Jetty format)..."
    kube1 create secret generic kafkarest-credential -n "$CENTRAL_NS" \
        --from-literal=basic.txt="$CENTRAL_KAFKA_USER: $CENTRAL_KAFKA_PASS,admin" \
        --dry-run=client -o yaml | kube1 apply -f -

    # Type 4a: Local REST client credential (CFK basic auth format)
    print_info "  Creating 'local-rest-credential' (local KafkaRestClass client auth)..."
    kube1 create secret generic local-rest-credential -n "$CENTRAL_NS" \
        --from-literal=basic.txt="username=$CENTRAL_KAFKA_USER
password=$CENTRAL_KAFKA_PASS" \
        --dry-run=client -o yaml | kube1 apply -f -

    # Type 4b: Remote REST client credential (east's REST, CFK basic auth format)
    print_info "  Creating 'east-rest-credential' (remote KafkaRestClass client auth for east REST)..."
    kube1 create secret generic east-rest-credential -n "$CENTRAL_NS" \
        --from-literal=basic.txt="username=$EAST_KAFKA_USER
password=$EAST_KAFKA_PASS" \
        --dry-run=client -o yaml | kube1 apply -f -

    # Type 5: Password encoder
    print_info "  Creating 'password-encoder-secret'..."
    kube1 create secret generic password-encoder-secret -n "$CENTRAL_NS" \
        --from-literal=password-encoder.txt="password=$PASSWORD_ENCODER_PASS" \
        --dry-run=client -o yaml | kube1 apply -f -

    # --- East cluster secrets ---
    print_info "Creating secrets on east cluster ($EAST_NS)..."

    # Type 1: SASL/PLAIN credential for east Kafka listeners
    print_info "  Creating 'credential' (SASL/PLAIN for east Kafka)..."
    kube2 create secret generic credential -n "$EAST_NS" \
        --from-literal=plain.txt="username=$EAST_KAFKA_USER
password=$EAST_KAFKA_PASS" \
        --from-literal=plain-users.json="{\"$EAST_KAFKA_USER\":\"$EAST_KAFKA_PASS\"}" \
        --from-literal=plain-interbroker.txt="username=$EAST_KAFKA_USER
password=$EAST_KAFKA_PASS" \
        --dry-run=client -o yaml | kube2 apply -f -

    # Type 2: Cross-cluster credential (central's creds, so east CL can auth to central Kafka)
    print_info "  Creating 'central-credential' (central SASL creds for cross-cluster ClusterLink)..."
    kube2 create secret generic central-credential -n "$EAST_NS" \
        --from-literal=plain.txt="username=$CENTRAL_KAFKA_USER
password=$CENTRAL_KAFKA_PASS" \
        --from-literal=plain-users.json="{\"$CENTRAL_KAFKA_USER\":\"$CENTRAL_KAFKA_PASS\"}" \
        --from-literal=plain-interbroker.txt="username=$CENTRAL_KAFKA_USER
password=$CENTRAL_KAFKA_PASS" \
        --dry-run=client -o yaml | kube2 apply -f -

    # Type 3: REST server credential (Jetty format: "user: pass,role")
    print_info "  Creating 'kafkarest-credential' (REST server, Jetty format)..."
    kube2 create secret generic kafkarest-credential -n "$EAST_NS" \
        --from-literal=basic.txt="$EAST_KAFKA_USER: $EAST_KAFKA_PASS,admin" \
        --dry-run=client -o yaml | kube2 apply -f -

    # Type 4a: Local REST client credential (CFK basic auth format)
    print_info "  Creating 'local-rest-credential' (local KafkaRestClass client auth)..."
    kube2 create secret generic local-rest-credential -n "$EAST_NS" \
        --from-literal=basic.txt="username=$EAST_KAFKA_USER
password=$EAST_KAFKA_PASS" \
        --dry-run=client -o yaml | kube2 apply -f -

    # Type 4b: Remote REST client credential (central's REST, CFK basic auth format)
    print_info "  Creating 'central-rest-credential' (remote KafkaRestClass client auth for central REST)..."
    kube2 create secret generic central-rest-credential -n "$EAST_NS" \
        --from-literal=basic.txt="username=$CENTRAL_KAFKA_USER
password=$CENTRAL_KAFKA_PASS" \
        --dry-run=client -o yaml | kube2 apply -f -

    # Type 5: Password encoder
    print_info "  Creating 'password-encoder-secret'..."
    kube2 create secret generic password-encoder-secret -n "$EAST_NS" \
        --from-literal=password-encoder.txt="password=$PASSWORD_ENCODER_PASS" \
        --dry-run=client -o yaml | kube2 apply -f -

    print_info "Phase 1 complete: All secrets created on both clusters."
}

# ============================================================
# Phase 2: Deploy KRaft Controllers
# ============================================================
phase2_deploy_kraft() {
    print_step "=== Phase 2: Deploy KRaft Controllers (both clusters) ==="
    echo ""
    echo "This will deploy 3-node KRaft controllers on each GKE cluster:"
    echo "  - Central (<central-cluster>, us-central1): kraftcontroller in namespace '$CENTRAL_NS'"
    echo "  - East (<east-cluster>, us-east4):     kraftcontroller in namespace '$EAST_NS'"
    echo ""

    if ! ask_yes_no "Deploy KRaft controllers?"; then
        print_info "Skipped Phase 2."
        return
    fi

    print_info "Deploying KRaftController on central cluster..."
    kube1 apply -f "$MANIFESTS_DIR/cp-cluster/central/kraftcontroller.yaml"

    print_info "Deploying KRaftController on east cluster..."
    kube2 apply -f "$MANIFESTS_DIR/cp-cluster/east/kraftcontroller.yaml"

    print_info "Waiting for KRaftController to be ready on central..."
    kube1 wait --for=condition=platform.confluent.io/cluster-ready \
        kraftcontroller/kraftcontroller -n "$CENTRAL_NS" --timeout=10m

    print_info "Waiting for KRaftController to be ready on east..."
    kube2 wait --for=condition=platform.confluent.io/cluster-ready \
        kraftcontroller/kraftcontroller -n "$EAST_NS" --timeout=10m

    print_info "Phase 2 complete: KRaft controllers ready on both clusters."
}

# ============================================================
# Phase 3: Deploy Kafka Clusters
# ============================================================
phase3_deploy_kafka() {
    print_step "=== Phase 3: Deploy Kafka Clusters (both clusters) ==="
    echo ""
    echo "This will deploy 3-node Kafka clusters with:"
    echo "  - SASL/PLAIN authentication on internal + external listeners"
    echo "  - TLS encryption on all listeners"
    echo "  - LoadBalancer external access for cross-cluster communication"
    echo "  - External REST API via LoadBalancer for cross-cluster CL management"
    echo "  - REST auth: basic with roles=[admin] matching kafkarest-credential role"
    echo ""
    echo "Endpoints after DNS sync:"
    echo "  - Central Kafka:  $CENTRAL_KAFKA_BOOTSTRAP"
    echo "  - East Kafka:     $EAST_KAFKA_BOOTSTRAP"
    echo "  - Central REST:   https://$CENTRAL_REST_ENDPOINT:443"
    echo "  - East REST:      https://$EAST_REST_ENDPOINT:443"
    echo ""

    if ! ask_yes_no "Deploy Kafka clusters?"; then
        print_info "Skipped Phase 3."
        return
    fi

    print_info "Deploying Kafka on central cluster..."
    kube1 apply -f "$MANIFESTS_DIR/cp-cluster/central/kafka.yaml"

    print_info "Deploying Kafka on east cluster..."
    kube2 apply -f "$MANIFESTS_DIR/cp-cluster/east/kafka.yaml"

    print_info "Waiting for Kafka to be ready on central..."
    kube1 wait --for=condition=platform.confluent.io/cluster-ready \
        kafka/kafka -n "$CENTRAL_NS" --timeout=15m

    print_info "Waiting for Kafka to be ready on east..."
    kube2 wait --for=condition=platform.confluent.io/cluster-ready \
        kafka/kafka -n "$EAST_NS" --timeout=15m

    print_info "Phase 3 complete: Kafka clusters ready on both clusters."
}

# ============================================================
# Phase 4: Wait for DNS Resolution
# ============================================================
phase4_wait_dns() {
    print_step "=== Phase 4: Wait for DNS Resolution (External LB Endpoints) ==="
    echo ""
    echo "ExternalDNS must sync LoadBalancer IPs to DNS records."
    echo "Checking resolution for:"
    echo "  - kafka-central.${DOMAIN}"
    echo "  - kafka-east.${DOMAIN}"
    echo "  - kafka-central-rest.${DOMAIN}"
    echo "  - kafka-east-rest.${DOMAIN}"
    echo ""

    if ! ask_yes_no "Check DNS resolution?"; then
        print_info "Skipped Phase 4."
        return
    fi

    local max_retries=30
    local retry_interval=10
    local all_resolved=false

    for i in $(seq 1 $max_retries); do
        local resolved=true

        for host in "kafka-central.${DOMAIN}" "kafka-east.${DOMAIN}" \
                    "kafka-central-rest.${DOMAIN}" "kafka-east-rest.${DOMAIN}"; do
            if dig +short "$host" 2>/dev/null | grep -q '[0-9]'; then
                echo -e "  ${GREEN}[OK]${NC} $host -> $(dig +short "$host" | head -1)"
            else
                echo -e "  ${YELLOW}[WAIT]${NC} $host not resolved yet"
                resolved=false
            fi
        done

        if $resolved; then
            all_resolved=true
            break
        fi

        if [ $i -lt $max_retries ]; then
            echo ""
            print_info "Retry $i/$max_retries... waiting ${retry_interval}s"
            sleep $retry_interval
        fi
    done

    if $all_resolved; then
        print_info "Phase 4 complete: All DNS records resolved."
    else
        print_warning "DNS resolution timed out. Some records may not be ready."
        print_warning "You can continue, but ClusterLink creation may fail if DNS is not ready."
        if ! ask_yes_no "Continue anyway?"; then
            exit 1
        fi
    fi
}

# ============================================================
# Phase 5: Create KafkaRestClass
# ============================================================
phase5_create_restclass() {
    print_step "=== Phase 5: Create KafkaRestClass (local + remote on each cluster, mode=$MODE) ==="
    echo ""
    echo "Creating REST classes for ClusterLink management:"
    echo "  Central cluster:"
    echo "    - central-rest: local REST class (shared infra)"
    echo "    - east-rest:    remote REST class (from $MODE mode manifests)"
    echo "  East cluster:"
    echo "    - east-rest:    local REST class (shared infra)"
    echo "    - central-rest: remote REST class (from $MODE mode manifests)"
    echo ""

    if ! ask_yes_no "Create KafkaRestClass resources?"; then
        print_info "Skipped Phase 5."
        return
    fi

    print_info "Creating local KafkaRestClass on central cluster (shared)..."
    kube1 apply -f "$MANIFESTS_DIR/cp-cluster/central/kafkarestclass.yaml"
    print_info "Creating remote KafkaRestClass on central cluster ($MODE mode)..."
    kube1 apply -f "$MODE_DIR/central/east-kafkarestclass.yaml"

    print_info "Creating local KafkaRestClass on east cluster (shared)..."
    kube2 apply -f "$MANIFESTS_DIR/cp-cluster/east/kafkarestclass.yaml"
    print_info "Creating remote KafkaRestClass on east cluster ($MODE mode)..."
    kube2 apply -f "$MODE_DIR/east/central-kafkarestclass.yaml"

    print_info "Phase 5 complete: KafkaRestClass resources created."
}

# ============================================================
# Phase 6: Create Topics
# ============================================================
phase6_create_topics() {
    print_step "=== Phase 6: Create Topics (mode=$MODE) ==="
    echo ""
    echo "Creating source topics for bidirectional mirroring:"
    echo "  - central-topic on central (will be mirrored TO east)"
    echo "  - east-topic on east (will be mirrored TO central)"
    echo ""

    if ! ask_yes_no "Create topics?"; then
        print_info "Skipped Phase 6."
        return
    fi

    print_info "Creating topics on central cluster..."
    kube1 apply -f "$MODE_DIR/central/topics.yaml"

    print_info "Creating topics on east cluster..."
    kube2 apply -f "$MODE_DIR/east/topics.yaml"

    # Wait for topics to be created
    print_info "Waiting for topics to be ready..."
    sleep 10

    # Check topic status
    local central_topic_state
    central_topic_state=$(kube1 get kafkatopic central-topic -n "$CENTRAL_NS" \
        -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
    local east_topic_state
    east_topic_state=$(kube2 get kafkatopic east-topic -n "$EAST_NS" \
        -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")

    print_info "central-topic state: $central_topic_state"
    print_info "east-topic state: $east_topic_state"

    print_info "Phase 6 complete: Topics created."
}

# ============================================================
# Phase 7: Create ClusterLinks
# ============================================================
phase7_create_clusterlinks() {
    local link_name
    if [[ "$MODE" == "outbound" ]]; then
        link_name="bidirectional-link"
    else
        link_name="bidirectional-cl/outbound-inbound-link"
    fi

    print_step "=== Phase 7: Create ClusterLinks (mode=$MODE) ==="
    echo ""

    if [[ "$MODE" == "outbound" ]]; then
        echo "Creating bidirectional ClusterLinks (no clusterID needed -- REST discovery):"
        echo "  - central-cluster-link (on central): mirrors east-topic FROM east"
        echo "  - east-cluster-link (on east):       mirrors central-topic FROM central"
        echo ""
        echo "Link name: $link_name (must match on both sides)"
    else
        echo "Creating bidirectional ClusterLinks (OUTBOUND + INBOUND, firewall scenario):"
        echo "  - east-cluster-link (INBOUND on east): created FIRST (passive, needs clusterID)"
        echo "  - central-cluster-link (OUTBOUND on central): created SECOND (initiates connection)"
        echo ""
        echo "Link name: $link_name (must match on both sides)"
        echo ""
        echo "NOTE: INBOUND CR requires central's clusterID (will be fetched automatically)."
    fi
    echo ""

    if ! ask_yes_no "Create ClusterLinks?"; then
        print_info "Skipped Phase 7."
        return
    fi

    if [[ "$MODE" == "outbound" ]]; then
        # Outbound mode: both sides use OUTBOUND, no clusterID needed, order doesn't matter
        print_info "Applying ClusterLink on central cluster..."
        kube1 apply -f "$MODE_DIR/central/clusterlink.yaml"

        print_info "Applying ClusterLink on east cluster..."
        kube2 apply -f "$MODE_DIR/east/clusterlink.yaml"
    else
        # Private mode: INBOUND on east first, then OUTBOUND on central
        # INBOUND CR needs the remote (central) cluster's clusterID
        print_info "Fetching central cluster ID for INBOUND CR..."
        local central_cluster_id
        central_cluster_id=$(kube1 exec -n "$CENTRAL_NS" kafka-0 -c kafka -- bash -c \
            "kafka-cluster cluster-id --bootstrap-server kafka.$CENTRAL_NS.svc.cluster.local:9071 \
             --config /mnt/config/shared/admin.properties 2>/dev/null" | grep -v "^$" | tail -1)
        print_info "Central cluster ID: $central_cluster_id"

        if [[ -z "$central_cluster_id" ]]; then
            print_error "Failed to fetch central cluster ID. Cannot create INBOUND ClusterLink."
            exit 1
        fi

        print_info "Applying INBOUND ClusterLink on east cluster (sed clusterID)..."
        sed "s/CENTRAL_CLUSTER_ID_PLACEHOLDER/$central_cluster_id/" \
            "$MODE_DIR/east/clusterlink.yaml" | kube2 apply -f -

        print_info "Waiting 10s for INBOUND CR to register..."
        sleep 10

        print_info "Applying OUTBOUND ClusterLink on central cluster..."
        kube1 apply -f "$MODE_DIR/central/clusterlink.yaml"
    fi

    # Wait for ClusterLinks to be created
    print_info "Waiting for ClusterLinks to be established..."
    local max_wait=120
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local central_state
        central_state=$(kube1 get clusterlink central-cluster-link -n "$CENTRAL_NS" \
            -o jsonpath='{.status.state}' 2>/dev/null || echo "Pending")
        local east_state
        east_state=$(kube2 get clusterlink east-cluster-link -n "$EAST_NS" \
            -o jsonpath='{.status.state}' 2>/dev/null || echo "Pending")

        print_info "ClusterLink states: central=$central_state, east=$east_state"

        if [[ "$central_state" == "CREATED" ]] && [[ "$east_state" == "CREATED" ]]; then
            break
        fi

        sleep 10
        waited=$((waited + 10))
    done

    print_info "Phase 7 complete: ClusterLinks created."
}

# ============================================================
# Phase 8: Validate Bidirectional Mirroring
# ============================================================
phase8_validate() {
    print_step "=== Phase 8: Validate Bidirectional Mirroring ==="
    echo ""
    echo "Running validation script..."
    echo ""

    if ! ask_yes_no "Run validation?"; then
        print_info "Skipped Phase 8."
        return
    fi

    "$SCRIPT_DIR/validate.sh" "$MODE"
}

# ============================================================
# Usage
# ============================================================
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "MRC Bidirectional Cluster Link (True Multi-Cluster, SASL-SSL, LoadBalancer)"
    echo "Central (<central-cluster>) <-> East (<east-cluster>)"
    echo ""
    echo "Modes (set via MODE env var, default: outbound):"
    echo "  MODE=outbound  Case 3: Both OUTBOUND, no firewall"
    echo "  MODE=private   Case 4: OUTBOUND + INBOUND, east behind firewall"
    echo ""
    echo "Commands:"
    echo "  (no args)    Run all phases sequentially (interactive)"
    echo "  outbound     Run all phases in outbound mode (Case 3)"
    echo "  private      Run all phases in private mode (Case 4)"
    echo "  secrets      Phase 1: Create secrets"
    echo "  kraft        Phase 2: Deploy KRaft controllers"
    echo "  kafka        Phase 3: Deploy Kafka clusters"
    echo "  dns          Phase 4: Wait for DNS resolution"
    echo "  restclass    Phase 5: Create KafkaRestClass"
    echo "  topics       Phase 6: Create topics"
    echo "  clusterlink  Phase 7: Create ClusterLinks"
    echo "  validate     Phase 8: Validate bidirectional mirroring"
    echo "  status       Show status of all resources on both clusters"
    echo ""
    echo "Prerequisites: TLS secrets (tls-kafka, tls-kraftcontroller, ca-pair-sslcerts)"
    echo "must be pre-deployed. All other secrets are created by Phase 1."
    echo ""
    exit 1
}

# ============================================================
# Show status
# ============================================================
show_status() {
    print_step "=== Cluster Status ==="
    echo ""

    print_info "=== Central ($CENTRAL_NS on <central-cluster>) ==="
    echo "KRaftController:"
    kube1 get kraftcontroller -n "$CENTRAL_NS" 2>/dev/null || echo "  Not found"
    echo "Kafka:"
    kube1 get kafka -n "$CENTRAL_NS" 2>/dev/null || echo "  Not found"
    echo "KafkaRestClass:"
    kube1 get kafkarestclass -n "$CENTRAL_NS" 2>/dev/null || echo "  Not found"
    echo "KafkaTopic:"
    kube1 get kafkatopic -n "$CENTRAL_NS" 2>/dev/null || echo "  Not found"
    echo "ClusterLink:"
    kube1 get clusterlink -n "$CENTRAL_NS" 2>/dev/null || echo "  Not found"
    echo "Pods:"
    kube1 get pods -n "$CENTRAL_NS" -o wide 2>/dev/null || echo "  No pods"
    echo ""

    print_info "=== East ($EAST_NS on <east-cluster>) ==="
    echo "KRaftController:"
    kube2 get kraftcontroller -n "$EAST_NS" 2>/dev/null || echo "  Not found"
    echo "Kafka:"
    kube2 get kafka -n "$EAST_NS" 2>/dev/null || echo "  Not found"
    echo "KafkaRestClass:"
    kube2 get kafkarestclass -n "$EAST_NS" 2>/dev/null || echo "  Not found"
    echo "KafkaTopic:"
    kube2 get kafkatopic -n "$EAST_NS" 2>/dev/null || echo "  Not found"
    echo "ClusterLink:"
    kube2 get clusterlink -n "$EAST_NS" 2>/dev/null || echo "  Not found"
    echo "Pods:"
    kube2 get pods -n "$EAST_NS" -o wide 2>/dev/null || echo "  No pods"
}

# ============================================================
# Run all phases
# ============================================================
run_all() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}  MRC Bidirectional Cluster Link (SASL-SSL)${NC}"
    echo -e "${BLUE}  True Multi-Cluster: Central <-> East${NC}"
    echo -e "${BLUE}  Mode: $MODE${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    echo "This script will set up bidirectional cluster linking between"
    echo "two separate GKE clusters with SASL-SSL security:"
    echo ""
    echo "  Central (<central-cluster>, us-central1):"
    echo "    - 3 KRaft controllers + 3 Kafka brokers"
    echo "    - central-topic (original, mirrored to east)"
    echo ""
    echo "  East (<east-cluster>, us-east4):"
    echo "    - 3 KRaft controllers + 3 Kafka brokers"
    echo "    - east-topic (original, mirrored to central)"
    echo ""
    echo "Security: TLS + SASL/PLAIN + Basic REST auth"
    echo "External access: LoadBalancer with ExternalDNS on ${DOMAIN}"
    echo ""

    phase1_create_secrets
    phase2_deploy_kraft
    phase3_deploy_kafka
    phase4_wait_dns
    phase5_create_restclass
    phase6_create_topics
    phase7_create_clusterlinks
    phase8_validate

    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}  Setup Complete!${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo ""
    echo "Bidirectional cluster linking established:"
    echo "  - central-topic: central -> east (mirror)"
    echo "  - east-topic: east -> central (mirror)"
    echo ""
    echo "Next steps:"
    echo "  1. Check status:  ./setup.sh status"
    echo "  2. Validate:      ./validate.sh"
    echo "  3. Teardown:      ./teardown.sh"
    echo ""
}

# ============================================================
# Main
# ============================================================
COMMAND="${1:-}"

case "$COMMAND" in
    outbound)    MODE=outbound; MODE_DIR="$MANIFESTS_DIR/bidirectional-cl/outbound-outbound"; run_all ;;
    private)     MODE=private; MODE_DIR="$MANIFESTS_DIR/bidirectional-cl/outbound-inbound"; run_all ;;
    secrets)     phase1_create_secrets ;;
    kraft)       phase2_deploy_kraft ;;
    kafka)       phase3_deploy_kafka ;;
    dns)         phase4_wait_dns ;;
    restclass)   phase5_create_restclass ;;
    topics)      phase6_create_topics ;;
    clusterlink) phase7_create_clusterlinks ;;
    validate)    phase8_validate ;;
    status)      show_status ;;
    "")          run_all ;;
    -h|--help|help) usage ;;
    *)           print_error "Unknown command: $COMMAND"; usage ;;
esac
