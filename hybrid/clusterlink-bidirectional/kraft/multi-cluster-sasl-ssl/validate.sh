#!/bin/bash
# Validation script for Multi-Cluster Bidirectional Cluster Link (SASL-SSL)
# Tests: link status, mirroring central-topic (central->east), mirroring east-topic (east->central)
#
# Usage: ./validate.sh [outbound|private]
set -e

# ============================================================
# Configuration
# ============================================================
MODE="${1:-outbound-outbound}"
CENTRAL_NS="${CENTRAL_NS:-central}"
EAST_NS="${EAST_NS:-east}"
CENTRAL_CONTEXT="${CENTRAL_CONTEXT:-<central-cluster-context>}"
EAST_CONTEXT="${EAST_CONTEXT:-<east-cluster-context>}"
CENTRAL_TOPIC="central-topic"
EAST_TOPIC="east-topic"

# Set link name based on mode
case "$MODE" in
    outbound-outbound) LINK_NAME="bidirectional-link" ;;
    outbound-inbound)  LINK_NAME="bidirectional-private-link" ;;
    *)        echo "ERROR: Invalid MODE '$MODE'. Must be 'outbound-outbound' or 'outbound-inbound'."; exit 1 ;;
esac

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

kube1() { kubectl --context "$CENTRAL_CONTEXT" "$@"; }
kube2() { kubectl --context "$EAST_CONTEXT" "$@"; }

# Create SASL-SSL client config on a pod
setup_client_config() {
    local ctx="$1" ns="$2" user="$3" pass="$4"
    kubectl --context "$ctx" exec -n "$ns" kafka-0 -c kafka -- bash -c "cat > /tmp/client.properties << PROPS
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$user\" password=\"$pass\";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
ssl.truststore.type=PKCS12
PROPS"
}

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}  Validating Bidirectional Cluster Link${NC}"
echo -e "${BLUE}  (SASL-SSL, Multi-Cluster, Mode: $MODE)${NC}"
echo -e "${BLUE}  Link name: $LINK_NAME${NC}"
echo -e "${BLUE}================================================${NC}"

# ============================================================
# Step 1: Setup client configs
# ============================================================
print_step "Setting up SASL-SSL client configs..."
setup_client_config "$CENTRAL_CONTEXT" "$CENTRAL_NS" "central-kafka" "<central-kafka-password>"
setup_client_config "$EAST_CONTEXT" "$EAST_NS" "east-kafka" "<east-kafka-password>"
print_info "Client configs created on both clusters."

# ============================================================
# Step 2: Describe ClusterLinks using kafka-cluster-links
# ============================================================
print_step "Describing ClusterLinks (kafka-cluster-links --describe)..."

echo ""
echo -e "${BLUE}--- Central cluster link ---${NC}"
kube1 exec -n "$CENTRAL_NS" kafka-0 -c kafka -- bash -c \
    "kafka-cluster-links --bootstrap-server kafka.$CENTRAL_NS.svc.cluster.local:9071 \
     --describe --link $LINK_NAME --command-config /tmp/client.properties 2>/dev/null"

echo ""
echo -e "${BLUE}--- East cluster link ---${NC}"
kube2 exec -n "$EAST_NS" kafka-0 -c kafka -- bash -c \
    "kafka-cluster-links --bootstrap-server kafka.$EAST_NS.svc.cluster.local:9071 \
     --describe --link $LINK_NAME --command-config /tmp/client.properties 2>/dev/null"

# ============================================================
# Step 3: List topics on both clusters
# ============================================================
print_step "Listing topics on both clusters..."

echo ""
echo -e "${BLUE}--- Central topics ---${NC}"
kube1 exec -n "$CENTRAL_NS" kafka-0 -c kafka -- bash -c \
    "kafka-topics --bootstrap-server kafka.$CENTRAL_NS.svc.cluster.local:9071 \
     --list --command-config /tmp/client.properties 2>/dev/null" | grep -v "^_"

echo ""
echo -e "${BLUE}--- East topics ---${NC}"
kube2 exec -n "$EAST_NS" kafka-0 -c kafka -- bash -c \
    "kafka-topics --bootstrap-server kafka.$EAST_NS.svc.cluster.local:9071 \
     --list --command-config /tmp/client.properties 2>/dev/null" | grep -v "^_"

# ============================================================
# Step 4: Test mirroring central-topic (central -> east)
# ============================================================
print_step "Testing: central-topic mirrored to east"

TEST_MSG_CENTRAL="central-test-$(date +%s)"
echo -e "  Producing: ${GREEN}$TEST_MSG_CENTRAL${NC} to $CENTRAL_TOPIC on central"

kube1 exec -n "$CENTRAL_NS" kafka-0 -c kafka -- bash -c \
    "echo '$TEST_MSG_CENTRAL' | kafka-console-producer \
     --bootstrap-server kafka.$CENTRAL_NS.svc.cluster.local:9071 \
     --topic $CENTRAL_TOPIC \
     --producer.config /tmp/client.properties 2>/dev/null"

print_info "Waiting 10s for mirror replication..."
sleep 10

echo -e "  Consuming from $CENTRAL_TOPIC mirror on east:"
CONSUMED=$(kube2 exec -n "$EAST_NS" kafka-0 -c kafka -- bash -c \
    "kafka-console-consumer \
     --bootstrap-server kafka.$EAST_NS.svc.cluster.local:9071 \
     --topic $CENTRAL_TOPIC \
     --from-beginning \
     --max-messages 20 \
     --timeout-ms 15000 \
     --consumer.config /tmp/client.properties 2>/dev/null")

echo -e "  ${BLUE}Messages on east mirror:${NC}"
echo "$CONSUMED" | while read -r line; do
    if [[ "$line" == "$TEST_MSG_CENTRAL" ]]; then
        echo -e "    ${GREEN}>>> $line  (THIS IS OUR TEST MESSAGE)${NC}"
    else
        echo "    $line"
    fi
done

if echo "$CONSUMED" | grep -q "$TEST_MSG_CENTRAL"; then
    RESULT_CENTRAL="PASS"
    echo -e "  ${GREEN}PASS${NC} Mirroring central-topic works!"
else
    RESULT_CENTRAL="FAIL"
    echo -e "  ${RED}FAIL${NC} Test message not found on east mirror"
fi

# ============================================================
# Step 5: Test mirroring east-topic (east -> central)
# ============================================================
print_step "Testing: east-topic mirrored to central"

TEST_MSG_EAST="east-test-$(date +%s)"
echo -e "  Producing: ${GREEN}$TEST_MSG_EAST${NC} to $EAST_TOPIC on east"

kube2 exec -n "$EAST_NS" kafka-0 -c kafka -- bash -c \
    "echo '$TEST_MSG_EAST' | kafka-console-producer \
     --bootstrap-server kafka.$EAST_NS.svc.cluster.local:9071 \
     --topic $EAST_TOPIC \
     --producer.config /tmp/client.properties 2>/dev/null"

print_info "Waiting 10s for mirror replication..."
sleep 10

echo -e "  Consuming from $EAST_TOPIC mirror on central:"
CONSUMED=$(kube1 exec -n "$CENTRAL_NS" kafka-0 -c kafka -- bash -c \
    "kafka-console-consumer \
     --bootstrap-server kafka.$CENTRAL_NS.svc.cluster.local:9071 \
     --topic $EAST_TOPIC \
     --from-beginning \
     --max-messages 20 \
     --timeout-ms 15000 \
     --consumer.config /tmp/client.properties 2>/dev/null")

echo -e "  ${BLUE}Messages on central mirror:${NC}"
echo "$CONSUMED" | while read -r line; do
    if [[ "$line" == "$TEST_MSG_EAST" ]]; then
        echo -e "    ${GREEN}>>> $line  (THIS IS OUR TEST MESSAGE)${NC}"
    else
        echo "    $line"
    fi
done

if echo "$CONSUMED" | grep -q "$TEST_MSG_EAST"; then
    RESULT_EAST="PASS"
    echo -e "  ${GREEN}PASS${NC} Mirroring east-topic works!"
else
    RESULT_EAST="FAIL"
    echo -e "  ${RED}FAIL${NC} Test message not found on central mirror"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}  Validation Summary${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo "  Mirroring central-topic (central -> east): ${RESULT_CENTRAL}"
echo "  Mirroring east-topic (east -> central): ${RESULT_EAST}"
echo ""

if [[ "$RESULT_CENTRAL" == "FAIL" ]] || [[ "$RESULT_EAST" == "FAIL" ]]; then
    print_error "Some validations failed."
    exit 1
else
    print_info "All validations passed! Bidirectional cluster linking working."
fi
