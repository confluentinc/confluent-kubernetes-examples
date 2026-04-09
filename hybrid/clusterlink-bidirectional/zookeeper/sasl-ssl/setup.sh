#!/bin/bash
# Setup script for Bidirectional Cluster Link - ZooKeeper SASL-SSL
# Prerequisites: Run ../../setup_cfk.sh first to install CFK
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_NS="src"
DEST_NS="dest"
CERTS_DIR="$SCRIPT_DIR/certs"

echo "=========================================="
echo "Bidirectional Cluster Link - ZooKeeper SASL-SSL"
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
kubectl create namespace $SRC_NS --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $DEST_NS --dry-run=client -o yaml | kubectl apply -f -

# Generate TLS certificates
mkdir -p "$CERTS_DIR"
if [ ! -f "$CERTS_DIR/ca-key.pem" ]; then
    echo "Generating certificates..."
    openssl genrsa -out "$CERTS_DIR/ca-key.pem" 4096
    openssl req -x509 -new -nodes -key "$CERTS_DIR/ca-key.pem" -sha256 -days 365 \
        -out "$CERTS_DIR/ca.pem" -subj "/CN=confluent-ca/O=Confluent/C=US"
    
    openssl genrsa -out "$CERTS_DIR/privkey.pem" 2048
    cat > "$CERTS_DIR/ext.cnf" << EOF
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = *.svc.cluster.local
DNS.2 = kafka.src.svc.cluster.local
DNS.3 = kafka.dest.svc.cluster.local
DNS.4 = zookeeper.src.svc.cluster.local
DNS.5 = zookeeper.dest.svc.cluster.local
DNS.6 = *.kafka.src.svc.cluster.local
DNS.7 = *.kafka.dest.svc.cluster.local
DNS.8 = *.zookeeper.src.svc.cluster.local
DNS.9 = *.zookeeper.dest.svc.cluster.local
EOF
    openssl req -new -key "$CERTS_DIR/privkey.pem" -out "$CERTS_DIR/server.csr" \
        -subj "/CN=*.svc.cluster.local"
    openssl x509 -req -in "$CERTS_DIR/server.csr" -CA "$CERTS_DIR/ca.pem" \
        -CAkey "$CERTS_DIR/ca-key.pem" -CAcreateserial -out "$CERTS_DIR/server.pem" \
        -days 365 -sha256 -extfile "$CERTS_DIR/ext.cnf" -extensions v3_req
    cat "$CERTS_DIR/server.pem" "$CERTS_DIR/ca.pem" > "$CERTS_DIR/fullchain.pem"
    cp "$CERTS_DIR/ca.pem" "$CERTS_DIR/cacerts.pem"
fi

# Create TLS secrets (same for both clusters - using single CA)
for ns in $SRC_NS $DEST_NS; do
    kubectl create secret generic tls-certs -n $ns \
        --from-file=fullchain.pem="$CERTS_DIR/fullchain.pem" \
        --from-file=cacerts.pem="$CERTS_DIR/cacerts.pem" \
        --from-file=privkey.pem="$CERTS_DIR/privkey.pem" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl create secret tls ca-pair-sslcerts -n $ns \
        --cert="$CERTS_DIR/ca.pem" --key="$CERTS_DIR/ca-key.pem" \
        --dry-run=client -o yaml | kubectl apply -f -
done

# ⚠️ IMPORTANT: Use DIFFERENT credentials for src and dest clusters
# This ensures authentication is properly tested and not passing by coincidence

# SOURCE cluster credentials
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

# DESTINATION cluster credentials (DIFFERENT from source!)
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
# dest-side ClusterLink needs src cluster credentials to auth to src Kafka
kubectl create secret generic src-credential -n $DEST_NS \
    --from-literal=plain.txt="username=src-kafka
password=src-kafka-secret" \
    --dry-run=client -o yaml | kubectl apply -f -

# src-side ClusterLink needs dest cluster credentials to auth to dest Kafka
kubectl create secret generic dest-credential -n $SRC_NS \
    --from-literal=plain.txt="username=dest-kafka
password=dest-kafka-secret" \
    --dry-run=client -o yaml | kubectl apply -f -

# Deploy clusters
echo "Deploying clusters..."
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/"

# Wait for clusters
echo "Waiting for ZooKeeper..."
kubectl wait --for=condition=Ready pod -l app=zookeeper -n $SRC_NS --timeout=300s
kubectl wait --for=condition=Ready pod -l app=zookeeper -n $DEST_NS --timeout=300s

echo "Waiting for Kafka..."
kubectl wait --for=condition=Ready pod -l app=kafka -n $SRC_NS --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kafka -n $DEST_NS --timeout=300s

# Wait and create ClusterLinks
sleep 15
kubectl apply -f "$SCRIPT_DIR/manifests/clusterlinks/"

echo ""
echo "Setup complete! Monitor with:"
echo "  kubectl get clusterlink -n $SRC_NS"
echo "  kubectl get clusterlink -n $DEST_NS"

