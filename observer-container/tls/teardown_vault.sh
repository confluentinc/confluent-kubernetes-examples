#!/bin/bash
#
# Observer Container - Vault Teardown Script
# ==========================================
# Removes HashiCorp Vault and cleans up DPIC resources.
#
# Usage:
#   ./teardown_vault.sh [--namespace <ns>]
#
# Options:
#   --namespace <ns>  Target namespace (default: operator)
#

set -e

# =============================================================================
# Configuration
# =============================================================================

NAMESPACE="${NAMESPACE:-operator}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# =============================================================================
# Cleanup Vault
# =============================================================================

log_info "Starting Vault cleanup in namespace: $NAMESPACE"

log_info "Uninstalling Vault Helm release..."
helm uninstall vault --namespace "$NAMESPACE" 2>/dev/null || {
    log_warn "Vault release not found or already removed"
}

log_info "Cleaning up Vault PVCs..."
kubectl delete pvc -l app.kubernetes.io/name=vault -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

log_info "Cleaning up Vault ServiceAccount..."
kubectl delete sa vault -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
kubectl delete sa vault-agent-injector -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

log_info "Cleaning up Vault ClusterRoleBindings..."
kubectl delete clusterrolebinding vault-agent-injector-binding --ignore-not-found=true 2>/dev/null || true
kubectl delete clusterrolebinding vault-server-binding --ignore-not-found=true 2>/dev/null || true

log_info "Cleaning up Vault MutatingWebhookConfiguration..."
kubectl delete mutatingwebhookconfiguration vault-agent-injector-cfg --ignore-not-found=true 2>/dev/null || true

# =============================================================================
# Summary
# =============================================================================

echo ""
log_success "=============================================="
log_success "  Vault Teardown Complete!"
log_success "=============================================="
echo ""
log_info "Cleaned up:"
echo "  - Vault Helm release"
echo "  - Vault PVCs"
echo "  - Vault ServiceAccounts"
echo "  - Vault ClusterRoleBindings"
echo "  - Vault MutatingWebhookConfiguration"
echo ""
log_info "For complete cleanup, also run: ./teardown.sh"
