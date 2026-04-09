#!/bin/bash
# Teardown script for MRC Bidirectional Cluster Link (SASL-SSL)
# Deletes resources in reverse order on both GKE clusters
set -e

# ============================================================
# Configuration
# ============================================================
CENTRAL_NS="${CENTRAL_NS:-central}"
EAST_NS="${EAST_NS:-east}"
CENTRAL_CONTEXT="${CENTRAL_CONTEXT:-<central-cluster-context>}"
EAST_CONTEXT="${EAST_CONTEXT:-<east-cluster-context>}"

# ============================================================
# Colors + helpers
# ============================================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step()    { echo -e "\n${BLUE}[STEP]${NC} $1"; }
print_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

ask_yes_no() {
    local prompt="$1"
    echo -en "${YELLOW}${prompt} [Y/n]${NC} > "
    read -r REPLY
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        return 1
    fi
    return 0
}

# Helpers: kubectl scoped to each cluster
kube1() { kubectl --context "$CENTRAL_CONTEXT" "$@"; }
kube2() { kubectl --context "$EAST_CONTEXT" "$@"; }

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}  Tearing Down MRC Bidirectional Cluster Link${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo "This will delete all resources on both clusters:"
echo "  Central (<central-cluster>): namespace '$CENTRAL_NS'"
echo "  East (<east-cluster>):  namespace '$EAST_NS'"
echo ""

if ! ask_yes_no "Proceed with teardown?"; then
    print_info "Teardown cancelled."
    exit 0
fi

# ============================================================
# Step 1: Delete ClusterLinks
# ============================================================
print_step "Deleting ClusterLinks..."
kube1 delete clusterlink --all -n "$CENTRAL_NS" --ignore-not-found=true
kube2 delete clusterlink --all -n "$EAST_NS" --ignore-not-found=true

# ============================================================
# Step 2: Delete Topics
# ============================================================
print_step "Deleting KafkaTopics..."
kube1 delete kafkatopic --all -n "$CENTRAL_NS" --ignore-not-found=true
kube2 delete kafkatopic --all -n "$EAST_NS" --ignore-not-found=true

# ============================================================
# Step 3: Delete KafkaRestClass
# ============================================================
print_step "Deleting KafkaRestClass resources..."
kube1 delete kafkarestclass --all -n "$CENTRAL_NS" --ignore-not-found=true
kube2 delete kafkarestclass --all -n "$EAST_NS" --ignore-not-found=true

# ============================================================
# Step 4: Delete Kafka
# ============================================================
print_step "Deleting Kafka clusters..."
kube1 delete kafka --all -n "$CENTRAL_NS" --ignore-not-found=true
kube2 delete kafka --all -n "$EAST_NS" --ignore-not-found=true

# Wait for Kafka pods to terminate
print_info "Waiting for Kafka pods to terminate..."
kube1 wait --for=delete pod -l app=kafka -n "$CENTRAL_NS" --timeout=5m 2>/dev/null || true
kube2 wait --for=delete pod -l app=kafka -n "$EAST_NS" --timeout=5m 2>/dev/null || true

# ============================================================
# Step 5: Delete KRaftController
# ============================================================
print_step "Deleting KRaft controllers..."
kube1 delete kraftcontroller --all -n "$CENTRAL_NS" --ignore-not-found=true
kube2 delete kraftcontroller --all -n "$EAST_NS" --ignore-not-found=true

# Wait for KRaft pods to terminate
print_info "Waiting for KRaft pods to terminate..."
kube1 wait --for=delete pod -l app=kraftcontroller -n "$CENTRAL_NS" --timeout=5m 2>/dev/null || true
kube2 wait --for=delete pod -l app=kraftcontroller -n "$EAST_NS" --timeout=5m 2>/dev/null || true

# ============================================================
# Step 6: Delete Secrets (all created by setup.sh)
# ============================================================
print_step "Deleting secrets created by setup.sh..."

# Central cluster secrets
print_info "Deleting secrets on central cluster..."
kube1 delete secret credential -n "$CENTRAL_NS" --ignore-not-found=true
kube1 delete secret east-credential -n "$CENTRAL_NS" --ignore-not-found=true
kube1 delete secret kafkarest-credential -n "$CENTRAL_NS" --ignore-not-found=true
kube1 delete secret local-rest-credential -n "$CENTRAL_NS" --ignore-not-found=true
kube1 delete secret east-rest-credential -n "$CENTRAL_NS" --ignore-not-found=true
kube1 delete secret password-encoder-secret -n "$CENTRAL_NS" --ignore-not-found=true

# East cluster secrets
print_info "Deleting secrets on east cluster..."
kube2 delete secret credential -n "$EAST_NS" --ignore-not-found=true
kube2 delete secret central-credential -n "$EAST_NS" --ignore-not-found=true
kube2 delete secret kafkarest-credential -n "$EAST_NS" --ignore-not-found=true
kube2 delete secret local-rest-credential -n "$EAST_NS" --ignore-not-found=true
kube2 delete secret central-rest-credential -n "$EAST_NS" --ignore-not-found=true
kube2 delete secret password-encoder-secret -n "$EAST_NS" --ignore-not-found=true

# ============================================================
# Step 7: Delete PVCs
# ============================================================
print_step "Deleting PVCs..."
kube1 delete pvc --all -n "$CENTRAL_NS" --ignore-not-found=true
kube2 delete pvc --all -n "$EAST_NS" --ignore-not-found=true

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Teardown Complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "Remaining secrets NOT deleted (assumed pre-existing):"
echo "  - tls-kafka, tls-kraftcontroller, ca-pair-sslcerts"
echo ""
echo "To delete namespaces entirely:"
echo "  kubectl --context $CENTRAL_CONTEXT delete namespace $CENTRAL_NS"
echo "  kubectl --context $EAST_CONTEXT delete namespace $EAST_NS"
