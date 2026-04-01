#!/bin/bash
#
# Observer Container - Vault DPIC Setup Script
# =============================================
# Installs HashiCorp Vault and configures it for Observer Container
# certificate injection using Directory Path In Container (DPIC).
#
# Prerequisites:
#   - kubectl configured with cluster access
#   - Helm 3 installed
#   - Certificates generated (run setup.sh first)
#
# Usage:
#   ./setup_vault.sh [--namespace <ns>]
#
# Options:
#   --namespace <ns>  Target namespace (default: operator)
#

set -e

# =============================================================================
# Configuration
# =============================================================================

NAMESPACE="${NAMESPACE:-operator}"
TUTORIAL_HOME=$(pwd)
CERT_PATH="$TUTORIAL_HOME/certs"

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
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# Pre-flight Checks
# =============================================================================

log_info "Running pre-flight checks..."

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please install kubectl."
    exit 1
fi

# Check helm
if ! command -v helm &> /dev/null; then
    log_error "helm not found. Please install Helm 3."
    exit 1
fi

# Check certificates exist
if [ ! -f "$CERT_PATH/ca/ca.pem" ]; then
    log_error "Certificates not found. Run ./setup.sh first."
    exit 1
fi

log_success "Pre-flight checks passed"

# =============================================================================
# Namespace Setup
# =============================================================================

log_info "Ensuring namespace exists: $NAMESPACE"
kubectl create ns "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# =============================================================================
# Vault Installation
# =============================================================================

log_info "Adding HashiCorp Helm repository..."
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update

log_info "Installing Vault in dev mode..."
helm upgrade --install vault hashicorp/vault \
    --namespace "$NAMESPACE" \
    --set='server.dev.enabled=true' \
    --set='injector.enabled=true' \
    --wait

log_info "Waiting for Vault pod to be ready..."
kubectl wait --for=condition=ready --timeout=300s pod -l app.kubernetes.io/name=vault -n "$NAMESPACE"

log_success "Vault installed successfully"

# =============================================================================
# Vault Configuration
# =============================================================================

log_info "Configuring Vault policies and authentication..."

# Create policy file
cat <<EOF > /tmp/app-policy.hcl
path "secret*" {
  capabilities = ["read"]
}
EOF

kubectl -n "$NAMESPACE" cp /tmp/app-policy.hcl vault-0:/tmp/app-policy.hcl

# Configure Vault
kubectl -n "$NAMESPACE" exec vault-0 -- vault write sys/policy/app policy=@/tmp/app-policy.hcl

# Enable Kubernetes authentication if not already enabled
kubectl -n "$NAMESPACE" exec vault-0 -- sh -c '
vault auth list | grep -q "kubernetes/" || vault auth enable kubernetes
'

# Configure Kubernetes auth
kubectl -n "$NAMESPACE" exec vault-0 -- sh -c '
vault write auth/kubernetes/config \
    kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_PORT_443_TCP_PORT \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    token_reviewer_jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
'

# Create role for Confluent components
kubectl -n "$NAMESPACE" exec vault-0 -- vault write auth/kubernetes/role/confluent-operator \
    bound_service_account_names=default \
    bound_service_account_namespaces="$NAMESPACE" \
    policies=app \
    ttl=1h

# Enable KV secrets engine if not already enabled
kubectl -n "$NAMESPACE" exec vault-0 -- sh -c '
vault secrets list | grep -q "secret/" || vault secrets enable -path=secret kv
'

log_success "Vault configuration completed"

# =============================================================================
# Store Certificates in Vault
# =============================================================================

log_info "Copying certificates to Vault pod..."
kubectl cp "$CERT_PATH" vault-0:/tmp/certs -n "$NAMESPACE"

log_info "Storing KRaft certificates in Vault..."
kubectl -n "$NAMESPACE" exec vault-0 -- sh -c '
# Create base64 encoded certificate files
cat /tmp/certs/ca/ca.pem | base64 | tr -d "\n" > /tmp/kraft-ca.b64
cat /tmp/certs/generated/kraft-server.pem | base64 | tr -d "\n" > /tmp/kraft-cert.b64
cat /tmp/certs/generated/kraft-server-key.pem | base64 | tr -d "\n" > /tmp/kraft-key.b64

# Store in Vault
vault kv put /secret/tls-kraft \
    cacerts=$(cat /tmp/kraft-ca.b64) \
    fullchain=$(cat /tmp/kraft-cert.b64) \
    privkey=$(cat /tmp/kraft-key.b64)
'

log_info "Storing Kafka certificates in Vault..."
kubectl -n "$NAMESPACE" exec vault-0 -- sh -c '
# Create base64 encoded certificate files
cat /tmp/certs/ca/ca.pem | base64 | tr -d "\n" > /tmp/kafka-ca.b64
cat /tmp/certs/generated/kafka-server.pem | base64 | tr -d "\n" > /tmp/kafka-cert.b64
cat /tmp/certs/generated/kafka-server-key.pem | base64 | tr -d "\n" > /tmp/kafka-key.b64

# Store in Vault
vault kv put /secret/tls-kafka \
    cacerts=$(cat /tmp/kafka-ca.b64) \
    fullchain=$(cat /tmp/kafka-cert.b64) \
    privkey=$(cat /tmp/kafka-key.b64)
'

log_success "Certificates stored in Vault"

# =============================================================================
# Verification
# =============================================================================

log_info "Verifying Vault secrets..."
echo ""
echo "KRaft certificates:"
kubectl -n "$NAMESPACE" exec vault-0 -- vault kv get -format=json /secret/tls-kraft | jq -r '.data | keys'
echo ""
echo "Kafka certificates:"
kubectl -n "$NAMESPACE" exec vault-0 -- vault kv get -format=json /secret/tls-kafka | jq -r '.data | keys'

# =============================================================================
# Cleanup
# =============================================================================

rm -f /tmp/app-policy.hcl

# =============================================================================
# Summary
# =============================================================================

echo ""
log_success "=============================================="
log_success "  Vault DPIC Setup Complete!"
log_success "=============================================="
echo ""
log_info "Vault secrets created:"
echo "  - /secret/tls-kraft (cacerts, fullchain, privkey)"
echo "  - /secret/tls-kafka (cacerts, fullchain, privkey)"
echo ""
log_info "Next steps:"
echo "  1. Deploy with DPIC: kubectl apply -f manifests/confluent_platform_dpic.yaml"
echo "  2. Verify injection: kubectl logs <pod> -c vault-agent-init -n $NAMESPACE"
echo "  3. Check certs: kubectl exec <pod> -c observer -n $NAMESPACE -- ls /mnt/dpic/certs/"
echo ""
log_info "Vault UI: kubectl port-forward vault-0 8200:8200 -n $NAMESPACE"
log_info "Vault token (dev mode): root"
