#!/bin/bash
#
# Observer Container - TLS Setup Script
# =====================================
# This script generates TLS certificates and creates Kubernetes secrets
# for the Observer Container with Confluent Platform.
#
# Prerequisites:
#   - kubectl configured with cluster access
#   - cfssl installed (brew install cfssl / apt install golang-cfssl)
#   - gcloud authenticated (for GCR image pull)
#
# Usage:
#   ./setup.sh [--namespace <ns>] [--skip-deploy]
#
# Options:
#   --namespace <ns>  Target namespace (default: operator)
#   --skip-deploy     Only create secrets, don't deploy platform
#

set -e

# =============================================================================
# Configuration
# =============================================================================

NAMESPACE="${NAMESPACE:-operator}"
TUTORIAL_HOME=$(pwd)
SKIP_DEPLOY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --skip-deploy)
            SKIP_DEPLOY=true
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

# Check cfssl
if ! command -v cfssl &> /dev/null; then
    log_error "cfssl not found. Install with: brew install cfssl (macOS) or apt install golang-cfssl (Linux)"
    exit 1
fi

# Check cluster connectivity
if ! kubectl cluster-info &> /dev/null; then
    log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
    exit 1
fi

log_success "Pre-flight checks passed"

# =============================================================================
# Namespace Setup
# =============================================================================

log_info "Creating namespace: $NAMESPACE"
kubectl create ns "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# =============================================================================
# Certificate Generation
# =============================================================================

log_info "Generating CA certificate..."
mkdir -p "$TUTORIAL_HOME/certs/ca"
mkdir -p "$TUTORIAL_HOME/certs/generated"

# Generate CA key and certificate
openssl genrsa -out "$TUTORIAL_HOME/certs/ca/ca-key.pem" 2048 2>/dev/null
openssl req -new -key "$TUTORIAL_HOME/certs/ca/ca-key.pem" -x509 \
    -days 1000 \
    -out "$TUTORIAL_HOME/certs/ca/ca.pem" \
    -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA" 2>/dev/null

log_success "CA certificate generated"

# Generate KRaft server certificate
log_info "Generating KRaft server certificate..."
cfssl gencert \
    -ca="$TUTORIAL_HOME/certs/ca/ca.pem" \
    -ca-key="$TUTORIAL_HOME/certs/ca/ca-key.pem" \
    -config="$TUTORIAL_HOME/certs/server_configs/ca-config.json" \
    -profile=server \
    "$TUTORIAL_HOME/certs/server_configs/kraft-server-config.json" 2>/dev/null | \
    cfssljson -bare "$TUTORIAL_HOME/certs/generated/kraft-server"

log_success "KRaft certificate generated"

# Generate Kafka server certificate
log_info "Generating Kafka server certificate..."
cfssl gencert \
    -ca="$TUTORIAL_HOME/certs/ca/ca.pem" \
    -ca-key="$TUTORIAL_HOME/certs/ca/ca-key.pem" \
    -config="$TUTORIAL_HOME/certs/server_configs/ca-config.json" \
    -profile=server \
    "$TUTORIAL_HOME/certs/server_configs/kafka-server-config.json" 2>/dev/null | \
    cfssljson -bare "$TUTORIAL_HOME/certs/generated/kafka-server"

log_success "Kafka certificate generated"

# =============================================================================
# Kubernetes Secrets Creation
# =============================================================================

log_info "Creating Kubernetes secrets..."

# CA certificate secret
kubectl -n "$NAMESPACE" create secret tls ca-pair-sslcerts \
    --cert="$TUTORIAL_HOME/certs/ca/ca.pem" \
    --key="$TUTORIAL_HOME/certs/ca/ca-key.pem" \
    --dry-run=client -o yaml | kubectl apply -f -
log_success "Created secret: ca-pair-sslcerts"

# KRaft TLS secret
kubectl -n "$NAMESPACE" create secret generic tls-kraft \
    --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/kraft-server.pem" \
    --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/kraft-server-key.pem" \
    --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
    --dry-run=client -o yaml | kubectl apply -f -
log_success "Created secret: tls-kraft"

# Kafka TLS secret
kubectl -n "$NAMESPACE" create secret generic tls-kafka \
    --from-file=fullchain.pem="$TUTORIAL_HOME/certs/generated/kafka-server.pem" \
    --from-file=privkey.pem="$TUTORIAL_HOME/certs/generated/kafka-server-key.pem" \
    --from-file=cacerts.pem="$TUTORIAL_HOME/certs/ca/ca.pem" \
    --dry-run=client -o yaml | kubectl apply -f -
log_success "Created secret: tls-kafka"

# Credential secret
kubectl -n "$NAMESPACE" create secret generic credential \
    --from-file=plain-users.json="$TUTORIAL_HOME/creds/creds-kafka-sasl-users.json" \
    --from-file=plain.txt="$TUTORIAL_HOME/creds/creds-client-kafka-sasl-user.txt" \
    --dry-run=client -o yaml | kubectl apply -f -
log_success "Created secret: credential"

# =============================================================================
# Image Pull Secret
# =============================================================================

log_info "Creating image pull secret..."

# Check if gcloud is available
if command -v gcloud &> /dev/null; then
    USER="_token"
    APIKEY=$(gcloud auth print-access-token 2>/dev/null || echo "")
    
    if [ -n "$APIKEY" ]; then
        EMAIL="${EMAIL:-user@example.com}"
        kubectl -n "$NAMESPACE" create secret docker-registry confluent-registry \
            --docker-server=us.gcr.io/cc-devel \
            --docker-username="$USER" \
            --docker-password="$APIKEY" \
            --docker-email="$EMAIL" \
            --dry-run=client -o yaml | kubectl apply -f -
        log_success "Created secret: confluent-registry"
    else
        log_warn "Could not get GCP access token. Skipping confluent-registry secret."
        log_warn "Create it manually if using private images."
    fi
else
    log_warn "gcloud not found. Skipping confluent-registry secret."
    log_warn "Create it manually if using private images."
fi

# =============================================================================
# Deploy Confluent Platform (optional)
# =============================================================================

if [ "$SKIP_DEPLOY" = false ]; then
    log_info "Deploying Confluent Platform..."
    kubectl apply -f "$TUTORIAL_HOME/manifests/confluent_platform.yaml"
    
    log_info "Waiting for KRaftController to be ready..."
    kubectl wait --for=condition=ready --timeout=300s pod -l app=kraftcontroller -n "$NAMESPACE" || {
        log_warn "KRaftController not ready within timeout. Check logs with:"
        log_warn "  kubectl logs -l app=kraftcontroller -c observer -n $NAMESPACE"
    }
    
    log_info "Waiting for Kafka to be ready..."
    kubectl wait --for=condition=ready --timeout=300s pod -l app=kafka -n "$NAMESPACE" || {
        log_warn "Kafka not ready within timeout. Check logs with:"
        log_warn "  kubectl logs -l app=kafka -c observer -n $NAMESPACE"
    }
else
    log_info "Skipping deployment (--skip-deploy specified)"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
log_success "=============================================="
log_success "  Observer Container TLS Setup Complete!"
log_success "=============================================="
echo ""
log_info "Namespace: $NAMESPACE"
log_info "Secrets created:"
echo "  - ca-pair-sslcerts"
echo "  - tls-kraft"
echo "  - tls-kafka"
echo "  - credential"
echo "  - confluent-registry (if gcloud available)"
echo ""
log_info "Next steps:"
echo "  1. Check pods: kubectl get pods -n $NAMESPACE"
echo "  2. View observer logs: kubectl logs <pod> -c observer -n $NAMESPACE"
echo "  3. Test health: kubectl exec <pod> -c observer -n $NAMESPACE -- curl -sk https://localhost:7443/healthz"
echo ""
log_info "For Vault DPIC mode, run: ./setup_vault.sh"
