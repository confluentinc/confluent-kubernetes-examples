#!/bin/bash
set -e

TUTORIAL_HOME=$(dirname "$BASH_SOURCE")

# Function to copy CA certificate from zookeeper-based-cluster
copy_ca_cert() {
    echo "Copying CA certificate from zookeeper-based-cluster..."

    # Create ca directory if it doesn't exist
    mkdir -p "$TUTORIAL_HOME/certs/ca"

    # Check if CA certificate already exists
    if [ -f "$TUTORIAL_HOME/certs/ca/ca.pem" ] && [ -f "$TUTORIAL_HOME/certs/ca/ca-key.pem" ]; then
        echo "CA certificate already exists, skipping copy"
        return
    fi

    # Reference the zookeeper-based-cluster CA
    local zk_cluster_path="../zookeeper-based-cluster"

    if [ -f "$zk_cluster_path/certs/ca/ca.pem" ] && [ -f "$zk_cluster_path/certs/ca/ca-key.pem" ]; then
        cp "$zk_cluster_path/certs/ca/ca.pem" "$TUTORIAL_HOME/certs/ca/ca.pem"
        cp "$zk_cluster_path/certs/ca/ca-key.pem" "$TUTORIAL_HOME/certs/ca/ca-key.pem"
        echo "CA certificate copied successfully"
    else
        echo "ERROR: CA certificate not found in zookeeper-based-cluster. Please run the zookeeper-based-cluster setup first."
        exit 1
    fi
}

# Function to copy CA configuration from zookeeper-based-cluster
copy_ca_config() {
    echo "Copying CA configuration from zookeeper-based-cluster..."

    # Create server_configs directory if it doesn't exist
    mkdir -p "$TUTORIAL_HOME/certs/server_configs"

    # Reference the zookeeper-based-cluster config
    local zk_cluster_path="../zookeeper-based-cluster"

    if [ -f "$zk_cluster_path/certs/server_configs/ca-signing-config.json" ]; then
        cp "$zk_cluster_path/certs/server_configs/ca-signing-config.json" "$TUTORIAL_HOME/certs/server_configs/ca-signing-config.json"
        echo "CA signing configuration copied successfully"
    else
        echo "ERROR: CA signing configuration not found in zookeeper-based-cluster. Please run the zookeeper-based-cluster setup first."
        exit 1
    fi
}

# Function to generate server certificate
generate_server_cert() {
    local component=$1
    local region=$2

    echo "Generating $component-$region certificate..."

    # Create generated directory if it doesn't exist
    mkdir -p "$TUTORIAL_HOME/certs/generated"

    local config_file="$TUTORIAL_HOME/certs/server_configs/${component}-${region}-server-config.json"
    local output_prefix="$TUTORIAL_HOME/certs/generated/${component}-${region}-server"

    # Check if certificate already exists
    if [ -f "${output_prefix}.pem" ] && [ -f "${output_prefix}-key.pem" ]; then
        echo "$component-$region certificate already exists, skipping generation"
        return
    fi

    cfssl gencert -ca="$TUTORIAL_HOME/certs/ca/ca.pem" \
        -ca-key="$TUTORIAL_HOME/certs/ca/ca-key.pem" \
        -config="$TUTORIAL_HOME/certs/server_configs/ca-signing-config.json" \
        -profile=server "$config_file" | \
        cfssljson -bare "$output_prefix"

    echo "$component-$region certificate generated successfully"
}


# Main setup function
setup_kraft_cluster() {
    echo "Setting up Kraft-based cluster..."

    # Generate all certificates
    echo "Generating all certificates..."

    # Copy CA certificate and config from zookeeper-based-cluster
    copy_ca_cert
    copy_ca_config

    # Generate certificates for Kraft controllers in each region
    for region in central east west; do
        generate_server_cert "kraft" "$region"
    done

    # MDS tokens will be referenced from zookeeper-based-cluster

    # Create namespaces (idempotent)
    echo "Creating namespaces..."
    kubectl create namespace central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -
    kubectl create namespace east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -
    kubectl create namespace west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

    # Reference CA certificate from zookeeper-based-cluster
    echo "Referencing CA certificate from zookeeper-based-cluster..."
    local zk_cluster_path="../zookeeper-based-cluster"

    # Check if CA certificate exists in zookeeper-based-cluster
    if [ ! -f "$zk_cluster_path/certs/ca/ca.pem" ] || [ ! -f "$zk_cluster_path/certs/ca/ca-key.pem" ]; then
        echo "ERROR: CA certificate not found in zookeeper-based-cluster. Please run the zookeeper-based-cluster setup first."
        exit 1
    fi

    echo "CA certificate found in zookeeper-based-cluster, using it for Kraft cluster"

    # Reference MDS tokens from zookeeper-based-cluster
    echo "Referencing MDS tokens from zookeeper-based-cluster..."

    # Check if MDS tokens exist in zookeeper-based-cluster
    if [ ! -f "$zk_cluster_path/certs/mds/mds-tokenkeypair.pem" ]; then
        echo "ERROR: MDS tokens not found in zookeeper-based-cluster. Please run the zookeeper-based-cluster setup first."
        exit 1
    fi

    echo "MDS tokens found in zookeeper-based-cluster, using them for Kraft cluster"

    # Create Kraft TLS secrets for each region
    echo "Creating Kraft TLS secrets..."

    # Delete existing Kraft TLS secrets if they exist to avoid type conflicts
    kubectl delete secret tls-kraft-central -n central --context mrc-central 2>/dev/null || true
    kubectl delete secret tls-kraft-east -n east --context mrc-east 2>/dev/null || true
    kubectl delete secret tls-kraft-west -n west --context mrc-west 2>/dev/null || true

    kubectl create secret generic tls-kraft-central \
        --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/kraft-central-server.pem" \
        --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/kraft-central-server-key.pem" \
        --from-file=cacerts.pem="$zk_cluster_path/certs/ca/ca.pem" \
        -n central --context mrc-central

    kubectl create secret generic tls-kraft-east \
        --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/kraft-east-server.pem" \
        --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/kraft-east-server-key.pem" \
        --from-file=cacerts.pem="$zk_cluster_path/certs/ca/ca.pem" \
        -n east --context mrc-east

    kubectl create secret generic tls-kraft-west \
        --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/kraft-west-server.pem" \
        --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/kraft-west-server-key.pem" \
        --from-file=cacerts.pem="$zk_cluster_path/certs/ca/ca.pem" \
        -n west --context mrc-west

    # Configure credentials for Authentication and Authorization (idempotent)
    kubectl create secret generic credential-mds \
      --from-file=plain.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-mds-client.txt \
      -n central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -
    kubectl create secret generic credential-mds \
      --from-file=plain.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-mds-client.txt \
      -n east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -
    kubectl create secret generic credential-mds \
      --from-file=plain.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-mds-client.txt \
      -n west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

    # Deploy Kraft controllers
    echo "Deploying Kraft controllers..."
    kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kraft/kraft-central.yaml --context mrc-central
    kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kraft/kraft-east.yaml --context mrc-east
    kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kraft/kraft-west.yaml --context mrc-west

    sleep 10s

    # Wait until Kraft controllers are up
#    echo "Waiting for Kraft controllers to be Ready..."
#    kubectl wait kraftcontroller kraftcontroller-central --for=jsonpath='{.status.phase}'=RUNNING --timeout=-1s -n central --context mrc-central
#    kubectl wait kraftcontroller kraftcontroller-east --for=jsonpath='{.status.phase}'=RUNNING --timeout=-1s -n east --context mrc-east
#    kubectl wait kraftcontroller kraftcontroller-west --for=jsonpath='{.status.phase}'=RUNNING --timeout=-1s -n west --context mrc-west

    echo "Kraft-based cluster setup completed successfully!"
    echo ""
    echo "Kraft controllers are running in:"
    echo "- Central region: 1 replica"
    echo "- East region: 2 replicas"
    echo "- West region: 2 replicas"
    echo ""
    echo "To check status:"
    echo "kubectl get kraftcontroller -n central --context mrc-central"
    echo "kubectl get kraftcontroller -n east --context mrc-east"
    echo "kubectl get kraftcontroller -n west --context mrc-west"
}

# Run the setup
setup_kraft_cluster
