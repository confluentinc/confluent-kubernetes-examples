#!/bin/bash
# Teardown script for Bidirectional Cluster Link - KRaft Private SASL-SSL
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_NS="src"
DEST_NS="dest"
CERTS_DIR="$SCRIPT_DIR/certs"

echo "============================================================"
echo "Tearing down Private Cluster Bidirectional Link"
echo "============================================================"

# Delete ClusterLinks
echo "Deleting ClusterLinks..."
kubectl delete clusterlink --all -n $SRC_NS --ignore-not-found=true
kubectl delete clusterlink --all -n $DEST_NS --ignore-not-found=true

# Delete topics
echo "Deleting topics..."
kubectl delete kafkatopic --all -n $SRC_NS --ignore-not-found=true
kubectl delete kafkatopic --all -n $DEST_NS --ignore-not-found=true

# Delete KafkaRestClass
echo "Deleting KafkaRestClass..."
kubectl delete kafkarestclass --all -n $SRC_NS --ignore-not-found=true
kubectl delete kafkarestclass --all -n $DEST_NS --ignore-not-found=true

# Delete Kafka clusters
echo "Deleting Kafka clusters..."
kubectl delete kafka --all -n $SRC_NS --ignore-not-found=true
kubectl delete kafka --all -n $DEST_NS --ignore-not-found=true

# Delete KRaft controllers
echo "Deleting KRaft controllers..."
kubectl delete kraftcontroller --all -n $SRC_NS --ignore-not-found=true
kubectl delete kraftcontroller --all -n $DEST_NS --ignore-not-found=true

sleep 10

# Delete PVCs and secrets
echo "Deleting PVCs and secrets..."
for ns in $SRC_NS $DEST_NS; do
    kubectl delete secret tls-certs credential rest-credential password-encoder-secret ca-pair-sslcerts -n $ns --ignore-not-found=true
done

# Delete cross-namespace credential secrets
kubectl delete secret src-credential -n $DEST_NS --ignore-not-found=true
kubectl delete secret dest-credential -n $SRC_NS --ignore-not-found=true

# Clean up certificates
if [ -d "$CERTS_DIR" ]; then
    echo "Cleaning up certificates..."
    rm -rf "$CERTS_DIR"
fi

echo ""
echo "Teardown complete!"

