#!/bin/bash
# Setup script for Bidirectional Cluster Link - ZooKeeper Basic
# Prerequisites: Run ../../setup_cfk.sh first to install CFK
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_NS="src"
DEST_NS="dest"

echo "=========================================="
echo "Bidirectional Cluster Link - ZooKeeper Basic"
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

# Create namespaces (idempotent - in case running without setup_cfk.sh)
echo ""
echo "Ensuring namespaces exist..."
kubectl create namespace $SRC_NS --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $DEST_NS --dry-run=client -o yaml | kubectl apply -f -

# Create secrets
echo "Creating secrets..."
kubectl apply -f "$SCRIPT_DIR/manifests/secrets/" -n $SRC_NS
kubectl apply -f "$SCRIPT_DIR/manifests/secrets/" -n $DEST_NS

# Deploy source cluster
echo ""
echo "Deploying source cluster..."
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/zookeeper.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/kafka.yaml"

# Deploy destination cluster
echo "Deploying destination cluster..."
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/zookeeper.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/kafka.yaml"

# Wait for ZooKeeper
echo ""
echo "Waiting for ZooKeeper clusters..."
kubectl wait --for=condition=Ready pod -l app=zookeeper -n $SRC_NS --timeout=300s
kubectl wait --for=condition=Ready pod -l app=zookeeper -n $DEST_NS --timeout=300s

# Wait for Kafka
echo "Waiting for Kafka clusters..."
kubectl wait --for=condition=Ready pod -l app=kafka -n $SRC_NS --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kafka -n $DEST_NS --timeout=300s

# Create KafkaRestClass
echo ""
echo "Creating KafkaRestClass..."
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/kafkarestclass.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/kafkarestclass.yaml"

sleep 10

# Create topics
echo "Creating topics..."
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/topics.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/topics.yaml"

sleep 10

# Create ClusterLinks
echo ""
echo "Creating ClusterLinks..."
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/clusterlink.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/clusterlink.yaml"

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "Monitor status with:"
echo "  kubectl get clusterlink -n $SRC_NS"
echo "  kubectl get clusterlink -n $DEST_NS"

