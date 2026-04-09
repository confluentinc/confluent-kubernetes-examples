#!/bin/bash
# Cleanup: Phased teardown of migration resources
# Mirrors the setup in reverse: CP resources → operator/infra → namespace

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
KRAFTCONTROLLER_NAME="${KRAFTCONTROLLER_NAME:-kraftcontroller}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Static→Dynamic Migration - Cleanup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Namespace: $NAMESPACE"
echo ""

# Phase 1: Delete CP resources (Kafka, KRaftController)
print_step "Phase 1: Delete Confluent Platform resources"
echo ""
echo "This will delete Kafka CR, KRaftController CR, and associated PVCs."

run_cmd kubectl delete kafka kafka -n "$NAMESPACE" --timeout=5m 2>/dev/null || print_warning "Kafka not found"
run_cmd kubectl delete kraftcontroller "$KRAFTCONTROLLER_NAME" -n "$NAMESPACE" --timeout=5m 2>/dev/null || print_warning "KRaftController not found"

echo_info "Waiting for pods to terminate..."
run_cmd kubectl wait --for=delete pod -l app=kafka -n "$NAMESPACE" --timeout=3m 2>/dev/null || true
run_cmd kubectl wait --for=delete pod -l app=kraftcontroller -n "$NAMESPACE" --timeout=3m 2>/dev/null || true

echo_info "Deleting PVCs..."
run_cmd kubectl delete pvc -l app=kafka -n "$NAMESPACE" 2>/dev/null || true
run_cmd kubectl delete pvc -l app=kraftcontroller -n "$NAMESPACE" 2>/dev/null || true

# Phase 2: Delete operator and infrastructure
print_step "Phase 2: Delete Operator and infrastructure"
echo ""
echo "This will delete Confluent Operator (Helm release)."

run_cmd helm uninstall confluent-operator -n "$NAMESPACE" 2>/dev/null || print_warning "Operator Helm release not found"

# Phase 3: Delete namespace
print_step "Phase 3: Delete namespace"
echo ""
echo "This will delete the entire namespace '$NAMESPACE' and ALL remaining resources in it."

run_cmd kubectl delete namespace "$NAMESPACE" --timeout=5m 2>/dev/null || print_warning "Namespace not found"

# Done
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Cleanup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
