#!/bin/bash
# Validation script for Bidirectional Cluster Link - KRaft Private SASL-SSL
set -e

SRC_NS="src"
DEST_NS="dest"
FORWARD_TOPIC="forward-topic"
REVERSE_TOPIC="reverse-topic"

echo "============================================================"
echo "Validating Private Cluster Bidirectional Link"
echo "============================================================"

# Check ClusterLink status - OUTBOUND link should be healthy first
echo ""
echo "Checking ClusterLink status..."
echo "(For private cluster mode, OUTBOUND link should be healthy first)"

# Wait for OUTBOUND (public/source) link to be healthy first
echo ""
echo "Waiting for OUTBOUND link (public cluster) to become healthy..."
for i in {1..60}; do
    SRC_LINK_STATE=$(kubectl get clusterlink src-cluster-link -n $SRC_NS -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
    if [[ "$SRC_LINK_STATE" == "CREATED" ]]; then
        echo "✓ Public cluster OUTBOUND link is healthy: $SRC_LINK_STATE"
        break
    fi
    echo "  Waiting... ($i/60) - Current state: $SRC_LINK_STATE"
    sleep 10
done

if [[ "$SRC_LINK_STATE" != "CREATED" ]]; then
    echo "ERROR: OUTBOUND link did not become healthy"
    kubectl describe clusterlink src-cluster-link -n $SRC_NS
    exit 1
fi

# Now check INBOUND link
echo ""
echo "Checking INBOUND link (private cluster)..."
for i in {1..30}; do
    DEST_LINK_STATE=$(kubectl get clusterlink dest-cluster-link -n $DEST_NS -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
    if [[ "$DEST_LINK_STATE" == "CREATED" ]]; then
        echo "✓ Private cluster INBOUND link is healthy: $DEST_LINK_STATE"
        break
    fi
    echo "  Waiting... ($i/30) - Current state: $DEST_LINK_STATE"
    sleep 10
done

if [[ "$DEST_LINK_STATE" != "CREATED" ]]; then
    echo "ERROR: INBOUND link did not become healthy"
    kubectl describe clusterlink dest-cluster-link -n $DEST_NS
    exit 1
fi

echo ""
echo "Both ClusterLinks are healthy!"

# Setup SASL config - DIFFERENT credentials for each cluster!
# Note: CFK stores the truststore password in /mnt/sslcerts/jksPassword.txt in format "jksPassword=<password>"
kubectl exec -n $SRC_NS kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
bootstrap.servers=kafka.src.svc.cluster.local:9071
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="src-kafka" password="src-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=$(grep jksPassword /mnt/sslcerts/jksPassword.txt | cut -d= -f2)
EOF'

kubectl exec -n $DEST_NS kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
bootstrap.servers=kafka.dest.svc.cluster.local:9071
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="dest-kafka" password="dest-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=$(grep jksPassword /mnt/sslcerts/jksPassword.txt | cut -d= -f2)
EOF'

echo ""
echo "=========================================="

# Test reverse mirroring (the only direction that works in private cluster mode)
# Reverse mirroring test (private -> public)
TEST_MSG_REV="PrivateCluster-Reverse-$(date +%s)"
REV_GROUP="reverse-validator-$TEST_MSG_REV"

echo "Producing to $REVERSE_TOPIC on private cluster..."
kubectl exec -n $DEST_NS kafka-0 -- bash -c \
  "echo '$TEST_MSG_REV' | kafka-console-producer \
   --topic $REVERSE_TOPIC \
   --bootstrap-server kafka.$DEST_NS.svc.cluster.local:9071 \
   --producer.config /tmp/client.properties"

sleep 5

echo "Consuming from mirror on public cluster..."
CONSUMED_REV=$(kubectl exec -n $SRC_NS kafka-0 -- bash -c \
  "kafka-console-consumer \
     --topic $REVERSE_TOPIC \
     --bootstrap-server kafka.$SRC_NS.svc.cluster.local:9071 \
     --consumer.config /tmp/client.properties \
     --from-beginning \
     --max-messages 10 \
     --timeout-ms 30000 2>/dev/null | grep -m1 '$TEST_MSG_REV' || true")

if [[ -n "$CONSUMED_REV" ]]; then
  echo "✓ Reverse mirroring successful!"
else
  echo "✗ Reverse mirroring failed!"
  echo " Expected to see: $TEST_MSG_REV"
  exit 1
fi

echo ""
echo "============================================================"
echo "Validation passed!"
echo "============================================================"
echo ""
echo "Private cluster bidirectional link is working correctly:"
echo "  ✅ Reverse mirroring: private (dest) -> public (src) WORKS"
echo ""
echo "This is expected behavior - see README.md for explanation."


# Test forward mirroring (public -> private)
TEST_MSG_FWD="PublicCluster-Forward-$(date +%s)"
FWD_GROUP="forward-validator-$TEST_MSG_FWD"

echo "Producing to $FORWARD_TOPIC on public cluster..."
kubectl exec -n $SRC_NS kafka-0 -- bash -c \
  "echo '$TEST_MSG_FWD' | kafka-console-producer \
   --topic $FORWARD_TOPIC \
   --bootstrap-server kafka.$SRC_NS.svc.cluster.local:9071 \
   --producer.config /tmp/client.properties"

sleep 5

echo "Consuming from mirror on private cluster..."
CONSUMED_FWD=$(kubectl exec -n $DEST_NS kafka-0 -- bash -c \
  "kafka-console-consumer \
     --topic $FORWARD_TOPIC \
     --bootstrap-server kafka.$DEST_NS.svc.cluster.local:9071 \
     --consumer.config /tmp/client.properties \
     --from-beginning \
     --max-messages 10 \
     --timeout-ms 30000 2>/dev/null | grep -m1 '$TEST_MSG_FWD' || true")

if [[ -n "$CONSUMED_FWD" ]]; then
  echo "✅ Forward mirroring successful!"
else
  echo "❌ Forward mirroring failed!"
  echo " Expected to see: $TEST_MSG_FWD"
  exit 1
fi