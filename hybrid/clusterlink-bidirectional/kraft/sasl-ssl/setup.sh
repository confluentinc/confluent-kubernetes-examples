#!/bin/bash
# Setup script for Bidirectional Cluster Link - KRaft SASL-SSL
# Prerequisites: Run ../../setup_cfk.sh first to install CFK
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_NS="src"
DEST_NS="dest"
CERTS_DIR="$SCRIPT_DIR/certs"

echo "=========================================="
echo "Bidirectional Cluster Link - KRaft SASL-SSL"
echo "=========================================="

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

# Create namespaces
echo "Creating namespaces..."
kubectl create namespace $SRC_NS --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $DEST_NS --dry-run=client -o yaml | kubectl apply -f -

# Generate TLS certificates
echo ""
echo "Generating TLS certificates..."
mkdir -p "$CERTS_DIR"

# Generate CA key and certificate
if [ ! -f "$CERTS_DIR/ca-key.pem" ]; then
    echo "  Generating CA..."
    openssl genrsa -out "$CERTS_DIR/ca-key.pem" 4096
    openssl req -x509 -new -nodes -key "$CERTS_DIR/ca-key.pem" -sha256 -days 365 \
        -out "$CERTS_DIR/ca.pem" \
        -subj "/CN=confluent-ca/O=Confluent/C=US"
fi

# Generate server certificate
if [ ! -f "$CERTS_DIR/privkey.pem" ]; then
    echo "  Generating server certificate..."
    openssl genrsa -out "$CERTS_DIR/privkey.pem" 2048
    
    # Create certificate signing request
    openssl req -new -key "$CERTS_DIR/privkey.pem" \
        -out "$CERTS_DIR/server.csr" \
        -subj "/CN=*.svc.cluster.local/O=Confluent/C=US"
    
    # Create extensions file for SAN
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
    
    # Sign the certificate with CA
    openssl x509 -req -in "$CERTS_DIR/server.csr" \
        -CA "$CERTS_DIR/ca.pem" -CAkey "$CERTS_DIR/ca-key.pem" \
        -CAcreateserial -out "$CERTS_DIR/server.pem" \
        -days 365 -sha256 -extfile "$CERTS_DIR/ext.cnf" -extensions v3_req
    
    # Create fullchain
    cat "$CERTS_DIR/server.pem" "$CERTS_DIR/ca.pem" > "$CERTS_DIR/fullchain.pem"
    cp "$CERTS_DIR/ca.pem" "$CERTS_DIR/cacerts.pem"
fi

echo "  Certificates generated in $CERTS_DIR"

# Create TLS secrets - use same CA for both clusters
echo ""
echo "Creating TLS secrets (shared CA for both clusters)..."

# Create tls-certs secret in BOTH namespaces with same CA
for ns in $SRC_NS $DEST_NS; do
    kubectl create secret generic tls-certs -n $ns \
        --from-file=fullchain.pem="$CERTS_DIR/fullchain.pem" \
        --from-file=cacerts.pem="$CERTS_DIR/cacerts.pem" \
        --from-file=privkey.pem="$CERTS_DIR/privkey.pem" \
        --dry-run=client -o yaml | kubectl apply -f -
done

# Create SASL credential secrets
echo "Creating SASL credential secrets..."

# ⚠️ IMPORTANT: Use DIFFERENT credentials for src and dest clusters
# This ensures authentication is properly tested and not passing by coincidence

# SOURCE cluster SASL credentials
cat > /tmp/src-plain.txt << EOF
username=src-kafka
password=src-kafka-secret
EOF

cat > /tmp/src-plain-users.json << EOF
{
  "src-kafka": "src-kafka-secret",
  "src-admin": "src-admin-secret",
  "src-client": "src-client-secret"
}
EOF

cat > /tmp/src-plain-interbroker.txt << EOF
username=src-kafka
password=src-kafka-secret
EOF

kubectl create secret generic credential -n $SRC_NS \
    --from-file=plain.txt=/tmp/src-plain.txt \
    --from-file=plain-users.json=/tmp/src-plain-users.json \
    --from-file=plain-interbroker.txt=/tmp/src-plain-interbroker.txt \
    --dry-run=client -o yaml | kubectl apply -f -

# DESTINATION cluster SASL credentials (DIFFERENT from source!)
cat > /tmp/dest-plain.txt << EOF
username=dest-kafka
password=dest-kafka-secret
EOF

cat > /tmp/dest-plain-users.json << EOF
{
  "dest-kafka": "dest-kafka-secret",
  "dest-admin": "dest-admin-secret",
  "dest-client": "dest-client-secret"
}
EOF

cat > /tmp/dest-plain-interbroker.txt << EOF
username=dest-kafka
password=dest-kafka-secret
EOF

kubectl create secret generic credential -n $DEST_NS \
    --from-file=plain.txt=/tmp/dest-plain.txt \
    --from-file=plain-users.json=/tmp/dest-plain-users.json \
    --from-file=plain-interbroker.txt=/tmp/dest-plain-interbroker.txt \
    --dry-run=client -o yaml | kubectl apply -f -

# REST API credentials (DIFFERENT for each cluster)
cat > /tmp/src-basic.txt << EOF
username=src-admin
password=src-admin-secret
EOF

cat > /tmp/dest-basic.txt << EOF
username=dest-admin
password=dest-admin-secret
EOF

kubectl create secret generic rest-credential -n $SRC_NS \
    --from-file=basic.txt=/tmp/src-basic.txt \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic rest-credential -n $DEST_NS \
    --from-file=basic.txt=/tmp/dest-basic.txt \
    --dry-run=client -o yaml | kubectl apply -f -

# Password encoder secret (can be the same since it's for local encryption)
kubectl create secret generic password-encoder-secret -n $SRC_NS \
    --from-literal=password-encoder.txt="password=src-encoder-secret" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic password-encoder-secret -n $DEST_NS \
    --from-literal=password-encoder.txt="password=dest-encoder-secret" \
    --dry-run=client -o yaml | kubectl apply -f -

# Create CROSS-NAMESPACE credential secrets for ClusterLink authentication
# The dest-side ClusterLink needs src cluster credentials to authenticate to src Kafka
# The src-side ClusterLink needs dest cluster credentials to authenticate to dest Kafka

# Secret in DEST namespace with SRC credentials (for dest-side ClusterLink to auth to src cluster)
cat > /tmp/src-creds-for-link.txt << EOF
username=src-kafka
password=src-kafka-secret
EOF

kubectl create secret generic src-credential -n $DEST_NS \
    --from-file=plain.txt=/tmp/src-creds-for-link.txt \
    --dry-run=client -o yaml | kubectl apply -f -

# Secret in SRC namespace with DEST credentials (for src-side ClusterLink to auth to dest cluster)
cat > /tmp/dest-creds-for-link.txt << EOF
username=dest-kafka
password=dest-kafka-secret
EOF

kubectl create secret generic dest-credential -n $SRC_NS \
    --from-file=plain.txt=/tmp/dest-creds-for-link.txt \
    --dry-run=client -o yaml | kubectl apply -f -

# Cleanup temp files
rm -f /tmp/src-plain.txt /tmp/src-plain-users.json /tmp/src-plain-interbroker.txt /tmp/src-basic.txt
rm -f /tmp/dest-plain.txt /tmp/dest-plain-users.json /tmp/dest-plain-interbroker.txt /tmp/dest-basic.txt
rm -f /tmp/src-creds-for-link.txt /tmp/dest-creds-for-link.txt

# Deploy source cluster
echo ""
echo "Deploying source cluster with SASL-SSL..."
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/kraftcontroller.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/kafka.yaml"

# Deploy destination cluster
echo "Deploying destination cluster with SASL-SSL..."
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/kraftcontroller.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/kafka.yaml"

# Wait for clusters to be ready
echo ""
echo "Waiting for KRaft controllers to be ready..."
kubectl wait --for=condition=Ready pod -l app=kraftcontroller -n $SRC_NS --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kraftcontroller -n $DEST_NS --timeout=300s

echo "Waiting for Kafka clusters to be ready..."
kubectl wait --for=condition=Ready pod -l app=kafka -n $SRC_NS --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kafka -n $DEST_NS --timeout=300s

# Create TLS secrets for ClusterLink cross-namespace connections
# Since both clusters use the same CA, we use the same certs for link trust
echo ""
echo "Creating TLS secrets for ClusterLink..."

# Create src-tls-for-link in dest namespace (for dest-cluster-link to trust src)
kubectl create secret generic src-tls-for-link -n $DEST_NS \
    --from-file=cacerts.pem="$CERTS_DIR/cacerts.pem" \
    --from-file=fullchain.pem="$CERTS_DIR/fullchain.pem" \
    --from-file=privkey.pem="$CERTS_DIR/privkey.pem" \
    --dry-run=client -o yaml | kubectl apply -f -

# Create dest-tls-for-link in src namespace (for src-cluster-link to trust dest)
kubectl create secret generic dest-tls-for-link -n $SRC_NS \
    --from-file=cacerts.pem="$CERTS_DIR/cacerts.pem" \
    --from-file=fullchain.pem="$CERTS_DIR/fullchain.pem" \
    --from-file=privkey.pem="$CERTS_DIR/privkey.pem" \
    --dry-run=client -o yaml | kubectl apply -f -

# Create KafkaRestClass
echo ""
echo "Creating KafkaRestClass resources..."
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/kafkarestclass.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/kafkarestclass.yaml"

# Wait for REST API
echo "Waiting for REST API to become available..."
sleep 15

# Create topics
echo ""
echo "Creating topics..."
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/topics.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/topics.yaml"

sleep 10

# Create ClusterLinks
echo ""
echo "Creating ClusterLinks with SASL-SSL authentication..."
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/clusterlink.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/clusterlink.yaml"

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "Both clusters deployed with SASL-SSL authentication."
echo "ClusterLinks are being created..."
echo ""
echo "Monitor status with:"
echo "  kubectl get clusterlink -n $SRC_NS"
echo "  kubectl get clusterlink -n $DEST_NS"
echo ""
echo "Once both show 'Created' state, run ./validate.sh"

