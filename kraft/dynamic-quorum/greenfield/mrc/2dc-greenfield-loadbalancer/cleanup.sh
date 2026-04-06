#!/bin/bash
# Cleanup: MRC Greenfield (True Multi-Cluster, Secured, LoadBalancer)
# Tears down CP resources, security secrets, Keycloak, and infrastructure on both clusters

set -e

# ============================================================
# Configuration
# ============================================================
REGION1_NS="${REGION1_NS:-central}"
REGION2_NS="${REGION2_NS:-east}"
REGION1_CONTEXT="${REGION1_CONTEXT:-<your-region1-k8s-context>}"
REGION2_CONTEXT="${REGION2_CONTEXT:-<your-region2-k8s-context>}"
KRAFTCONTROLLER_NAME="${KRAFTCONTROLLER_NAME:-kraftcontroller}"
KAFKA_NAME="${KAFKA_NAME:-kafka}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/.generated-certs"

# Colors + helpers
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step() { echo -e "\n${GREEN}==>${NC} $1"; }
echo_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }

run_cmd() {
    echo ""
    echo -e "${BLUE}  \$ $*${NC}"
    echo -en "${YELLOW}  Run? [Y/n]${NC} > "
    read -r REPLY
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo_info "  Skipped."
        return 0
    fi
    "$@"
}

# Helpers
kube1() { kubectl --context "$REGION1_CONTEXT" "$@"; }
kube2() { kubectl --context "$REGION2_CONTEXT" "$@"; }

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  MRC Greenfield (LoadBalancer) - Cleanup${NC}"
echo -e "${BLUE}  (True Multi-Cluster, Secured)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "  Region 1: $REGION1_NS on my-cluster"
echo "  Region 2: $REGION2_NS on my-clusterdev"
echo ""

# ============================================================
# Phase 1: Delete CP resources (Kafka, KRaftController, PVCs)
# ============================================================
print_step "Phase 1: Delete Confluent Platform resources"
echo "This will delete Kafka, KRaftController CRs, and PVCs on both clusters."

# Region 1
echo_info "Region 1 ($REGION1_NS on my-cluster)..."
run_cmd kube1 delete kafka $KAFKA_NAME -n $REGION1_NS --timeout=5m 2>/dev/null || print_warning "Kafka not found in $REGION1_NS"
run_cmd kube1 delete kraftcontroller $KRAFTCONTROLLER_NAME -n $REGION1_NS --timeout=5m 2>/dev/null || print_warning "KRaftController not found in $REGION1_NS"
run_cmd kube1 wait --for=delete pod -l app=kafka -n $REGION1_NS --timeout=3m 2>/dev/null || true
run_cmd kube1 wait --for=delete pod -l app=kraftcontroller -n $REGION1_NS --timeout=3m 2>/dev/null || true

# Region 2
echo_info "Region 2 ($REGION2_NS on my-clusterdev)..."
run_cmd kube2 delete kafka $KAFKA_NAME -n $REGION2_NS --timeout=5m 2>/dev/null || print_warning "Kafka not found in $REGION2_NS"
run_cmd kube2 delete kraftcontroller $KRAFTCONTROLLER_NAME -n $REGION2_NS --timeout=5m 2>/dev/null || print_warning "KRaftController not found in $REGION2_NS"
run_cmd kube2 wait --for=delete pod -l app=kafka -n $REGION2_NS --timeout=3m 2>/dev/null || true
run_cmd kube2 wait --for=delete pod -l app=kraftcontroller -n $REGION2_NS --timeout=3m 2>/dev/null || true

# ============================================================
# Phase 2: Delete Bootstrap ConfigMap & RBAC
# ============================================================
print_step "Phase 2: Delete Bootstrap ConfigMap & RBAC (Region 1)"
run_cmd kube1 delete configmap kraftcontroller-dynamic-quorum -n $REGION1_NS 2>/dev/null || print_warning "ConfigMap not found"
run_cmd kube1 delete rolebinding kraftcontroller-bootstrap-rolebinding -n $REGION1_NS 2>/dev/null || true
run_cmd kube1 delete role kraftcontroller-bootstrap-role -n $REGION1_NS 2>/dev/null || true
run_cmd kube1 delete serviceaccount kraftcontroller-sa -n $REGION1_NS 2>/dev/null || true

# ============================================================
# Phase 3: Delete Keycloak
# ============================================================
print_step "Phase 3: Delete Keycloak (Central Identity Provider)"
echo "This will delete Keycloak deployment and configmap from Region 1."

run_cmd kube1 delete deployment keycloak -n $REGION1_NS 2>/dev/null || print_warning "Keycloak not found on my-cluster"
run_cmd kube1 delete service keycloak -n $REGION1_NS 2>/dev/null || true
run_cmd kube1 delete configmap keycloak-configmap -n $REGION1_NS 2>/dev/null || true

# ============================================================
# Phase 4: Delete operator and infrastructure
# ============================================================
print_step "Phase 4: Delete operator and infrastructure"
echo "This will uninstall the operator and delete all secrets on both clusters."

run_cmd helm --kube-context "$REGION1_CONTEXT" uninstall confluent-operator -n $REGION1_NS 2>/dev/null || print_warning "Operator not found on my-cluster"
run_cmd helm --kube-context "$REGION2_CONTEXT" uninstall confluent-operator -n $REGION2_NS 2>/dev/null || print_warning "Operator not found on my-clusterdev"

# Delete secrets (TLS, credentials, MDS, registry) and admin config
echo_info "Deleting secrets and configmaps on both clusters..."
for secret in confluent-registry tls-kraftcontroller tls-kafka credential mds-token oauth-jass; do
    run_cmd kube1 delete secret $secret -n $REGION1_NS 2>/dev/null || true
    run_cmd kube2 delete secret $secret -n $REGION2_NS 2>/dev/null || true
done
run_cmd kube1 delete configmap kraft-admin-config -n $REGION1_NS 2>/dev/null || true
run_cmd kube2 delete configmap kraft-admin-config -n $REGION2_NS 2>/dev/null || true

# ============================================================
# Phase 5: Delete namespaces
# ============================================================
print_step "Phase 5: Delete namespaces"
echo "This will delete namespaces and ALL remaining resources in them."

run_cmd kube1 delete namespace $REGION1_NS --timeout=5m 2>/dev/null || print_warning "Namespace $REGION1_NS not found"
run_cmd kube2 delete namespace $REGION2_NS --timeout=5m 2>/dev/null || print_warning "Namespace $REGION2_NS not found"

# ============================================================
# Phase 6: Clean up generated certificates
# ============================================================
print_step "Phase 6: Clean up generated certificates"
if [[ -d "$CERT_DIR" ]]; then
    echo "This will delete generated certificates in $CERT_DIR"
    run_cmd rm -rf "$CERT_DIR"
else
    echo_info "No generated certificates found."
fi

# ============================================================
# Done
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Cleanup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Cleaned up:"
echo "  - CP resources (Kafka + KRaftController on both clusters)"
echo "  - Bootstrap ConfigMap & RBAC (Region 1)"
echo "  - Keycloak (central identity provider, region 1 only)"
echo "  - Operator (Helm release on both clusters)"
echo "  - Secrets (TLS, credentials, MDS, OAuth, registry on both clusters)"
echo "  - Namespaces ($REGION1_NS, $REGION2_NS)"
echo "  - Generated certificates ($CERT_DIR)"
