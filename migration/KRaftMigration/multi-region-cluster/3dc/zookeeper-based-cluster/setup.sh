#!/bin/bash
# Make sure to complete Kubernetes networking setup before running this script.
# This script is idempotent - it can be run multiple times safely without altering existing resources.
#
# Note: External-DNS installation may fail due to Bitnami image availability issues.
# This is optional and the script will continue without it.

# Exit on error
set -e

# shellcheck disable=SC2128
TUTORIAL_HOME=$(dirname "$BASH_SOURCE")

# Function to generate CA certificate
generate_ca_cert() {
    echo "Generating CA certificate..."
    mkdir -p "$TUTORIAL_HOME/certs/ca"

    # Check if CA certificate already exists
    if [ -f "$TUTORIAL_HOME/certs/ca/ca.pem" ] && [ -f "$TUTORIAL_HOME/certs/ca/ca-key.pem" ]; then
        echo "CA certificate already exists, skipping generation"
        return
    fi

    cfssl gencert -initca "$TUTORIAL_HOME/certs/server_configs/ca-config.json" | cfssljson -bare "$TUTORIAL_HOME/certs/ca/ca"
}

# Function to generate server certificate
generate_server_cert() {
    local component=$1
    local region=$2
    local config_file="$TUTORIAL_HOME/certs/server_configs/${component}-${region}-server-config.json"
    local output_prefix="$TUTORIAL_HOME/certs/generated/${component}-${region}-server"

    echo "Generating ${component}-${region} certificate..."

    # Create generated directory if it doesn't exist
    mkdir -p "$TUTORIAL_HOME/certs/generated"

    # Check if certificate already exists
    if [ -f "${output_prefix}.pem" ] && [ -f "${output_prefix}-key.pem" ]; then
        echo "Certificate for ${component}-${region} already exists, skipping generation"
        return
    fi

    cfssl gencert -ca="$TUTORIAL_HOME/certs/ca/ca.pem" \
        -ca-key="$TUTORIAL_HOME/certs/ca/ca-key.pem" \
        -config="$TUTORIAL_HOME/certs/server_configs/ca-signing-config.json" \
        -profile=server "$config_file" | \
        cfssljson -bare "$output_prefix"
}

# Function to download MDS tokens from external repository
download_mds_tokens() {
    echo "Downloading MDS tokens from external repository..."

    # Set the external repository URL
    export CFK_EXAMPLES_REPO_HOME="https://raw.githubusercontent.com/confluentinc/confluent-kubernetes-examples/master"

    # Create mds directory if it doesn't exist
    mkdir -p "$TUTORIAL_HOME/certs/mds"

    # Check if MDS certificates already exist
    if [ -f "$TUTORIAL_HOME/certs/mds/mds-publickey.pem" ] && [ -f "$TUTORIAL_HOME/certs/mds/mds-tokenkeypair.pem" ]; then
        echo "MDS certificates already exist, skipping download"
        return
    fi

    # Download MDS public key
    echo "Downloading MDS public key..."
    curl -sSL "$CFK_EXAMPLES_REPO_HOME/assets/certs/mds-publickey.txt" -o "$TUTORIAL_HOME/certs/mds/mds-publickey.pem"

    # Download MDS token key pair
    echo "Downloading MDS token key pair..."
    curl -sSL "$CFK_EXAMPLES_REPO_HOME/assets/certs/mds-tokenkeypair.txt" -o "$TUTORIAL_HOME/certs/mds/mds-tokenkeypair.pem"
}

# Function to generate LDAP certificates
generate_ldap_cert() {
    echo "Generating LDAP certificates..."

    # Create generated directory if it doesn't exist
    mkdir -p "$TUTORIAL_HOME/certs/generated"

    local config_file="$TUTORIAL_HOME/certs/server_configs/ldap-server-config.json"
    local output_prefix="$TUTORIAL_HOME/certs/generated/ldap-server"

    # Check if LDAP certificate already exists
    if [ -f "${output_prefix}.pem" ] && [ -f "${output_prefix}-key.pem" ]; then
        echo "LDAP certificate already exists, skipping generation"
        return
    fi

    cfssl gencert -ca="$TUTORIAL_HOME/certs/ca/ca.pem" \
        -ca-key="$TUTORIAL_HOME/certs/ca/ca-key.pem" \
        -config="$TUTORIAL_HOME/certs/server_configs/ca-signing-config.json" \
        -profile=server "$config_file" | \
        cfssljson -bare "$output_prefix"

    echo "LDAP certificates generated successfully"
}

# Function to create LDAP configuration with generated certificates
create_ldap_config() {
    echo "Creating LDAP configuration with generated certificates..."

    local ldap_config_file="$TUTORIAL_HOME/openldap/ldaps-rbac-generated.yaml"
    local cert_file="$TUTORIAL_HOME/certs/generated/ldap-server.pem"
    local key_file="$TUTORIAL_HOME/certs/generated/ldap-server-key.pem"
    local ca_file="$TUTORIAL_HOME/certs/ca/ca.pem"

    # Create the LDAP configuration with generated certificates
    cat > "$ldap_config_file" << EOF
tls:
  enabled: true
  fullchain: |
$(sed 's/^/    /' "$cert_file")
  privkey: |
$(sed 's/^/    /' "$key_file")
  cacerts: |
$(sed 's/^/    /' "$ca_file")
EOF

    echo "LDAP configuration created with generated certificates"
}

# Generate all certificates
generate_all_certificates() {
    echo "Generating all certificates..."

    # Generate CA certificate
    generate_ca_cert

    # Generate certificates for each component and region
    for component in zk kafka kraft sr; do
        for region in central east west; do
            generate_server_cert "$component" "$region"
        done
    done

    # Force regeneration of Kafka certificates with MDS SANs
    echo "Regenerating Kafka certificates with MDS SANs..."
    for region in central east west; do
        rm -f "$TUTORIAL_HOME/certs/generated/kafka-${region}-server.pem" "$TUTORIAL_HOME/certs/generated/kafka-${region}-server-key.pem"
        generate_server_cert "kafka" "$region"
    done

    # Download MDS tokens from external repository
    download_mds_tokens

    # Generate LDAP certificates
    generate_ldap_cert

    # Create LDAP configuration with generated certificates
    create_ldap_config

    echo "All certificates generated successfully!"
}

# Generate all certificates first
generate_all_certificates

# Create namespace (idempotent)
kubectl create ns central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -
kubectl create ns east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -
kubectl create ns west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

# Set up the Helm Chart (idempotent)
helm repo add confluentinc https://packages.confluent.io/helm

# Install Confluent For Kubernetes (idempotent)
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes --version 0.1193.70 -n central --kube-context mrc-central
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes --version 0.1193.70 -n east --kube-context mrc-east
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes --version 0.1193.70 -n west --kube-context mrc-west

# Install external-dns (idempotent) - Optional, skip if fails
echo "Installing external-dns (optional - may fail due to image availability)..."

# Try to install external-dns, but don't fail the entire script if it fails
# Try to install external-dns, but don't fail the entire script if it fails
echo "Installing external-dns for central region..."
helm upgrade --install external-dns external-dns/external-dns \
  -f "$TUTORIAL_HOME/external-dns-values.yaml" \
  --set txtOwnerId=mrc-central \
  -n central --kube-context mrc-central || echo "External-DNS installation failed for central, skipping..."

echo "Installing external-dns for east region..."
helm upgrade --install external-dns external-dns/external-dns \
  -f "$TUTORIAL_HOME/external-dns-values.yaml" \
  --set txtOwnerId=mrc-east \
  -n east --kube-context mrc-east || echo "External-DNS installation failed for east, skipping..."

echo "Installing external-dns for west region..."
helm upgrade --install external-dns external-dns/external-dns \
  -f "$TUTORIAL_HOME/external-dns-values.yaml" \
  --set txtOwnerId=mrc-west \
  -n west --kube-context mrc-west || echo "External-DNS installation failed for west, skipping..."

echo "External-DNS installation attempts completed (some may have failed - this is expected and OK)"

# Deploy OpenLdap (idempotent) - Use local assets with generated certificates
if [ -d "$TUTORIAL_HOME"/openldap ]; then
    echo "Deploying OpenLDAP with generated certificates..."
    helm upgrade --install -f "$TUTORIAL_HOME"/openldap/ldaps-rbac-generated.yaml open-ldap "$TUTORIAL_HOME"/openldap -n central --kube-context mrc-central

    # Wait for LDAP to be ready
    echo "Waiting for LDAP to be ready..."
    kubectl wait pod -l app=openldap --for=condition=Ready --timeout=300s -n central --context mrc-central || echo "LDAP deployment may have issues, continuing..."
else
    echo "OpenLDAP assets directory not found, skipping OpenLDAP deployment"
    echo "WARNING: Kafka is configured to use LDAP authentication but LDAP is not available!"
fi

# Create external access LB for LDAP (idempotent) - Skip if file doesn't exist
if [ -f "$TUTORIAL_HOME"/ldap-loadbalancer.yaml ]; then
    echo "Creating LDAP load balancer..."
    kubectl apply -f "$TUTORIAL_HOME"/ldap-loadbalancer.yaml -n central --context mrc-central
else
    echo "LDAP loadbalancer file not found, skipping LDAP loadbalancer creation"
fi

# Configure service account
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rack-awareness/service-account-rolebinding-central.yaml --context mrc-central
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rack-awareness/service-account-rolebinding-east.yaml --context mrc-east
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rack-awareness/service-account-rolebinding-west.yaml --context mrc-west

# Create CFK CA TLS certificates for auto generating certs (idempotent)
kubectl create secret tls ca-pair-sslcerts \
  --cert="$TUTORIAL_HOME/certs/ca/ca.pem" \
  --key="$TUTORIAL_HOME/certs/ca/ca-key.pem" \
  -n central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -
kubectl create secret tls ca-pair-sslcerts \
  --cert="$TUTORIAL_HOME/certs/ca/ca.pem" \
  --key="$TUTORIAL_HOME/certs/ca/ca-key.pem" \
  -n east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -
kubectl create secret tls ca-pair-sslcerts \
  --cert="$TUTORIAL_HOME/certs/ca/ca.pem" \
  --key="$TUTORIAL_HOME/certs/ca/ca-key.pem" \
  -n west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

# Configure credentials for Authentication and Authorization (idempotent)
kubectl create secret generic credential \
  --from-file=digest-users.json="$TUTORIAL_HOME"/confluent-platform/credentials/zk-users-server.json \
  --from-file=digest.txt="$TUTORIAL_HOME"/confluent-platform/credentials/zk-users-client.txt \
  --from-file=plain-users.json="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-users-server.json \
  --from-file=plain.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-users-client.txt \
  --from-file=plain-interbroker.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-server-plain-interbroker.txt \
  --from-file=kafka-server-listener-internal-plain-metrics.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-server-plain-interbroker.txt \
  --from-file=ldap.txt="$TUTORIAL_HOME"/confluent-platform/credentials/ldap-client.txt \
  -n central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -
kubectl create secret generic credential \
  --from-file=digest-users.json="$TUTORIAL_HOME"/confluent-platform/credentials/zk-users-server.json \
  --from-file=digest.txt="$TUTORIAL_HOME"/confluent-platform/credentials/zk-users-client.txt \
  --from-file=plain-users.json="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-users-server.json \
  --from-file=plain.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-users-client.txt \
  --from-file=plain-interbroker.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-server-plain-interbroker.txt \
  --from-file=kafka-server-listener-internal-plain-metrics.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-server-plain-interbroker.txt \
  --from-file=ldap.txt="$TUTORIAL_HOME"/confluent-platform/credentials/ldap-client.txt \
  -n east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -
kubectl create secret generic credential \
  --from-file=digest-users.json="$TUTORIAL_HOME"/confluent-platform/credentials/zk-users-server.json \
  --from-file=digest.txt="$TUTORIAL_HOME"/confluent-platform/credentials/zk-users-client.txt \
  --from-file=plain-users.json="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-users-server.json \
  --from-file=plain.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-users-client.txt \
  --from-file=plain-interbroker.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-server-plain-interbroker.txt \
  --from-file=kafka-server-listener-internal-plain-metrics.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-server-plain-interbroker.txt \
  --from-file=ldap.txt="$TUTORIAL_HOME"/confluent-platform/credentials/ldap-client.txt \
  -n west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

# Configure credentials for kafka metric reporter (using replication credentials) (idempotent)
kubectl create secret generic metric-creds \
  --from-file=plain.txt=$TUTORIAL_HOME/confluent-platform/credentials/metric-users-client.txt \
  -n central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -

kubectl create secret generic metric-creds \
  --from-file=plain.txt=$TUTORIAL_HOME/confluent-platform/credentials/metric-users-client.txt \
  -n east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -

kubectl create secret generic metric-creds \
  --from-file=plain.txt=$TUTORIAL_HOME/confluent-platform/credentials/metric-users-client.txt \
  -n west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

# Create Kubernetes secret object for MDS using generated certificates (idempotent):
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem="$TUTORIAL_HOME/certs/mds/mds-publickey.pem" \
  --from-file=mdsTokenKeyPair.pem="$TUTORIAL_HOME/certs/mds/mds-tokenkeypair.pem" \
  -n central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem="$TUTORIAL_HOME/certs/mds/mds-publickey.pem" \
  --from-file=mdsTokenKeyPair.pem="$TUTORIAL_HOME/certs/mds/mds-tokenkeypair.pem" \
  -n east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem="$TUTORIAL_HOME/certs/mds/mds-publickey.pem" \
  --from-file=mdsTokenKeyPair.pem="$TUTORIAL_HOME/certs/mds/mds-tokenkeypair.pem" \
  -n west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

# Create Kafka RBAC credential (idempotent)
kubectl create secret generic mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/mds-client.txt \
  -n central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -
kubectl create secret generic mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/mds-client.txt \
  -n east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -
kubectl create secret generic mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/mds-client.txt \
  -n west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

# Create Schema Registry RBAC credential (idempotent)
kubectl create secret generic sr-mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/sr-mds-client.txt \
  -n central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -
kubectl create secret generic sr-mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/sr-mds-client.txt \
  -n east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -
kubectl create secret generic sr-mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/sr-mds-client.txt \
  -n west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

# Create Control Center RBAC credential (idempotent)
kubectl create secret generic c3-mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/c3-mds-client.txt \
  -n central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -

# Create Kafka REST credential (idempotent)
kubectl create secret generic kafka-rest-credential \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/mds-client.txt \
  -n central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -
kubectl create secret generic kafka-rest-credential \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/mds-client.txt \
  -n east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -
kubectl create secret generic kafka-rest-credential \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/mds-client.txt \
  -n west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

# Create component-specific TLS secrets for each region
echo "Creating component-specific TLS secrets..."

# Create Zookeeper TLS secrets for each region
kubectl create secret generic tls-zk-central \
  --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/zk-central-server.pem" \
  --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/zk-central-server-key.pem" \
  --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
  -n central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -

kubectl create secret generic tls-zk-east \
  --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/zk-east-server.pem" \
  --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/zk-east-server-key.pem" \
  --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
  -n east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -

kubectl create secret generic tls-zk-west \
  --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/zk-west-server.pem" \
  --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/zk-west-server-key.pem" \
  --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
  -n west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

# Create Kafka TLS secrets for each region
kubectl create secret generic tls-kafka-central \
  --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/kafka-central-server.pem" \
  --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/kafka-central-server-key.pem" \
  --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
  -n central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -

kubectl create secret generic tls-kafka-east \
  --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/kafka-east-server.pem" \
  --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/kafka-east-server-key.pem" \
  --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
  -n east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -

kubectl create secret generic tls-kafka-west \
  --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/kafka-west-server.pem" \
  --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/kafka-west-server-key.pem" \
  --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
  -n west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

# Create KRaft TLS secrets for each region
kubectl create secret generic tls-kraft-central \
  --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/kraft-central-server.pem" \
  --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/kraft-central-server-key.pem" \
  --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
  -n central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -

kubectl create secret generic tls-kraft-east \
  --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/kraft-east-server.pem" \
  --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/kraft-east-server-key.pem" \
  --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
  -n east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -

kubectl create secret generic tls-kraft-west \
  --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/kraft-west-server.pem" \
  --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/kraft-west-server-key.pem" \
  --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
  -n west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

# Create Schema Registry TLS secrets for each region
kubectl create secret generic tls-sr-central \
  --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/sr-central-server.pem" \
  --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/sr-central-server-key.pem" \
  --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
  -n central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -

kubectl create secret generic tls-sr-east \
  --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/sr-east-server.pem" \
  --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/sr-east-server-key.pem" \
  --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
  -n east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -

kubectl create secret generic tls-sr-west \
  --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/sr-west-server.pem" \
  --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/sr-west-server-key.pem" \
  --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
  -n west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

# Deploy Zookeeper cluster
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/zookeeper/zookeeper-central.yaml --context mrc-central
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/zookeeper/zookeeper-east.yaml --context mrc-east
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/zookeeper/zookeeper-west.yaml --context mrc-west

# Wait until Zookeeper is up
echo "Waiting for Zookeeper to be Ready..."
kubectl wait pod -l app=zookeeper --for=condition=Ready --timeout=-1s -n central --context mrc-central
kubectl wait pod -l app=zookeeper --for=condition=Ready --timeout=-1s -n east --context mrc-east
kubectl wait pod -l app=zookeeper --for=condition=Ready --timeout=-1s -n west --context mrc-west

# Verify LDAP is accessible before deploying Kafka
echo "Verifying LDAP connectivity..."
if kubectl get pod -l app=openldap -n central --context mrc-central >/dev/null 2>&1; then
    echo "LDAP is available, proceeding with Kafka deployment..."
else
    echo "WARNING: LDAP is not available, but Kafka is configured to use LDAP authentication!"
    echo "This may cause Kafka startup issues. Consider deploying LDAP first or updating Kafka configuration."
fi

# Deploy Kafka cluster
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kafka/kafka-central.yaml --context mrc-central
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kafka/kafka-east.yaml --context mrc-east
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kafka/kafka-west.yaml --context mrc-west

sleep 10s

# Wait until Kafka is up
echo "Waiting for Kafka to be Ready..."
kubectl wait kafka kafka --for=jsonpath='{.status.phase}'=RUNNING --timeout=-1s -n central --context mrc-central
kubectl wait kafka kafka --for=jsonpath='{.status.phase}'=RUNNING --timeout=-1s -n east --context mrc-east
kubectl wait kafka kafka --for=jsonpath='{.status.phase}'=RUNNING --timeout=-1s -n west --context mrc-west

# Create Kafka REST class
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kafkarestclass.yaml -n central --context mrc-central
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kafkarestclass.yaml -n east --context mrc-east
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kafkarestclass.yaml -n west --context mrc-west

# Create role bindings for Schema Registry
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/mrc-rolebindings.yaml -n central --context mrc-central
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/mrc-rolebindings.yaml -n east --context mrc-east
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/mrc-rolebindings.yaml -n west --context mrc-west

# Create role bindings for Control Center
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/c3-rolebindings.yaml --context mrc-central

# Deploy Schema Registry cluster
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/schemaregistry/schemaregistry-central.yaml --context mrc-central
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/schemaregistry/schemaregistry-east.yaml --context mrc-east
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/schemaregistry/schemaregistry-west.yaml --context mrc-west

# Wait until Schema Registry is up
echo "Waiting for Schema Registry to be Ready..."
kubectl wait pod -l app=schemaregistry --for=condition=Ready --timeout=-1s -n central --context mrc-central
kubectl wait pod -l app=schemaregistry --for=condition=Ready --timeout=-1s -n east --context mrc-east
kubectl wait pod -l app=schemaregistry --for=condition=Ready --timeout=-1s -n west --context mrc-west

# Deploy Control Center
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/controlcenter.yaml --context mrc-central

## Wait until Control Center is up
#echo "Waiting for Control Center to be Ready..."
sleep 2
kubectl wait pod -l app=controlcenter --for=condition=Ready --timeout=-1s -n central --context mrc-central
