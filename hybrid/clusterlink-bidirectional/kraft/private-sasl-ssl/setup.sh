#!/bin/bash
# Setup script for Bidirectional Cluster Link - KRaft Private SASL-SSL
# This example demonstrates private cluster mode where the destination cluster
# only accepts inbound connections.
# Prerequisites: Run ../../setup_cfk.sh first to install CFK
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_NS="src"    # Public cluster
DEST_NS="dest"  # Private cluster
CERTS_DIR="$SCRIPT_DIR/certs"
LINK_NAME="bidirectional-private-link"

echo "============================================================"
echo "Bidirectional Cluster Link - KRaft Private Cluster SASL-SSL"
echo "============================================================"

# Check if CFK is installed
echo "Checking CFK installation..."
if ! kubectl get crd kafkas.platform.confluent.io &>/dev/null; then
    echo "ERROR: CFK CRDs not found. Please run setup_cfk.sh first."
    echo ""
    echo "To install CFK (must use namespaced=false for cross-namespace cluster links):"
    echo "  ../../setup_cfk.sh --namespace confluent --all-namespaces"
    exit 1
fi
echo "CFK is installed."

echo ""
echo "Architecture:"
echo "  - Public cluster (src): OUTBOUND mode - initiates connections"
echo "  - Private cluster (dest): INBOUND mode - accepts connections only"
echo ""

# Create namespaces
echo "Creating namespaces..."
kubectl create namespace $SRC_NS --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $DEST_NS --dry-run=client -o yaml | kubectl apply -f -

# Generate TLS certificates
echo ""
echo "Generating TLS certificates..."
mkdir -p "$CERTS_DIR"

if [ ! -f "$CERTS_DIR/ca-key.pem" ]; then
    echo "  Generating CA..."
    openssl genrsa -out "$CERTS_DIR/ca-key.pem" 4096
    openssl req -x509 -new -nodes -key "$CERTS_DIR/ca-key.pem" -sha256 -days 365 \
        -out "$CERTS_DIR/ca.pem" \
        -subj "/CN=confluent-ca/O=Confluent/C=US"
fi

if [ ! -f "$CERTS_DIR/privkey.pem" ]; then
    echo "  Generating server certificate..."
    openssl genrsa -out "$CERTS_DIR/privkey.pem" 2048
    
    cat > "$CERTS_DIR/ext.cnf" << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = *.svc.cluster.local

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.svc.cluster.local
DNS.2 = *.src.svc.cluster.local
DNS.3 = *.dest.svc.cluster.local
DNS.4 = kafka.src.svc.cluster.local
DNS.5 = kafka.dest.svc.cluster.local
DNS.6 = kraftcontroller.src.svc.cluster.local
DNS.7 = kraftcontroller.dest.svc.cluster.local
DNS.8 = *.kafka.src.svc.cluster.local
DNS.9 = *.kafka.dest.svc.cluster.local
DNS.10 = *.kraftcontroller.src.svc.cluster.local
DNS.11 = *.kraftcontroller.dest.svc.cluster.local
EOF
    
    openssl req -new -key "$CERTS_DIR/privkey.pem" \
        -out "$CERTS_DIR/server.csr" \
        -subj "/CN=*.svc.cluster.local/O=Confluent/C=US"
    
    openssl x509 -req -in "$CERTS_DIR/server.csr" \
        -CA "$CERTS_DIR/ca.pem" -CAkey "$CERTS_DIR/ca-key.pem" \
        -CAcreateserial -out "$CERTS_DIR/server.pem" \
        -days 365 -sha256 -extfile "$CERTS_DIR/ext.cnf" -extensions v3_req
    
    cat "$CERTS_DIR/server.pem" "$CERTS_DIR/ca.pem" > "$CERTS_DIR/fullchain.pem"
    cp "$CERTS_DIR/ca.pem" "$CERTS_DIR/cacerts.pem"
fi

# Create secrets
echo ""
echo "Creating secrets..."

# TLS secrets
kubectl create secret generic tls-certs -n $SRC_NS \
    --from-file=fullchain.pem="$CERTS_DIR/fullchain.pem" \
    --from-file=cacerts.pem="$CERTS_DIR/cacerts.pem" \
    --from-file=privkey.pem="$CERTS_DIR/privkey.pem" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic tls-certs -n $DEST_NS \
    --from-file=fullchain.pem="$CERTS_DIR/fullchain.pem" \
    --from-file=cacerts.pem="$CERTS_DIR/cacerts.pem" \
    --from-file=privkey.pem="$CERTS_DIR/privkey.pem" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret tls ca-pair-sslcerts -n $SRC_NS \
    --cert="$CERTS_DIR/ca.pem" --key="$CERTS_DIR/ca-key.pem" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret tls ca-pair-sslcerts -n $DEST_NS \
    --cert="$CERTS_DIR/ca.pem" --key="$CERTS_DIR/ca-key.pem" \
    --dry-run=client -o yaml | kubectl apply -f -

# ⚠️ IMPORTANT: Use DIFFERENT credentials for src and dest clusters
# This ensures authentication is properly tested and not passing by coincidence

# SOURCE (public) cluster SASL credentials
kubectl create secret generic credential -n $SRC_NS \
    --from-literal=plain.txt="username=src-kafka
password=src-kafka-secret" \
    --from-literal=plain-users.json='{"src-kafka":"src-kafka-secret","src-admin":"src-admin-secret"}' \
    --from-literal=plain-interbroker.txt="username=src-kafka
password=src-kafka-secret" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic rest-credential -n $SRC_NS \
    --from-literal=basic.txt="username=src-admin
password=src-admin-secret" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic password-encoder-secret -n $SRC_NS \
    --from-literal=password-encoder.txt="password=src-encoder-secret" \
    --dry-run=client -o yaml | kubectl apply -f -

# DESTINATION (private) cluster SASL credentials (DIFFERENT from source!)
kubectl create secret generic credential -n $DEST_NS \
    --from-literal=plain.txt="username=dest-kafka
password=dest-kafka-secret" \
    --from-literal=plain-users.json='{"dest-kafka":"dest-kafka-secret","dest-admin":"dest-admin-secret"}' \
    --from-literal=plain-interbroker.txt="username=dest-kafka
password=dest-kafka-secret" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic rest-credential -n $DEST_NS \
    --from-literal=basic.txt="username=dest-admin
password=dest-admin-secret" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic password-encoder-secret -n $DEST_NS \
    --from-literal=password-encoder.txt="password=dest-encoder-secret" \
    --dry-run=client -o yaml | kubectl apply -f -

# Cross-namespace credential secrets for ClusterLink authentication
# dest-side (INBOUND) ClusterLink needs src cluster credentials to validate link
kubectl create secret generic src-credential -n $DEST_NS \
    --from-literal=plain.txt="username=src-kafka
password=src-kafka-secret" \
    --dry-run=client -o yaml | kubectl apply -f -

# src-side (OUTBOUND) ClusterLink needs dest cluster credentials to auth to dest Kafka
kubectl create secret generic dest-credential -n $SRC_NS \
    --from-literal=plain.txt="username=dest-kafka
password=dest-kafka-secret" \
    --dry-run=client -o yaml | kubectl apply -f -

# Deploy clusters
echo ""
echo "Deploying public cluster (src)..."
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/kraftcontroller.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/kafka.yaml"

echo "Deploying private cluster (dest)..."
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/kraftcontroller.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/kafka.yaml"

# Wait for clusters
echo ""
echo "Waiting for KRaft controller pods to be created..."
until kubectl get pods -l app=kraftcontroller -n $SRC_NS 2>/dev/null | grep -q kraftcontroller; do sleep 2; done
until kubectl get pods -l app=kraftcontroller -n $DEST_NS 2>/dev/null | grep -q kraftcontroller; do sleep 2; done

echo "Waiting for KRaft controllers to be ready..."
kubectl wait --for=condition=Ready pod -l app=kraftcontroller -n $SRC_NS --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kraftcontroller -n $DEST_NS --timeout=300s

echo "Waiting for Kafka pods to be created..."
until kubectl get pods -l app=kafka -n $SRC_NS 2>/dev/null | grep -q kafka; do sleep 2; done
until kubectl get pods -l app=kafka -n $DEST_NS 2>/dev/null | grep -q kafka; do sleep 2; done

echo "Waiting for Kafka to be ready..."
kubectl wait --for=condition=Ready pod -l app=kafka -n $SRC_NS --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kafka -n $DEST_NS --timeout=300s

# Create KafkaRestClass
echo ""
echo "Creating KafkaRestClass resources..."
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/kafkarestclass.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/kafkarestclass.yaml"

# Wait for REST API and get cluster IDs
echo "Waiting for REST API to become available..."
sleep 20

# Get source (public) cluster ID - required for INBOUND mode
echo ""
echo "Retrieving public cluster ID for INBOUND mode configuration..."
SRC_CLUSTER_ID=""
for i in {1..30}; do
    SRC_CLUSTER_ID=$(kubectl get kafkarestclass src-rest -n $SRC_NS -o jsonpath='{.status.kafkaClusterID}' 2>/dev/null || echo "")
    if [ -n "$SRC_CLUSTER_ID" ]; then
        break
    fi
    echo "  Waiting for cluster ID... ($i/30)"
    sleep 5
done

if [ -z "$SRC_CLUSTER_ID" ]; then
    echo "ERROR: Could not retrieve public cluster ID from KafkaRestClass"
    exit 1
fi

echo "  Public cluster ID: $SRC_CLUSTER_ID"

# Create topics
echo ""
echo "Creating topics..."
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/topics.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/topics.yaml"

sleep 10

#Create ClusterLinks with the correct cluster ID
echo ""
echo "Creating ClusterLinks for private cluster mode..."
echo " IMPORTANT: Creating INBOUND link first (private cluster)" - #we have to create the INBOUND link first so that it is assigned a new link id. The OUTBOUND link then gets the link id from the other cluster.

# 1) INBOUND on dest (private) – needs SRC_CLUSTER_ID already computed above
cat "$SCRIPT_DIR/manifests/dest-cluster/clusterlink.yaml" | \
  sed "s/\${SOURCE_CLUSTER_ID}/$SRC_CLUSTER_ID/g" | \
  kubectl apply -f -

echo " Creating OUTBOUND link (public cluster)..."

# 2) OUTBOUND on src (public)
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/clusterlink.yaml"

echo ""
echo "============================================================"
echo "Setup complete!"
echo "============================================================"
echo ""
echo "Private cluster mode deployed:"
echo "  - Public cluster (src): OUTBOUND mode"
echo "  - Private cluster (dest): INBOUND mode"
echo ""
echo "⚠️  IMPORTANT: The OUTBOUND link must become healthy FIRST"
echo "    before the INBOUND link can accept connections."
echo ""
echo "Monitor status:"
echo "  kubectl get clusterlink -n $SRC_NS   # Should be healthy first"
echo "  kubectl get clusterlink -n $DEST_NS  # Will become healthy after"
echo ""
echo "Run ./validate.sh once both links show 'Created' state."

