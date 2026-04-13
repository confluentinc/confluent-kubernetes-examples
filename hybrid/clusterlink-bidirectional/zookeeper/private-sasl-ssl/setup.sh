#!/bin/bash
# Setup script for Bidirectional Cluster Link - ZooKeeper Private SASL-SSL
# Prerequisites: Run ../../setup_cfk.sh first to install CFK
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_NS="src"    # Public cluster
DEST_NS="dest"  # Private cluster
CERTS_DIR="$SCRIPT_DIR/certs"

echo "============================================================"
echo "Bidirectional Cluster Link - ZooKeeper Private SASL-SSL"
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
echo "  - Public cluster (src): OUTBOUND mode"
echo "  - Private cluster (dest): INBOUND mode"
echo ""

# Create namespaces and generate certs
kubectl create namespace $SRC_NS --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $DEST_NS --dry-run=client -o yaml | kubectl apply -f -

mkdir -p "$CERTS_DIR"
if [ ! -f "$CERTS_DIR/ca-key.pem" ]; then
    echo "Generating certificates..."
    openssl genrsa -out "$CERTS_DIR/ca-key.pem" 4096
    openssl req -x509 -new -nodes -key "$CERTS_DIR/ca-key.pem" -sha256 -days 365 \
        -out "$CERTS_DIR/ca.pem" -subj "/CN=confluent-ca"
    openssl genrsa -out "$CERTS_DIR/privkey.pem" 2048
    cat > "$CERTS_DIR/ext.cnf" << EOF
[v3_req]
subjectAltName = DNS:*.svc.cluster.local,DNS:kafka.src.svc.cluster.local,DNS:kafka.dest.svc.cluster.local,DNS:zookeeper.src.svc.cluster.local,DNS:zookeeper.dest.svc.cluster.local,DNS:*.kafka.src.svc.cluster.local,DNS:*.kafka.dest.svc.cluster.local,DNS:*.zookeeper.src.svc.cluster.local,DNS:*.zookeeper.dest.svc.cluster.local
EOF
    openssl req -new -key "$CERTS_DIR/privkey.pem" -out "$CERTS_DIR/server.csr" -subj "/CN=*.svc.cluster.local"
    openssl x509 -req -in "$CERTS_DIR/server.csr" -CA "$CERTS_DIR/ca.pem" -CAkey "$CERTS_DIR/ca-key.pem" \
        -CAcreateserial -out "$CERTS_DIR/server.pem" -days 365 -sha256 -extfile "$CERTS_DIR/ext.cnf" -extensions v3_req
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

# SOURCE (public) cluster credentials
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

# DESTINATION (private) cluster credentials (DIFFERENT from source!)
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
echo "Deploying clusters..."
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/"

echo "Waiting for ZooKeeper pods to be created..."
until kubectl get pods -l app=zookeeper -n $SRC_NS 2>/dev/null | grep -q zookeeper; do sleep 2; done
until kubectl get pods -l app=zookeeper -n $DEST_NS 2>/dev/null | grep -q zookeeper; do sleep 2; done

echo "Waiting for ZooKeeper to be ready..."
kubectl wait --for=condition=Ready pod -l app=zookeeper -n $SRC_NS --timeout=300s
kubectl wait --for=condition=Ready pod -l app=zookeeper -n $DEST_NS --timeout=300s

echo "Waiting for Kafka pods to be created..."
until kubectl get pods -l app=kafka -n $SRC_NS 2>/dev/null | grep -q kafka; do sleep 2; done
until kubectl get pods -l app=kafka -n $DEST_NS 2>/dev/null | grep -q kafka; do sleep 2; done

echo "Waiting for Kafka to be ready..."
kubectl wait --for=condition=Ready pod -l app=kafka -n $SRC_NS --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kafka -n $DEST_NS --timeout=300s

# Get cluster ID
echo "Getting public cluster ID..."
sleep 20
SRC_CLUSTER_ID=""
for i in {1..30}; do
    SRC_CLUSTER_ID=$(kubectl get kafkarestclass src-rest -n $SRC_NS -o jsonpath='{.status.kafkaClusterID}' 2>/dev/null || echo "")
    if [ -n "$SRC_CLUSTER_ID" ]; then break; fi
    echo "  Waiting... ($i/30)"
    sleep 5
done

if [ -z "$SRC_CLUSTER_ID" ]; then
    echo "ERROR: Could not get cluster ID"
    exit 1
fi
echo "Public cluster ID: $SRC_CLUSTER_ID"

# Create ClusterLinks
echo ""
echo "Creating OUTBOUND link (public cluster) FIRST..."
kubectl apply -f "$SCRIPT_DIR/manifests/clusterlinks/src-clusterlink.yaml"

echo "Creating INBOUND link (private cluster) with cluster ID..."
cat "$SCRIPT_DIR/manifests/clusterlinks/dest-clusterlink.yaml" | \
    sed "s/\${SOURCE_CLUSTER_ID}/$SRC_CLUSTER_ID/g" | \
    kubectl apply -f -

echo ""
echo "Setup complete!"
echo "⚠️  IMPORTANT: Wait for OUTBOUND link to be healthy FIRST"
echo ""
echo "Monitor with:"
echo "  kubectl get clusterlink -n $SRC_NS   # Should be healthy first"
echo "  kubectl get clusterlink -n $DEST_NS  # Then this one"

