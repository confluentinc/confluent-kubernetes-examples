#!/bin/bash
# Validation script for Bidirectional Cluster Link - KRaft Basic
set -e

SRC_NS="src"
DEST_NS="dest"
FORWARD_TOPIC="forward-topic"
REVERSE_TOPIC="reverse-topic"
TEST_MESSAGE_FORWARD="Hello from source cluster - $(date +%s)"
TEST_MESSAGE_REVERSE="Hello from destination cluster - $(date +%s)"

echo "=========================================="
echo "Validating Bidirectional Cluster Link"
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
    echo "Please wait for both links to become healthy before running validation."
    echo ""
    echo "Monitor with:"
    echo "  kubectl get clusterlink -n $SRC_NS -w"
    echo "  kubectl get clusterlink -n $DEST_NS -w"
    exit 1
fi

echo ""
echo "Both ClusterLinks are healthy!"

# Test forward mirroring (source -> destination)
echo ""
echo "=========================================="
echo "Testing Forward Mirroring (src -> dest)"
echo "=========================================="

echo "Producing message to $FORWARD_TOPIC on source cluster..."
kubectl exec -n $SRC_NS kafka-0 -- bash -c "echo '$TEST_MESSAGE_FORWARD' | kafka-console-producer --topic $FORWARD_TOPIC --bootstrap-server kafka.$SRC_NS.svc.cluster.local:9092"

echo "Waiting for message to be mirrored..."
sleep 5

echo "Consuming from $FORWARD_TOPIC mirror on destination cluster..."
CONSUMED_FORWARD=$(kubectl exec -n $DEST_NS kafka-0 -- bash -c \
  "kafka-console-consumer \
     --topic $FORWARD_TOPIC \
     --bootstrap-server kafka.$DEST_NS.svc.cluster.local:9092 \
     --from-beginning \
     --max-messages 10 \
     --timeout-ms 30000 2>/dev/null | grep -m1 '$TEST_MESSAGE_FORWARD' || true")

if [[ -n "$CONSUMED_FORWARD" ]]; then
    echo "✅ Forward mirroring successful!"
else
    echo "❌ Forward mirroring failed!"
    echo "  Expected to see: $TEST_MESSAGE_FORWARD"
    exit 1
fi

# Test reverse mirroring (destination -> source)
echo ""
echo "=========================================="
echo "Testing Reverse Mirroring (dest -> src)"
echo "=========================================="

echo "Producing message to $REVERSE_TOPIC on destination cluster..."
kubectl exec -n $DEST_NS kafka-0 -- bash -c "echo '$TEST_MESSAGE_REVERSE' | kafka-console-producer --topic $REVERSE_TOPIC --bootstrap-server kafka.$DEST_NS.svc.cluster.local:9092"

echo "Waiting for message to be mirrored..."
sleep 5

echo "Consuming from $REVERSE_TOPIC mirror on source cluster..."
CONSUMED_REVERSE=$(kubectl exec -n $SRC_NS kafka-0 -- bash -c \
  "kafka-console-consumer \
     --topic $REVERSE_TOPIC \
     --bootstrap-server kafka.$SRC_NS.svc.cluster.local:9092 \
     --from-beginning \
     --max-messages 10 \
     --timeout-ms 30000 2>/dev/null | grep -m1 '$TEST_MESSAGE_REVERSE' || true")

if [[ -n "$CONSUMED_REVERSE" ]]; then
    echo "✅ Reverse mirroring successful!"
else
    echo "❌ Reverse mirroring failed!"
    echo "  Expected to see: $TEST_MESSAGE_REVERSE"
    exit 1
fi

echo ""
echo "=========================================="
echo "All validations passed!"
echo "=========================================="
echo ""
echo "Bidirectional cluster link is working correctly."
echo "- Forward mirroring: source -> destination ✓"
echo "- Reverse mirroring: destination -> source ✓"

