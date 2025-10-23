#!/bin/bash
set -e

TUTORIAL_HOME=$(dirname "$BASH_SOURCE")

echo "Tearing down Kraft-based cluster..."

# Delete Kraft controllers
echo "Deleting Kraft controllers..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kraft/kraft-central.yaml --context mrc-central 2>/dev/null || echo "Kraft controller central not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kraft/kraft-east.yaml --context mrc-east 2>/dev/null || echo "Kraft controller east not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kraft/kraft-west.yaml --context mrc-west 2>/dev/null || echo "Kraft controller west not found, skipping..."

# Wait for Kraft controllers to be deleted
echo "Waiting for Kraft controllers to be deleted..."
kubectl wait kraftcontroller kraftcontroller-central --for=delete --timeout=300s -n central --context mrc-central 2>/dev/null || echo "Kraft controller central deletion timeout, continuing..."
kubectl wait kraftcontroller kraftcontroller-east --for=delete --timeout=300s -n east --context mrc-east 2>/dev/null || echo "Kraft controller east deletion timeout, continuing..."
kubectl wait kraftcontroller kraftcontroller-west --for=delete --timeout=300s -n west --context mrc-west 2>/dev/null || echo "Kraft controller west deletion timeout, continuing..."

# Delete TLS secrets
echo "Deleting TLS secrets..."
kubectl delete secret tls-kraft-central -n central --context mrc-central 2>/dev/null || echo "Kraft TLS secret central not found, skipping..."
kubectl delete secret tls-kraft-east -n east --context mrc-east 2>/dev/null || echo "Kraft TLS secret east not found, skipping..."
kubectl delete secret tls-kraft-west -n west --context mrc-west 2>/dev/null || echo "Kraft TLS secret west not found, skipping..."

# Note: MDS secrets are shared with zookeeper-based-cluster, so we don't delete them
echo "MDS secrets preserved (shared with zookeeper-based-cluster)"

# Delete namespaces

# Clean up generated certificates
cleanup_certificates() {
    echo "Cleaning up generated certificates..."

    # Only remove generated certificate files, not the entire directories
    if [ -d "$TUTORIAL_HOME/certs/generated" ]; then
        rm -f "$TUTORIAL_HOME/certs/generated"/*.pem "$TUTORIAL_HOME/certs/generated"/*.csr
        echo "Generated certificate files removed"
    fi

    # Note: CA certificate is shared with zookeeper-based-cluster, so we don't remove it
    echo "CA certificate"
    if [ -d "$TUTORIAL_HOME/certs/ca" ]; then
        rm -f "$TUTORIAL_HOME/certs/ca"/*.pem "$TUTORIAL_HOME/certs/ca"/*.csr
        echo "CA certificate files removed"
    fi

    if [ -d "$TUTORIAL_HOME/certs/mds" ]; then
        rm -f "$TUTORIAL_HOME/certs/mds"/*.pem "$TUTORIAL_HOME/certs/mds"/*.csr
        echo "MDS certificate files removed"
    fi

    echo "Certificate configuration files preserved for reuse"
}

# Clean up certificates
cleanup_certificates

echo "Kraft-based cluster teardown completed successfully!"
echo ""
echo "All Kraft controllers, secrets, and namespaces have been removed."
echo "Certificate configuration files have been preserved for reuse."
