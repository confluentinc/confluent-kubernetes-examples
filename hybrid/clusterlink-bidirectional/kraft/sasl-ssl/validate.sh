#!/bin/bash
# Validation script for Bidirectional Cluster Link - KRaft SASL-SSL
set -e

SRC_NS="src"
DEST_NS="dest"
FORWARD_TOPIC="forward-topic"
REVERSE_TOPIC="reverse-topic"
TEST_MESSAGE_FORWARD="SASL-SSL Forward $(date +%s)"
TEST_MESSAGE_REVERSE="SASL-SSL Reverse $(date +%s)"

echo "=========================================="
echo "Validating SASL-SSL Bidirectional Cluster Link"
echo "=========================================="

# Check ClusterLink status
echo ""
echo "Checking ClusterLink status..."
SRC_LINK_STATE=$(kubectl get clusterlink src-cluster-link -n $SRC_NS -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
DEST_LINK_STATE=$(kubectl get clusterlink dest-cluster-link -n $DEST_NS -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")

echo "  Source ClusterLink state: $SRC_LINK_STATE"
echo "  Destination ClusterLink state: $DEST_LINK_STATE"

if [[ "$SRC_LINK_STATE" != "CREATED" ]] || [[ "$DEST_LINK_STATE" != "CREATED" ]]; then
    echo ""
    echo "ERROR: ClusterLinks are not in 'Created' state yet."
    echo "Please wait for both links to become healthy."
    exit 1
fi

echo ""
echo "Both ClusterLinks are healthy!"

# Create SASL config for producer/consumer
# ⚠️ IMPORTANT: Use DIFFERENT credentials for src and dest clusters
echo ""
echo "Setting up SASL-SSL configuration..."

kubectl exec -n $SRC_NS kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
bootstrap.servers=kafka.src.svc.cluster.local:9071
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="src-kafka" password="src-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF'

kubectl exec -n $DEST_NS kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
bootstrap.servers=kafka.dest.svc.cluster.local:9071
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="dest-kafka" password="dest-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF'

# Test forward mirroring
echo ""
echo "=========================================="
echo "Testing Forward Mirroring (src -> dest)"
echo "=========================================="

echo "Producing SASL-authenticated message to $FORWARD_TOPIC on source cluster..."
kubectl exec -n $SRC_NS kafka-0 -- bash -c "echo '$TEST_MESSAGE_FORWARD' | kafka-console-producer --topic $FORWARD_TOPIC --bootstrap-server kafka.$SRC_NS.svc.cluster.local:9071 --producer.config /tmp/client.properties"

echo "Waiting for message to be mirrored..."
sleep 5

echo "Consuming from $FORWARD_TOPIC mirror on destination cluster..."
CONSUMED_FORWARD=$(kubectl exec -n $DEST_NS kafka-0 -- bash -c \
  "kafka-console-consumer \
     --topic $FORWARD_TOPIC \
     --bootstrap-server kafka.$DEST_NS.svc.cluster.local:9071 \
     --consumer.config /tmp/client.properties \
     --from-beginning \
     --max-messages 10 \
     --timeout-ms 30000 2>/dev/null | grep -m1 '$TEST_MESSAGE_FORWARD' || true")

if [[ -n "$CONSUMED_FORWARD" ]]; then
    echo "✅ Forward mirroring with SASL-SSL successful!"
else
    echo "❌ Forward mirroring failed!"
    echo "  Expected to see: $TEST_MESSAGE_FORWARD"
    exit 1
fi

# Test reverse mirroring
echo ""
echo "=========================================="
echo "Testing Reverse Mirroring (dest -> src)"
echo "=========================================="

echo "Producing SASL-authenticated message to $REVERSE_TOPIC on destination cluster..."
kubectl exec -n $DEST_NS kafka-0 -- bash -c "echo '$TEST_MESSAGE_REVERSE' | kafka-console-producer --topic $REVERSE_TOPIC --bootstrap-server kafka.$DEST_NS.svc.cluster.local:9071 --producer.config /tmp/client.properties"

echo "Waiting for message to be mirrored..."
sleep 5

echo "Consuming from $REVERSE_TOPIC mirror on source cluster..."
CONSUMED_REVERSE=$(kubectl exec -n $SRC_NS kafka-0 -- bash -c \
  "kafka-console-consumer \
     --topic $REVERSE_TOPIC \
     --bootstrap-server kafka.$SRC_NS.svc.cluster.local:9071 \
     --consumer.config /tmp/client.properties \
     --from-beginning \
     --max-messages 10 \
     --timeout-ms 30000 2>/dev/null | grep -m1 '$TEST_MESSAGE_REVERSE' || true")

if [[ -n "$CONSUMED_REVERSE" ]]; then
    echo "✅ Reverse mirroring with SASL-SSL successful!"
else
    echo "❌ Reverse mirroring failed!"
    echo "  Expected to see: $TEST_MESSAGE_REVERSE"
    exit 1
fi

echo ""
echo "=========================================="
echo "All SASL-SSL validations passed!"
echo "=========================================="

