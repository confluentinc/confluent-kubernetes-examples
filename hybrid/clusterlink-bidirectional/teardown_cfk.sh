#!/bin/bash
# CFK Teardown Script
# Removes CFK from a single namespace. Call multiple times for multiple instances.
#
# Examples:
#   ./teardown_cfk.sh --namespace confluent
#   ./teardown_cfk.sh --namespace src --delete-namespace
#   ./teardown_cfk.sh --namespace dest --delete-namespace
set -e

NAMESPACE="${NAMESPACE:-confluent}"
RELEASE_NAME="${RELEASE_NAME:-}"
DELETE_NS="false"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --namespace NS        Namespace where CFK is installed (default: confluent)"
    echo "  --release NAME        Helm release name (auto-detected if not set)"
    echo "  --delete-namespace    Delete the namespace after uninstalling"
    echo "  --help                Show this help message"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --release)
            RELEASE_NAME="$2"
            shift 2
            ;;
        --delete-namespace)
            DELETE_NS="true"
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

echo "=========================================="
echo "CFK Teardown"
echo "=========================================="
echo "Namespace: $NAMESPACE"
echo ""

# Auto-detect release name if not set
if [ -z "$RELEASE_NAME" ]; then
    # Try to find CFK release in the namespace
    RELEASE_NAME=$(helm list -n "$NAMESPACE" -q | grep -E "^cfk-operator" | head -1) || true
fi

if [ -n "$RELEASE_NAME" ]; then
    echo "Uninstalling release: $RELEASE_NAME..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --ignore-not-found || true
else
    echo "No CFK release found in namespace $NAMESPACE"
fi

if [ "$DELETE_NS" = "true" ]; then
    echo ""
    echo "Deleting namespace: $NAMESPACE..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true || true
fi

echo ""
echo "=========================================="
echo "CFK Teardown Complete!"
echo "=========================================="
