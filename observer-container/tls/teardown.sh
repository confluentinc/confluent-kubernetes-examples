#!/bin/bash
#
# Observer Container - TLS Teardown Script
# =========================================
# Cleans up all resources created by setup.sh
#
# Usage:
#   ./teardown.sh [--namespace <ns>] [--keep-certs]
#
# Options:
#   --namespace <ns>  Target namespace (default: operator)
#   --keep-certs      Don't delete generated certificate files
#

set -e

# =============================================================================
# Configuration
# =============================================================================

NAMESPACE="${NAMESPACE:-operator}"
TUTORIAL_HOME=$(pwd)
KEEP_CERTS=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --keep-certs)
            KEEP_CERTS=true
            shift
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
# Cleanup Kubernetes Resources
# =============================================================================

log_info "Starting cleanup in namespace: $NAMESPACE"

log_info "Deleting Confluent Platform components..."
kubectl delete -f "$TUTORIAL_HOME/manifests/confluent_platform.yaml" --ignore-not-found=true 2>/dev/null || true
kubectl delete -f "$TUTORIAL_HOME/manifests/confluent_platform_mtls.yaml" --ignore-not-found=true 2>/dev/null || true
kubectl delete -f "$TUTORIAL_HOME/manifests/confluent_platform_dpic.yaml" --ignore-not-found=true 2>/dev/null || true

log_info "Deleting secrets..."
kubectl delete secret credential -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
kubectl delete secret ca-pair-sslcerts -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
kubectl delete secret tls-kraft -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
kubectl delete secret tls-kafka -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
kubectl delete secret confluent-registry -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

log_info "Deleting ConfigMaps..."
kubectl delete cm -l app=kraftcontroller -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
kubectl delete cm -l app=kafka -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

# =============================================================================
# Cleanup Local Files
# =============================================================================

if [ "$KEEP_CERTS" = false ]; then
    log_info "Cleaning up generated certificates..."
    rm -rf "$TUTORIAL_HOME/certs/generated/"*
    rm -rf "$TUTORIAL_HOME/certs/ca/"*
    log_success "Certificate files removed"
else
    log_info "Keeping certificate files (--keep-certs specified)"
fi

# =============================================================================
# Delete Namespace (optional)
# =============================================================================

# Check if namespace is empty
REMAINING=$(kubectl get all -n "$NAMESPACE" 2>/dev/null | grep -v "^NAME" | wc -l)
if [ "$REMAINING" -eq 0 ]; then
    log_info "Deleting empty namespace: $NAMESPACE"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
else
    log_warn "Namespace $NAMESPACE still has resources, not deleting"
    log_warn "Delete manually with: kubectl delete namespace $NAMESPACE"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
log_success "=============================================="
log_success "  Observer Container Teardown Complete!"
log_success "=============================================="
echo ""
log_info "Cleaned up:"
echo "  - Confluent Platform manifests"
echo "  - TLS secrets"
echo "  - Credential secrets"
if [ "$KEEP_CERTS" = false ]; then
    echo "  - Generated certificate files"
fi
echo ""
log_info "For Vault cleanup, run: ./teardown_vault.sh"
