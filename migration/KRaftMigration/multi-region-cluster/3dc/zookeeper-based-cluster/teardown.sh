#!/bin/bash
# Make sure to complete Kubernetes networking setup before running this script.

# Exit on error
set -e

# shellcheck disable=SC2128
TUTORIAL_HOME=$(dirname "$BASH_SOURCE")

# Function to clean up generated certificates (but keep config files)
cleanup_certificates() {
    echo "Cleaning up generated certificates..."
    
    # Only remove generated certificate files, not the entire directories
    if [ -d "$TUTORIAL_HOME/certs/generated" ]; then
        rm -f "$TUTORIAL_HOME/certs/generated"/*.pem "$TUTORIAL_HOME/certs/generated"/*.csr
        echo "Generated certificate files removed"
    fi
    
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

# Destroy Control Center (if it exists)
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/controlcenter.yaml --context mrc-central 2>/dev/null || echo "Control Center not found, skipping..."

# Destroy Schema Registry (if they exist)
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/schemaregistry/schemaregistry-west.yaml --context mrc-west 2>/dev/null || echo "Schema Registry west not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/schemaregistry/schemaregistry-east.yaml --context mrc-east 2>/dev/null || echo "Schema Registry east not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/schemaregistry/schemaregistry-central.yaml --context mrc-central 2>/dev/null || echo "Schema Registry central not found, skipping..."

# Delete Control Center role bindings (if they exist)
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/c3-rolebindings.yaml --context mrc-central 2>/dev/null || echo "Control Center role bindings not found, skipping..."

# Delete Schema Registry role bindings (if they exist)
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/mrc-rolebindings.yaml -n west --context mrc-west 2>/dev/null || echo "Schema Registry role bindings west not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/mrc-rolebindings.yaml -n east --context mrc-east 2>/dev/null || echo "Schema Registry role bindings east not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/mrc-rolebindings.yaml -n central --context mrc-central 2>/dev/null || echo "Schema Registry role bindings central not found, skipping..."

# Wait for internal role bindings to be deleted
echo "Waiting for role bindings to be deleted..."
kubectl wait cfrb --all --for=delete --timeout=-1s -n west --context mrc-west
kubectl wait cfrb --all --for=delete --timeout=-1s -n east --context mrc-east
kubectl wait cfrb --all --for=delete --timeout=-1s -n central --context mrc-central

# Delete Kafka REST class (if they exist)
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kafkarestclass.yaml -n west --context mrc-west 2>/dev/null || echo "Kafka REST class west not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kafkarestclass.yaml -n east --context mrc-east 2>/dev/null || echo "Kafka REST class east not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kafkarestclass.yaml -n central --context mrc-central 2>/dev/null || echo "Kafka REST class central not found, skipping..."

# Destroy Kafka (if they exist)
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kafka/kafka-west.yaml --context mrc-west 2>/dev/null || echo "Kafka west not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kafka/kafka-east.yaml --context mrc-east 2>/dev/null || echo "Kafka east not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kafka/kafka-central.yaml --context mrc-central 2>/dev/null || echo "Kafka central not found, skipping..."

# Wait for Kafka to be destroyed
echo "Waiting for Kafka to be deleted..."
kubectl wait pod -l app=kafka --for=delete --timeout=-1s -n west --context mrc-west
kubectl wait pod -l app=kafka --for=delete --timeout=-1s -n east --context mrc-east
kubectl wait pod -l app=kafka --for=delete --timeout=-1s -n central --context mrc-central

# Destroy Zookeeper (if they exist)
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/zookeeper/zookeeper-west.yaml --context mrc-west 2>/dev/null || echo "Zookeeper west not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/zookeeper/zookeeper-east.yaml --context mrc-east 2>/dev/null || echo "Zookeeper east not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/zookeeper/zookeeper-central.yaml --context mrc-central 2>/dev/null || echo "Zookeeper central not found, skipping..."

# Delete Kafka REST credential (if they exist)
kubectl delete secret kafka-rest-credential -n west --context mrc-west 2>/dev/null || echo "Kafka REST credential west not found, skipping..."
kubectl delete secret kafka-rest-credential -n east --context mrc-east 2>/dev/null || echo "Kafka REST credential east not found, skipping..."
kubectl delete secret kafka-rest-credential -n central --context mrc-central 2>/dev/null || echo "Kafka REST credential central not found, skipping..."

# Delete Control Center RBAC credential (if it exists)
kubectl delete secret c3-mds-client -n central --context mrc-central 2>/dev/null || echo "Control Center RBAC credential not found, skipping..."

# Delete Schema Registry RBAC credential (if they exist)
kubectl delete secret sr-mds-client -n west --context mrc-west 2>/dev/null || echo "Schema Registry RBAC credential west not found, skipping..."
kubectl delete secret sr-mds-client -n east --context mrc-east 2>/dev/null || echo "Schema Registry RBAC credential east not found, skipping..."
kubectl delete secret sr-mds-client -n central --context mrc-central 2>/dev/null || echo "Schema Registry RBAC credential central not found, skipping..."

# Delete Kafka RBAC credential (if they exist)
kubectl delete secret mds-client -n west --context mrc-west 2>/dev/null || echo "Kafka RBAC credential west not found, skipping..."
kubectl delete secret mds-client -n east --context mrc-east 2>/dev/null || echo "Kafka RBAC credential east not found, skipping..."
kubectl delete secret mds-client -n central --context mrc-central 2>/dev/null || echo "Kafka RBAC credential central not found, skipping..."

# Delete Kubernetes secret object for MDS (if they exist):
kubectl delete secret mds-token -n west --context mrc-west 2>/dev/null || echo "MDS token west not found, skipping..."
kubectl delete secret mds-token -n east --context mrc-east 2>/dev/null || echo "MDS token east not found, skipping..."
kubectl delete secret mds-token -n central --context mrc-central 2>/dev/null || echo "MDS token central not found, skipping..."

# Delete credentials for metric reporter using replication listener (if they exist)
kubectl delete secret metric-creds -n west --context mrc-west 2>/dev/null || echo "Metric credentials west not found, skipping..."
kubectl delete secret metric-creds -n east --context mrc-east 2>/dev/null || echo "Metric credentials east not found, skipping..."
kubectl delete secret metric-creds -n central --context mrc-central 2>/dev/null || echo "Metric credentials central not found, skipping..."

# Delete credentials for Authentication and Authorization (if they exist)
kubectl delete secret credential -n west --context mrc-west 2>/dev/null || echo "Credential west not found, skipping..."
kubectl delete secret credential -n east --context mrc-east 2>/dev/null || echo "Credential east not found, skipping..."
kubectl delete secret credential -n central --context mrc-central 2>/dev/null || echo "Credential central not found, skipping..."

# Delete component-specific TLS secrets (if they exist)
kubectl delete secret tls-zk-west tls-kafka-west tls-kraft-west tls-sr-west -n west --context mrc-west 2>/dev/null || echo "Component TLS secrets west not found, skipping..."
kubectl delete secret tls-zk-east tls-kafka-east tls-kraft-east tls-sr-east -n east --context mrc-east 2>/dev/null || echo "Component TLS secrets east not found, skipping..."
kubectl delete secret tls-zk-central tls-kafka-central tls-kraft-central tls-sr-central -n central --context mrc-central 2>/dev/null || echo "Component TLS secrets central not found, skipping..."

# Delete CFK CA TLS certificates for auto generating certs (if they exist)
kubectl delete secret ca-pair-sslcerts -n west --context mrc-west 2>/dev/null || echo "CA certificates west not found, skipping..."
kubectl delete secret ca-pair-sslcerts -n east --context mrc-east 2>/dev/null || echo "CA certificates east not found, skipping..."
kubectl delete secret ca-pair-sslcerts -n central --context mrc-central 2>/dev/null || echo "CA certificates central not found, skipping..."

# Delete service account (if they exist)
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rack-awareness/service-account-rolebinding-west.yaml --context mrc-west 2>/dev/null || echo "Service account role bindings west not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rack-awareness/service-account-rolebinding-east.yaml --context mrc-east 2>/dev/null || echo "Service account role bindings east not found, skipping..."
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rack-awareness/service-account-rolebinding-central.yaml --context mrc-central 2>/dev/null || echo "Service account role bindings central not found, skipping..."

# Uninstall Open LDAP (if it exists)
helm uninstall open-ldap -n central --kube-context mrc-central 2>/dev/null || echo "OpenLDAP not found, skipping..."

# Uninstall External-DNS (if it exists)
helm uninstall external-dns -n west --kube-context mrc-west 2>/dev/null || echo "External-DNS west not found, skipping..."
helm uninstall external-dns -n east --kube-context mrc-east 2>/dev/null || echo "External-DNS east not found, skipping..."
helm uninstall external-dns -n central --kube-context mrc-central 2>/dev/null || echo "External-DNS central not found, skipping..."

# Uninstall CFK
helm uninstall cfk-operator -n west --kube-context mrc-west 2>/dev/null || echo "CFK operator west not found, skipping..."
helm uninstall cfk-operator -n east --kube-context mrc-east 2>/dev/null || echo "CFK operator east not found, skipping..."
helm uninstall cfk-operator -n central --kube-context mrc-central 2>/dev/null || echo "CFK operator central not found, skipping..."

# Delete namespace
kubectl delete ns west --context mrc-west
kubectl delete ns east --context mrc-east
kubectl delete ns central --context mrc-central

# Clean up generated certificates
cleanup_certificates

echo "Teardown completed successfully!"