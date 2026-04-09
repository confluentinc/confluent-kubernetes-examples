#!/bin/bash
set -e

SRC_NS="src"
DEST_NS="dest"

echo "Checking ClusterLink status..."
SRC_STATE=$(kubectl get clusterlink src-cluster-link -n $SRC_NS -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
DEST_STATE=$(kubectl get clusterlink dest-cluster-link -n $DEST_NS -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")

echo "Source: $SRC_STATE, Destination: $DEST_STATE"

if [[ "$SRC_STATE" != "CREATED" ]] || [[ "$DEST_STATE" != "CREATED" ]]; then
    echo "ERROR: ClusterLinks not ready"
    exit 1
fi

# Setup SASL config - DIFFERENT credentials for each cluster!
kubectl exec -n $SRC_NS kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="src-kafka" password="src-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF'

kubectl exec -n $DEST_NS kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="dest-kafka" password="dest-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF'

# Test forward mirroring
MSG="SASL-SSL-$(date +%s)"
echo "Testing forward mirroring..."
kubectl exec -n $SRC_NS kafka-0 -- bash -c "echo '$MSG' | kafka-console-producer --topic forward-topic --bootstrap-server kafka.$SRC_NS.svc.cluster.local:9071 --producer.config /tmp/client.properties"
sleep 5
CONSUMED=$(kubectl exec -n $DEST_NS kafka-0 -- kafka-console-consumer --topic forward-topic --bootstrap-server kafka.$DEST_NS.svc.cluster.local:9071 --consumer.config /tmp/client.properties --from-beginning --max-messages 1 --timeout-ms 30000 2>/dev/null | tail -1)

if [[ "$CONSUMED" == *"$MSG"* ]]; then
    echo "✓ Forward mirroring successful"
else
    echo "✗ Forward mirroring failed"
    exit 1
fi

echo "All validations passed!"

