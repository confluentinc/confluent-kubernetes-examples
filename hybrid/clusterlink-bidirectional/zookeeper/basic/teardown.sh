#!/bin/bash
# Teardown script for Bidirectional Cluster Link - ZooKeeper Basic
set -e

SRC_NS="src"
DEST_NS="dest"

echo "=========================================="
echo "Tearing down Bidirectional Cluster Link"
echo "=========================================="

# Delete resources
for resource in clusterlink kafkatopic kafkarestclass kafka zookeeper; do
    echo "Deleting $resource..."
    kubectl delete $resource --all -n $SRC_NS --ignore-not-found=true
    kubectl delete $resource --all -n $DEST_NS --ignore-not-found=true
done

sleep 10

# Delete PVCs and secrets
echo "Deleting secrets..."
kubectl delete secret password-encoder-secret -n $SRC_NS --ignore-not-found=true
kubectl delete secret password-encoder-secret -n $DEST_NS --ignore-not-found=true

echo ""
echo "Teardown complete!"
echo ""
echo "Note: CFK is still installed. To uninstall CFK, run:"
echo "  ../../teardown_cfk.sh"

