#!/bin/bash
# Pre-Setup: One-time environment setup
# Run this once to deploy operator, create namespace, and secrets

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step() {
    echo -e "\n${GREEN}==>${NC} $1"
}

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

# Print command, ask Y/n, execute or skip.
# If something fails mid-run, re-run the script and answer "n" to skip
# already-completed commands, then "y" to resume from where it failed.
run_cmd() {
    echo ""
    echo -e "${BLUE}  \$ $*${NC}"
    read -p "$(echo -e "${YELLOW}  Run? [Y/n]${NC} > ")" -r
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo_info "  Skipped."
        return 0
    fi
    "$@"
}

# Configuration
NAMESPACE="${NAMESPACE:-confluent}"
PROJECT_ID="${PROJECT_ID:-<your-gcp-project>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Operator image version
OPERATOR_VERSION="${OPERATOR_VERSION:-latest}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Static→Dynamic Migration - Pre-Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "This script sets up the one-time prerequisites:"
echo "  1. Namespace ($NAMESPACE)"
echo "  2. StorageClass (retain-sc — PVs persist across rolls)"
echo "  3. Secrets (registry credentials)"
echo "  4. Confluent Operator"
echo ""
echo "Configuration:"
echo "  - Namespace:          $NAMESPACE"
echo "  - GCP Project ID:    $PROJECT_ID"
echo "  - Operator version:  $OPERATOR_VERSION"
echo ""

# Step 1: Create Namespace
print_step "Step 1: Create Namespace"
run_cmd kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Create StorageClass with Retain policy
print_step "Step 2: Create StorageClass (retain-sc)"
echo ""
echo "PVs must persist across rolling restarts to preserve data and directory IDs."
if kubectl get storageclass retain-sc &>/dev/null; then
    echo_info "retain-sc already exists (skipping)"
else
    run_cmd kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: retain-sc
provisioner: pd.csi.storage.gke.io
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: pd-standard
EOF
fi

# Step 3: Create Registry Secret
print_step "Step 3: Create Registry Secret"
echo ""
echo "Image pull secret for pulling from container registry"
if kubectl get secret confluent-registry -n "$NAMESPACE" &>/dev/null; then
    echo_info "confluent-registry already exists in $NAMESPACE (skipping)"
else
    ECR_PASSWORD="${ECR_PASSWORD:-$(gcloud auth print-access-token)}"
    run_cmd kubectl create secret docker-registry confluent-registry \
        --docker-server=docker.io \
        --docker-username=_token \
        --docker-password="$ECR_PASSWORD" \
        -n "$NAMESPACE"
fi

# Step 4: Deploy Confluent Operator
print_step "Step 4: Deploy Confluent Operator via Helm"
echo ""
echo "Operator image: confluent-operator:${OPERATOR_VERSION}"
run_cmd helm upgrade --install \
    -f  \
    confluent-operator confluentinc/confluent-for-kubernetes \
    --set image.tag="${OPERATOR_VERSION}" \
    --namespace "$NAMESPACE"

# Done
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Pre-Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Run the migration:"
echo "     ./setup.sh"
echo ""
