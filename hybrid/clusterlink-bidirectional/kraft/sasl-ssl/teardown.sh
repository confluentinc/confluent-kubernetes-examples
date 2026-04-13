#!/bin/bash
# Teardown script for Bidirectional Cluster Link - KRaft SASL-SSL
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_NS="src"
DEST_NS="dest"
CERTS_DIR="$SCRIPT_DIR/certs"

echo "=========================================="
echo "Tearing down Bidirectional Cluster Link"
echo "=========================================="

# Delete ClusterLinks first
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

# Wait for resources to be deleted
echo "Waiting for resources to be cleaned up..."
sleep 10

# Delete PVCs
# Delete secrets
echo "Deleting secrets..."
for secret in password-encoder-secret credential rest-credential tls-certs src-tls-for-link dest-tls-for-link; do
    kubectl delete secret $secret -n $SRC_NS --ignore-not-found=true
    kubectl delete secret $secret -n $DEST_NS --ignore-not-found=true
done

# Clean up generated certificates
if [ -d "$CERTS_DIR" ]; then
    echo "Cleaning up generated certificates..."
    rm -rf "$CERTS_DIR"
fi

# Optionally delete namespaces
# echo "Deleting namespaces..."
# kubectl delete namespace $SRC_NS --ignore-not-found=true
# kubectl delete namespace $DEST_NS --ignore-not-found=true

echo ""
echo "=========================================="
echo "Teardown complete!"
echo "=========================================="

