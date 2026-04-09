#!/bin/bash
# Setup script for Bidirectional Cluster Link - KRaft Basic
# Prerequisites: Run ../../setup_cfk.sh first to install CFK
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_NS="src"
DEST_NS="dest"

echo "=========================================="
echo "Bidirectional Cluster Link - KRaft Basic"
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

# Create secrets
echo "Creating secrets..."
kubectl apply -f "$SCRIPT_DIR/manifests/secrets/" -n $SRC_NS
kubectl apply -f "$SCRIPT_DIR/manifests/secrets/" -n $DEST_NS

# Deploy source cluster
echo ""
echo "Deploying source cluster in namespace: $SRC_NS"
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/kraftcontroller.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/kafka.yaml"

# Deploy destination cluster
echo "Deploying destination cluster in namespace: $DEST_NS"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/kraftcontroller.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/kafka.yaml"

# Wait for KRaft controllers to be ready
echo ""
echo "Waiting for KRaft controllers to be ready..."
kubectl wait --for=condition=Ready pod -l app=kraftcontroller -n $SRC_NS --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kraftcontroller -n $DEST_NS --timeout=300s

# Wait for Kafka clusters to be ready
echo "Waiting for Kafka clusters to be ready..."
kubectl wait --for=condition=Ready pod -l app=kafka -n $SRC_NS --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kafka -n $DEST_NS --timeout=300s

# Create KafkaRestClass
echo ""
echo "Creating KafkaRestClass resources..."
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/kafkarestclass.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/kafkarestclass.yaml"

# Wait for KafkaRestClass to be ready
echo "Waiting for KafkaRestClass to report cluster IDs..."
sleep 10  # Allow time for REST API to become available

# Create topics
echo ""
echo "Creating topics..."
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/topics.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/topics.yaml"

# Wait for topics to be created
echo "Waiting for topics to be created..."
sleep 15

# Create ClusterLinks (both must be created for bidirectional to work)
echo ""
echo "Creating ClusterLinks..."
echo "  - dest-cluster-link (handles forward mirroring: src -> dest)"
kubectl apply -f "$SCRIPT_DIR/manifests/dest-cluster/clusterlink.yaml"

echo "  - src-cluster-link (handles reverse mirroring: dest -> src)"
kubectl apply -f "$SCRIPT_DIR/manifests/src-cluster/clusterlink.yaml"

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "Waiting for ClusterLinks to become healthy..."
echo "This may take 2-3 minutes."
echo ""
echo "Check status with:"
echo "  kubectl get clusterlink -n $SRC_NS"
echo "  kubectl get clusterlink -n $DEST_NS"
echo ""
echo "Once both show 'Created' state, run ./validate.sh to test bidirectional mirroring."

