#!/bin/bash
# Cleanup: MRC ZK->KRaft Migration (True Multi-Cluster, Secured)
# Tears down CP resources, security secrets, Keycloak, and infrastructure on both clusters
# Runs both regions in parallel for speed. Force-removes finalizers on stuck resources.

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

kube1() { kubectl --context "$REGION1_CONTEXT" "$@"; }
kube2() { kubectl --context "$REGION2_CONTEXT" "$@"; }

# Delete a CFK CR — try normal delete with short timeout, strip finalizers if stuck
force_delete() {
    local kube_fn="$1"
    local kind="$2"
    local name="$3"
    local ns="$4"

    # Check if resource exists
    if ! $kube_fn get "$kind" "$name" -n "$ns" &>/dev/null; then
        return 0
    fi

    echo_info "  Deleting $kind/$name in $ns..."
    # Try normal delete with 30s timeout
    if $kube_fn delete "$kind" "$name" -n "$ns" --timeout=30s &>/dev/null; then
        return 0
    fi

    # Stuck on finalizer — strip it
    print_warning "  $kind/$name stuck, removing finalizers..."
    $kube_fn patch "$kind" "$name" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' &>/dev/null || true
    # Wait briefly for deletion
    sleep 3
    # Force delete if still around
    $kube_fn delete "$kind" "$name" -n "$ns" --timeout=10s &>/dev/null || true
}

# Delete all CP resources in a region (runs as a unit, called in background)
cleanup_region() {
    local kube_fn="$1"
    local ns="$2"
    local label="$3"

    echo_info "[$label] Cleaning up namespace $ns..."

    # Phase 1: KRaftMigrationJob
    force_delete "$kube_fn" kraftmigrationjob kraftmigrationjob "$ns"

    # Phase 2: CP resources
    force_delete "$kube_fn" kafka "$KAFKA_NAME" "$ns"
    force_delete "$kube_fn" kraftcontroller "$KRAFTCONTROLLER_NAME" "$ns"
    force_delete "$kube_fn" zookeeper zookeeper "$ns"

    # Wait for pods to terminate (best effort, don't block forever)
    $kube_fn wait --for=delete pod -l app=kafka -n "$ns" --timeout=2m &>/dev/null || true
    $kube_fn wait --for=delete pod -l app=kraftcontroller -n "$ns" --timeout=2m &>/dev/null || true
    $kube_fn wait --for=delete pod -l app=zookeeper -n "$ns" --timeout=2m &>/dev/null || true

    # Phase 3: ConfigMap, RBAC, admin config
    $kube_fn delete configmap kraftcontroller-dynamic-quorum kraft-admin-config -n "$ns" &>/dev/null || true
    $kube_fn delete rolebinding kraftcontroller-configmap-updater -n "$ns" &>/dev/null || true
    $kube_fn delete role kraftcontroller-configmap-updater -n "$ns" &>/dev/null || true
    $kube_fn delete serviceaccount kraftcontroller-sa -n "$ns" &>/dev/null || true

    # Phase 4: PVCs
    $kube_fn delete pvc --all -n "$ns" --timeout=60s &>/dev/null || true

    echo_info "[$label] CP resources cleaned."
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  MRC ZK->KRaft Migration - Cleanup${NC}"
echo -e "${BLUE}  (True Multi-Cluster, Secured)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "  Region 1: $REGION1_NS on my-cluster"
echo "  Region 2: $REGION2_NS on my-clusterdev"
echo ""
read -p "Proceed with cleanup? (y/n): " -n 1 -r
echo
[[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }

# ============================================================
# Run both regions in parallel
# ============================================================
print_step "Phase 1-4: Deleting CP resources on both regions (parallel)"

cleanup_region kube1 "$REGION1_NS" "R1" &
PID1=$!
cleanup_region kube2 "$REGION2_NS" "R2" &
PID2=$!

echo_info "Waiting for both regions to finish..."
wait $PID1 || print_warning "Region 1 cleanup had issues"
wait $PID2 || print_warning "Region 2 cleanup had issues"
echo_info "Both regions done."

# ============================================================
# Phase 5: Keycloak (central only)
# ============================================================
print_step "Phase 5: Delete Keycloak (central only)"
kube1 delete deployment keycloak -n $REGION1_NS &>/dev/null || true
kube1 delete service keycloak -n $REGION1_NS &>/dev/null || true
kube1 delete configmap keycloak-configmap -n $REGION1_NS &>/dev/null || true

# ============================================================
# Phase 6: Operator + secrets (parallel)
# ============================================================
print_step "Phase 6: Uninstall operator and delete secrets (parallel)"

(
    helm --kube-context "$REGION1_CONTEXT" uninstall confluent-operator -n "$REGION1_NS" &>/dev/null || true
    for secret in tls-kraftcontroller tls-kafka tls-zookeeper credential mds-token oauth-jass; do
        kube1 delete secret "$secret" -n "$REGION1_NS" &>/dev/null || true
    done
    echo_info "[R1] Operator and secrets removed."
) &
(
    helm --kube-context "$REGION2_CONTEXT" uninstall confluent-operator -n "$REGION2_NS" &>/dev/null || true
    for secret in tls-kraftcontroller tls-kafka tls-zookeeper credential mds-token oauth-jass; do
        kube2 delete secret "$secret" -n "$REGION2_NS" &>/dev/null || true
    done
    echo_info "[R2] Operator and secrets removed."
) &
wait

# ============================================================
# Phase 7: Delete namespaces (parallel)
# ============================================================
print_step "Phase 7: Delete namespaces (parallel)"
kube1 delete namespace "$REGION1_NS" --timeout=5m &>/dev/null &
kube2 delete namespace "$REGION2_NS" --timeout=5m &>/dev/null &
wait
echo_info "Namespaces deleted."

# ============================================================
# Phase 8: Clean up generated certificates
# ============================================================
print_step "Phase 8: Clean up generated certificates"
if [[ -d "$CERT_DIR" ]]; then
    rm -rf "$CERT_DIR"
    echo_info "Deleted $CERT_DIR"
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
