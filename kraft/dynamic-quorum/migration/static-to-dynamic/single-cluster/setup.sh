#!/bin/bash
# Static to Dynamic Quorum Migration Script (Path C)
# Migrates KRaft from kraft.version=0 (static) to kraft.version=1 (dynamic)
# Requires CP 8.0+

set -e

NAMESPACE="${NAMESPACE:-confluent}"
KRAFTCONTROLLER_NAME="${KRAFTCONTROLLER_NAME:-kraftcontroller}"
KAFKA_NAME="${KAFKA_NAME:-kafka}"
TEST_TOPIC="migration-test"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Print command, ask Y/n, execute or skip.
# If something fails mid-run, re-run the script and answer "n" to skip
# already-completed commands, then "y" to resume from where it failed.
run_cmd() {
    echo ""
    echo -e "${BLUE}  \$ $*${NC}"
    read -p "$(echo -e "${YELLOW}  Run? [Y/n]${NC} > ")" -r
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo_info "  Skipped."
        return 0
    fi
    "$@"
}

# Print and execute a command without prompting (for read-only verification commands).
show_cmd() {
    echo -e "${BLUE}  \$ $*${NC}"
    echo -e "${YELLOW}  Running...${NC}"
    "$@"
}

usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Static to Dynamic Quorum Migration — Path C (kraft.version 0 -> 1)"
    echo ""
    echo "Commands:"
    echo "  (no args)    Run all phases sequentially (interactive, asks y/n at each command)"
    echo "  phase0       Deploy static quorum cluster (kraft.version=0)"
    echo "  phase1       Upgrade kraft.version 0 -> 1 via kafka-features CLI (no YAML change)"
    echo "  phase2       Switch KRaft to dynamicQuorumConfig (CFK generates bootstrap.servers)"
    echo "  phase3       Force-roll Kafka to pick up bootstrap.servers"
    echo "  verify       Verify dynamic quorum works (remove + re-add controller)"
    echo "  status       Show kraft.version and quorum status"
    echo ""
    echo "Typical flow:"
    echo "  ./pre-setup.sh          # One-time: namespace, secrets, operator"
    echo "  ./setup.sh              # Runs all phases interactively"
    echo "  ./cleanup.sh            # Phased teardown"
    echo ""
    echo "Or run individual phases:"
    echo "  ./setup.sh phase0"
    echo "  ./setup.sh phase1"
    echo "  ./setup.sh phase2"
    echo "  ./setup.sh phase3"
    echo "  ./setup.sh verify"
    echo ""
    echo "Environment variables:"
    echo "  NAMESPACE            Kubernetes namespace (default: confluent)"
    echo "  KRAFTCONTROLLER_NAME Name of KRaftController (default: kraftcontroller)"
    exit 1
}

# Run all phases sequentially
run_all() {
    phase0
    phase1
    phase2
    phase3
    verify
    echo ""
    echo_info "All phases complete. Migration from kraft.version=0 to 1 is done."
    echo_info "Run ./cleanup.sh when ready to tear down."
}

wait_for_kraftcontroller_ready() {
    echo_info "Waiting for KRaftController to be ready (may take a while if rolling)..."
    run_cmd kubectl wait --for=condition=platform.confluent.io/cluster-ready \
        kraftcontroller/"$KRAFTCONTROLLER_NAME" -n "$NAMESPACE" --timeout=10m
}

wait_for_kafka_ready() {
    echo_info "Waiting for Kafka to be ready (may take a while if rolling)..."
    run_cmd kubectl wait --for=condition=platform.confluent.io/cluster-ready \
        kafka/kafka -n "$NAMESPACE" --timeout=10m
}

get_kraft_version() {
    show_cmd kubectl exec "${KRAFTCONTROLLER_NAME}-0" -n "$NAMESPACE" -- \
        kafka-features --bootstrap-controller localhost:9074 describe 2>/dev/null \
        | grep kraft.version || echo "  (unable to retrieve kraft.version)"
}

get_quorum_status() {
    show_cmd kubectl exec "${KRAFTCONTROLLER_NAME}-0" -n "$NAMESPACE" -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        describe --status 2>/dev/null || echo "  (unable to retrieve quorum status)"
}

get_replication_info() {
    show_cmd kubectl exec "${KRAFTCONTROLLER_NAME}-0" -n "$NAMESPACE" -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        describe --replication 2>/dev/null || echo "  (unable to retrieve replication info)"
}

# Validate data: create topic, produce, consume
# Usage: validate_data <phase_label>
validate_data() {
    local phase_label="$1"
    local msg="phase=${phase_label},ts=$(date +%s)"

    echo_info "=== Data Validation ($phase_label) ==="

    # Create topic if it doesn't exist
    echo_info "Ensuring topic '$TEST_TOPIC' exists..."
    run_cmd kubectl exec "${KAFKA_NAME}-0" -n "$NAMESPACE" -- \
        kafka-topics --bootstrap-server localhost:9092 \
        --create --topic "$TEST_TOPIC" --partitions 3 --replication-factor 3 \
        --if-not-exists 2>/dev/null || true

    # Produce a message
    echo_info "Producing message: $msg"
    run_cmd kubectl exec "${KAFKA_NAME}-0" -n "$NAMESPACE" -- \
        sh -c "echo '$msg' | kafka-console-producer --bootstrap-server localhost:9092 --topic $TEST_TOPIC" 2>/dev/null

    # Consume all messages (from beginning, with timeout)
    echo_info "Consuming messages from '$TEST_TOPIC'..."
    CONSUMED=$(run_cmd kubectl exec "${KAFKA_NAME}-0" -n "$NAMESPACE" -- \
        kafka-console-consumer --bootstrap-server localhost:9092 \
        --topic "$TEST_TOPIC" --from-beginning --timeout-ms 10000 2>/dev/null) || true

    if echo "$CONSUMED" | grep -q "$phase_label"; then
        echo_info "Data validation passed — produced and consumed successfully"
    else
        echo_warn "Could not verify message consumption (may need more time)"
    fi

    # Show message count
    local count
    count=$(echo "$CONSUMED" | grep -c "phase=" 2>/dev/null) || count=0
    echo_info "Total messages consumed: $count"
    echo ""
}

# Phase 0: Deploy static quorum cluster
phase0() {
    echo_step "=== Phase 0: Deploy Static Quorum Cluster ==="
    echo ""
    echo "This will:"
    echo "  - Deploy KRaftController with static quorum (kraft.version=0)"
    echo "  - Deploy Kafka brokers"
    echo "  - Verify kraft.version=0"
    echo "  - Confirm remove-controller fails (static quorum doesn't support it)"

    # Deploy KRaftController (static quorum)
    echo_info "Deploying KRaftController with static quorum..."
    run_cmd kubectl apply -f "$SCRIPT_DIR/resources/kraftcontroller-phase0-static.yaml" -n "$NAMESPACE"
    wait_for_kraftcontroller_ready

    # Deploy Kafka
    echo_info "Deploying Kafka brokers..."
    run_cmd kubectl apply -f "$SCRIPT_DIR/resources/kafka.yaml" -n "$NAMESPACE"
    wait_for_kafka_ready

    # Verify kraft.version=0
    echo ""
    echo_info "=== Verification ==="
    echo_info "kraft.version:"
    get_kraft_version
    echo ""

    # Show replication info (lists all controllers with their IDs and directory IDs)
    echo_info "Quorum replication info:"
    get_replication_info
    echo ""

    # Get a real controller ID and directory ID to test remove-controller
    echo_info "Testing remove-controller (should FAIL on static quorum)..."
    REPLICATION_OUTPUT=$(kubectl exec "${KRAFTCONTROLLER_NAME}-0" -n "$NAMESPACE" -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        describe --replication 2>/dev/null) || true

    # Parse the last controller's ID and directory ID (controllers have IDs >= 9990, brokers are lower)
    REMOVE_ID=$(echo "$REPLICATION_OUTPUT" | awk 'NR>1 && $1>=9990 {id=$1} END{print id}')
    REMOVE_DIR_ID=$(echo "$REPLICATION_OUTPUT" | awk -v rid="$REMOVE_ID" 'NR>1 && $1==rid {print $2}')

    if [[ -n "$REMOVE_ID" && -n "$REMOVE_DIR_ID" ]]; then
        echo_info "Using controller-id=$REMOVE_ID, directory-id=$REMOVE_DIR_ID"
        if run_cmd kubectl exec "${KRAFTCONTROLLER_NAME}-0" -n "$NAMESPACE" -- \
            kafka-metadata-quorum --bootstrap-controller localhost:9074 \
            remove-controller --controller-id "$REMOVE_ID" --controller-directory-id "$REMOVE_DIR_ID" 2>&1; then
            echo_warn "remove-controller unexpectedly succeeded"
        else
            echo_info "remove-controller correctly failed — static quorum does not support dynamic operations"
        fi
    else
        echo_warn "Could not parse controller IDs from replication output, skipping remove-controller test"
    fi
    echo ""

    # Produce and consume to validate data path
    validate_data "phase0"

    echo_info "Phase 0 complete. Static quorum cluster is running."
}

# Phase 1: Upgrade kraft.version to 1 (metadata-level only, no YAML change)
phase1() {
    echo_step "=== Phase 1: Upgrade kraft.version=0 -> 1 ==="
    echo ""
    echo "This will:"
    echo "  - Run kafka-features upgrade --feature kraft.version=1"
    echo "  - This is a metadata-level upgrade — no YAML change needed"
    echo "  - The quorum is now capable of dynamic operations"

    echo_info "Current kraft.version:"
    get_kraft_version
    echo ""

    echo_info "Upgrading kraft.version to 1..."
    run_cmd kubectl exec "${KRAFTCONTROLLER_NAME}-0" -n "$NAMESPACE" -- \
        kafka-features --bootstrap-controller localhost:9074 \
        upgrade --feature kraft.version=1

    echo ""
    echo_info "=== Verification ==="
    echo_info "kraft.version (should be 1):"
    get_kraft_version
    echo ""
    echo_info "Quorum status:"
    get_quorum_status

    echo ""

    # Produce and consume to validate data path after kraft.version upgrade
    validate_data "phase1"

    echo_info "Phase 1 complete. kraft.version=1 — metadata upgrade done."
}

# Phase 2: Switch KRaft to dynamicQuorumConfig
phase2() {
    echo_step "=== Phase 2: Switch KRaft to dynamicQuorumConfig ==="
    echo ""
    echo "This will:"
    echo "  - Apply KRaftController with dynamicQuorumConfig.enabled: true"
    echo "  - CFK generates controller.quorum.bootstrap.servers (replaces voters)"
    echo "  - Triggers a rolling restart of KRaft controllers"

    echo_info "Applying KRaftController with dynamicQuorumConfig..."
    run_cmd kubectl apply -f "$SCRIPT_DIR/resources/kraftcontroller-phase2-dynamic.yaml" -n "$NAMESPACE"
    wait_for_kraftcontroller_ready

    # Verify
    echo ""
    echo_info "=== Verification ==="
    echo_info "kraft.version (should be 1):"
    get_kraft_version
    echo ""
    echo_info "Quorum status:"
    get_quorum_status

    echo ""

    # Produce and consume to validate data path after switching to dynamic config
    validate_data "phase2"

    echo_info "Phase 2 complete. KRaft controllers now use bootstrap.servers."
}

# Phase 3: Force-roll Kafka to pick up bootstrap.servers
phase3() {
    echo_step "=== Phase 3: Roll Kafka to Pick Up bootstrap.servers ==="
    echo ""
    echo "This will:"
    echo "  - Patch Kafka with kafkacluster-manual-roll annotation to force a rolling restart"
    echo "  - Kafka brokers pick up the new controller.quorum.bootstrap.servers config"
    echo "  - Wait for Kafka to be ready"

    echo_info "Triggering Kafka rolling restart via manual-roll annotation..."
    run_cmd kubectl patch kafka kafka -n "$NAMESPACE" --type merge \
        -p '{"spec":{"podTemplate":{"annotations":{"kafkacluster-manual-roll":"phase3"}}}}'
    wait_for_kafka_ready

    # Verify
    echo ""
    echo_info "=== Verification ==="
    echo_info "kraft.version (should be 1):"
    get_kraft_version
    echo ""
    echo_info "Quorum status:"
    get_quorum_status

    echo ""

    # Produce and consume to validate data path after Kafka roll
    validate_data "phase3"

    echo_info "Phase 3 complete. Kafka brokers rolled with bootstrap.servers. Dynamic quorum fully active."
}

# Verify: Prove dynamic quorum works
verify() {
    echo_step "=== Verify: Dynamic Quorum Operations ==="
    echo ""
    echo "This will:"
    echo "  - Show current quorum status"
    echo "  - Remove kraftcontroller-2 from the quorum"
    echo "  - Verify it was removed"
    echo "  - Re-add kraftcontroller-2 to restore quorum"
    echo "  - Verify it was re-added"

    echo_info "Current quorum status:"
    get_quorum_status
    echo ""

    # Get all controller IDs via describe --replication
    echo_info "Quorum replication info (shows controller IDs and directory IDs):"
    get_replication_info
    echo ""

    # Parse the last controller's ID and directory ID for removal
    REPLICATION_OUTPUT=$(kubectl exec "${KRAFTCONTROLLER_NAME}-0" -n "$NAMESPACE" -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        describe --replication 2>/dev/null) || true

    # Parse the last controller's ID and directory ID (controllers have IDs >= 9990, brokers are lower)
    REMOVE_ID=$(echo "$REPLICATION_OUTPUT" | awk 'NR>1 && $1>=9990 {id=$1} END{print id}')
    REMOVE_DIR_ID=$(echo "$REPLICATION_OUTPUT" | awk -v rid="$REMOVE_ID" 'NR>1 && $1==rid {print $2}')

    if [[ -n "$REMOVE_ID" && -n "$REMOVE_DIR_ID" ]]; then
        echo_info "Will attempt to remove controller-id=$REMOVE_ID, directory-id=$REMOVE_DIR_ID"
        echo ""

        echo_info "Step 1: Remove controller from quorum"
        run_cmd kubectl exec "${KRAFTCONTROLLER_NAME}-0" -n "$NAMESPACE" -- \
            kafka-metadata-quorum --bootstrap-controller localhost:9074 \
            remove-controller --controller-id "$REMOVE_ID" --controller-directory-id "$REMOVE_DIR_ID"

        echo ""
        echo_info "Step 2: Verify removal"
        get_replication_info
        echo ""

        echo_info "Step 3: Re-add the controller (run FROM the removed pod)"
        echo_warn "Determine which pod had controller-id=$REMOVE_ID, then run add-controller from it."
        echo ""
        echo "  kubectl exec <removed-pod> -n $NAMESPACE -- \\"
        echo "    kafka-metadata-quorum --bootstrap-controller \\"
        echo "    ${KRAFTCONTROLLER_NAME}-0.${KRAFTCONTROLLER_NAME}.${NAMESPACE}.svc.cluster.local:9074 \\"
        echo "    add-controller"
        echo ""
        echo "  # Then verify:"
        echo "  ./setup.sh status"
    else
        echo_warn "Could not parse controller IDs from replication output."
        echo_warn "Run manually: ./setup.sh status"
    fi
}

# Show status
show_status() {
    echo_step "=== Cluster Status ==="
    echo ""

    echo_info "KRaftController:"
    show_cmd kubectl get kraftcontroller "$KRAFTCONTROLLER_NAME" -n "$NAMESPACE" 2>/dev/null || echo_warn "KRaftController not found"
    echo ""

    echo_info "Kafka:"
    show_cmd kubectl get kafka kafka -n "$NAMESPACE" 2>/dev/null || echo_warn "Kafka not found"
    echo ""

    echo_info "Pods:"
    show_cmd kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo_warn "No pods found"
    echo ""

    echo_info "kraft.version:"
    get_kraft_version
    echo ""

    echo_info "Quorum status:"
    get_quorum_status
}

# Main
COMMAND="${1:-}"

case "$COMMAND" in
    phase0)
        phase0
        ;;
    phase1)
        phase1
        ;;
    phase2)
        phase2
        ;;
    phase3)
        phase3
        ;;
    verify)
        verify
        ;;
    status)
        show_status
        ;;
    "")
        run_all
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo_error "Unknown command: $COMMAND"
        usage
        ;;
esac
