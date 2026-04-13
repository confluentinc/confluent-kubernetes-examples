#!/bin/bash
set -e

SRC_NS="src"
DEST_NS="dest"
REVERSE_TOPIC="reverse-topic"

echo "============================================================"
echo "Validating Private Cluster Bidirectional Link (ZooKeeper)"
echo "============================================================"

# Wait for OUTBOUND link first
echo ""
echo "Waiting for OUTBOUND link (public cluster)..."
for i in {1..60}; do
    SRC_STATE=$(kubectl get clusterlink src-cluster-link -n $SRC_NS -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
    if [[ "$SRC_STATE" == "CREATED" ]]; then
        echo "✓ OUTBOUND link healthy: $SRC_STATE"
        break
    fi
    echo "  Waiting... ($i/60) - State: $SRC_STATE"
    sleep 10
done

if [[ "$SRC_STATE" != "CREATED" ]]; then
    echo "ERROR: OUTBOUND link not healthy"
    exit 1
fi

# Check INBOUND link
echo ""
echo "Checking INBOUND link (private cluster)..."
for i in {1..30}; do
    DEST_STATE=$(kubectl get clusterlink dest-cluster-link -n $DEST_NS -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
    if [[ "$DEST_STATE" == "CREATED" ]]; then
        echo "✓ INBOUND link healthy: $DEST_STATE"
        break
    fi
    echo "  Waiting... ($i/30) - State: $DEST_STATE"
    sleep 10
done

if [[ "$DEST_STATE" != "CREATED" ]]; then
    echo "ERROR: INBOUND link not healthy"
    exit 1
fi

echo ""
echo "Both links healthy!"

# Setup SASL config - DIFFERENT credentials for each cluster!
# Note: CFK stores the truststore password in /mnt/sslcerts/jksPassword.txt in format "jksPassword=<password>"
kubectl exec -n $SRC_NS kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="src-kafka" password="src-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=$(grep jksPassword /mnt/sslcerts/jksPassword.txt | cut -d= -f2)
EOF'

kubectl exec -n $DEST_NS kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="dest-kafka" password="dest-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=$(grep jksPassword /mnt/sslcerts/jksPassword.txt | cut -d= -f2)
EOF'

# NOTE: Forward mirroring (public -> private) is NOT possible in private cluster mode
# because creating a mirror topic requires the destination to describe the source topic,
# and the INBOUND cluster cannot reach the remote cluster.
echo ""
echo "=========================================="
echo "NOTE: Forward mirroring (public -> private) is NOT possible"
echo "in private cluster mode - skipping forward mirroring test"
echo "=========================================="

# Test reverse mirroring (the only direction that works in private cluster mode)
MSG="PrivateZK-Reverse-$(date +%s)"
echo ""
echo "=========================================="
echo "Testing Reverse Mirroring (private -> public)"
echo "=========================================="

echo "Producing to $REVERSE_TOPIC on private cluster..."
kubectl exec -n $DEST_NS kafka-0 -- bash -c "echo '$MSG' | kafka-console-producer --topic $REVERSE_TOPIC --bootstrap-server kafka.$DEST_NS.svc.cluster.local:9071 --producer.config /tmp/client.properties"

sleep 5

echo "Consuming from mirror on public cluster..."
CONSUMED=$(kubectl exec -n $SRC_NS kafka-0 -- kafka-console-consumer --topic $REVERSE_TOPIC --bootstrap-server kafka.$SRC_NS.svc.cluster.local:9071 --consumer.config /tmp/client.properties --from-beginning --max-messages 1 --timeout-ms 30000 2>/dev/null | tail -1)

if [[ "$CONSUMED" == *"$MSG"* ]]; then
    echo "✓ Reverse mirroring successful!"
else
    echo "✗ Reverse mirroring failed!"
    echo "  Expected: $MSG"
    echo "  Got: $CONSUMED"
    exit 1
fi

echo ""
echo "============================================================"
echo "Validation passed!"
echo "============================================================"
echo ""
echo "Private cluster bidirectional link is working correctly:"
echo "  ✅ Reverse mirroring: private (dest) -> public (src) WORKS"
echo "  ❌ Forward mirroring: NOT possible in private cluster mode"
echo ""
echo "This is expected behavior - see README.md for explanation."

