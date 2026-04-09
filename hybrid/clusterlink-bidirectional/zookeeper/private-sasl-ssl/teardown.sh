#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo "Tearing down Private Cluster Bidirectional Link (ZooKeeper)"
echo "============================================================"

for ns in src dest; do
    echo "Cleaning up namespace: $ns"
    for resource in clusterlink kafkatopic kafkarestclass kafka zookeeper; do
        kubectl delete $resource --all -n $ns --ignore-not-found=true
    done
    kubectl delete secret tls-certs ca-pair-sslcerts credential rest-credential password-encoder-secret -n $ns --ignore-not-found=true
done

# Delete cross-namespace credential secrets
kubectl delete secret src-credential -n dest --ignore-not-found=true
kubectl delete secret dest-credential -n src --ignore-not-found=true

rm -rf "$SCRIPT_DIR/certs"
echo ""
echo "Teardown complete!"

