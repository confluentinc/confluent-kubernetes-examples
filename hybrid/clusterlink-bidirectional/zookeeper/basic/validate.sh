#!/bin/bash
# Validation script for Bidirectional Cluster Link - ZooKeeper Basic
set -e

SRC_NS="src"
DEST_NS="dest"
FORWARD_TOPIC="forward-topic"
REVERSE_TOPIC="reverse-topic"

echo "=========================================="
echo "Validating Bidirectional Cluster Link"
echo "=========================================="

# Check status
SRC_STATE=$(kubectl get clusterlink src-cluster-link -n $SRC_NS -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
DEST_STATE=$(kubectl get clusterlink dest-cluster-link -n $DEST_NS -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")

echo "Source ClusterLink: $SRC_STATE"
echo "Destination ClusterLink: $DEST_STATE"

if [[ "$SRC_STATE" != "CREATED" ]] || [[ "$DEST_STATE" != "CREATED" ]]; then
    echo "ERROR: ClusterLinks not ready"
    exit 1
fi

# Test forward mirroring
MSG_FWD="ZK-Forward-$(date +%s)"
echo ""
echo "Testing forward mirroring..."
kubectl exec -n $SRC_NS kafka-0 -- bash -c "echo '$MSG_FWD' | kafka-console-producer --topic $FORWARD_TOPIC --bootstrap-server kafka.$SRC_NS.svc.cluster.local:9092"
sleep 5
CONSUMED=$(kubectl exec -n $DEST_NS kafka-0 -- kafka-console-consumer --topic $FORWARD_TOPIC --bootstrap-server kafka.$DEST_NS.svc.cluster.local:9092 --from-beginning --max-messages 1 --timeout-ms 30000 2>/dev/null | tail -1)

if [[ "$CONSUMED" == "$MSG_FWD" ]]; then
    echo "✓ Forward mirroring successful"
else
    echo "✗ Forward mirroring failed"
    exit 1
fi

# Test reverse mirroring
MSG_REV="ZK-Reverse-$(date +%s)"
echo ""
echo "Testing reverse mirroring..."
kubectl exec -n $DEST_NS kafka-0 -- bash -c "echo '$MSG_REV' | kafka-console-producer --topic $REVERSE_TOPIC --bootstrap-server kafka.$DEST_NS.svc.cluster.local:9092"
sleep 5
CONSUMED=$(kubectl exec -n $SRC_NS kafka-0 -- kafka-console-consumer --topic $REVERSE_TOPIC --bootstrap-server kafka.$SRC_NS.svc.cluster.local:9092 --from-beginning --max-messages 1 --timeout-ms 30000 2>/dev/null | tail -1)

if [[ "$CONSUMED" == "$MSG_REV" ]]; then
    echo "✓ Reverse mirroring successful"
else
    echo "✗ Reverse mirroring failed"
    exit 1
fi

echo ""
echo "All validations passed!"

