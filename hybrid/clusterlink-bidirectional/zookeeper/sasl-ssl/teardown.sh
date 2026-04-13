#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for ns in src dest; do
    for resource in clusterlink kafkatopic kafkarestclass kafka zookeeper; do
        kubectl delete $resource --all -n $ns --ignore-not-found=true
    done
    kubectl delete secret tls-certs ca-pair-sslcerts credential rest-credential password-encoder-secret -n $ns --ignore-not-found=true
done

rm -rf "$SCRIPT_DIR/certs"
echo "Teardown complete!"

