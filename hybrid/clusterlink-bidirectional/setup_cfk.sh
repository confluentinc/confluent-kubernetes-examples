#!/bin/bash
# CFK Installation Script
# Installs CFK in a single namespace. Call multiple times for multiple instances.
#
# Examples:
#   # Single CFK watching all namespaces
#   ./setup_cfk.sh --namespace confluent --all-namespaces
#
#   # Two CFK instances, each watching its own namespace
#   ./setup_cfk.sh --namespace src --namespaced
#   ./setup_cfk.sh --namespace dest --namespaced
#
#   # With custom image
#   ./setup_cfk.sh --namespace src --namespaced \
#     --registry docker.io/confluentinc \
#     --repository confluent-operator \
#     --tag v0.1431.0-19-g4dca185-amd64 \
#     --pull-secret confluent-registry
set -e

# Configuration - can be overridden via environment variables
NAMESPACE="${NAMESPACE:-confluent}"
NAMESPACED="${NAMESPACED:-false}"
CFK_VERSION="${CFK_VERSION:-0.1351.59}"
HELM_REPO_NAME="${HELM_REPO_NAME:-confluentinc}"
HELM_REPO_URL="${HELM_REPO_URL:-https://packages.confluent.io/helm}"
CHART_NAME="${CHART_NAME:-confluent-for-kubernetes}"
RELEASE_NAME="${RELEASE_NAME:-}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-}"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --namespace NS        Namespace to install CFK (default: confluent)"
    echo "  --namespaced          Watch only the install namespace (namespaced=true)"
    echo "  --all-namespaces      Watch all namespaces (namespaced=false, default)"
    echo "  --version VERSION     CFK Helm chart version (default: $CFK_VERSION)"
    echo "  --release NAME        Helm release name (default: cfk-operator or cfk-operator-<ns>)"
    echo "  --repo-name NAME      Helm repo name (default: $HELM_REPO_NAME)"
    echo "  --repo-url URL        Helm repo URL (default: $HELM_REPO_URL)"
    echo "  --chart NAME          Helm chart name (default: $CHART_NAME)"
    echo "  --registry REGISTRY   Image registry (e.g., docker.io/confluentinc)"
    echo "  --repository REPO     Image repository (e.g., confluent-operator)"
    echo "  --tag TAG             Image tag (e.g., v0.1431.0)"
    echo "  --pull-secret SECRET  Image pull secret name"
    echo "  --help                Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Single CFK watching all namespaces"
    echo "  $0 --namespace confluent --all-namespaces"
    echo ""
    echo "  # Two CFK instances, each watching its own namespace"
    echo "  $0 --namespace src --namespaced"
    echo "  $0 --namespace dest --namespaced"
    echo ""
    echo "  # With custom image"
    echo "  $0 --namespace src --namespaced \\"
    echo "    --registry docker.io/confluentinc \\"
    echo "    --repository confluent-operator \\"
    echo "    --tag v0.1431.0 \\"
    echo "    --pull-secret confluent-registry"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --namespaced)
            NAMESPACED="true"
            shift
            ;;
        --all-namespaces)
            NAMESPACED="false"
            shift
            ;;
        --version)
            CFK_VERSION="$2"
            shift 2
            ;;
        --release)
            RELEASE_NAME="$2"
            shift 2
            ;;
        --repo-name)
            HELM_REPO_NAME="$2"
            shift 2
            ;;
        --repo-url)
            HELM_REPO_URL="$2"
            shift 2
            ;;
        --chart)
            CHART_NAME="$2"
            shift 2
            ;;
        --registry)
            IMAGE_REGISTRY="$2"
            shift 2
            ;;
        --repository)
            IMAGE_REPOSITORY="$2"
            shift 2
            ;;
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --pull-secret)
            IMAGE_PULL_SECRET="$2"
            shift 2
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

# Auto-generate release name if not set
if [ -z "$RELEASE_NAME" ]; then
    if [ "$NAMESPACED" = "true" ]; then
        RELEASE_NAME="cfk-operator-$NAMESPACE"
    else
        RELEASE_NAME="cfk-operator"
    fi
fi

echo "=========================================="
echo "CFK Installation"
echo "=========================================="
echo "Namespace: $NAMESPACE"
echo "Namespaced: $NAMESPACED"
echo "Release: $RELEASE_NAME"
echo "CFK Version: $CFK_VERSION"
echo "Helm Repo: $HELM_REPO_NAME ($HELM_REPO_URL)"
[ -n "$IMAGE_REGISTRY" ] && echo "Image Registry: $IMAGE_REGISTRY"
[ -n "$IMAGE_REPOSITORY" ] && echo "Image Repository: $IMAGE_REPOSITORY"
[ -n "$IMAGE_TAG" ] && echo "Image Tag: $IMAGE_TAG"
[ -n "$IMAGE_PULL_SECRET" ] && echo "Pull Secret: $IMAGE_PULL_SECRET"
echo ""

# Build extra Helm args
EXTRA_HELM_ARGS=""
[ -n "$IMAGE_REGISTRY" ] && EXTRA_HELM_ARGS="$EXTRA_HELM_ARGS --set image.registry=$IMAGE_REGISTRY"
[ -n "$IMAGE_REPOSITORY" ] && EXTRA_HELM_ARGS="$EXTRA_HELM_ARGS --set image.repository=$IMAGE_REPOSITORY"
[ -n "$IMAGE_TAG" ] && EXTRA_HELM_ARGS="$EXTRA_HELM_ARGS --set image.tag=$IMAGE_TAG"
[ -n "$IMAGE_PULL_SECRET" ] && EXTRA_HELM_ARGS="$EXTRA_HELM_ARGS --set imagePullSecretRef=$IMAGE_PULL_SECRET"

# Add Helm repo (idempotent)
echo "Adding Helm repository: $HELM_REPO_NAME..."
helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" 2>/dev/null || true
helm repo update

# Create namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create image pull secret if specified and doesn't exist
if [ -n "$IMAGE_PULL_SECRET" ]; then
    if ! kubectl get secret "$IMAGE_PULL_SECRET" -n "$NAMESPACE" &>/dev/null; then
        echo "Creating image pull secret: $IMAGE_PULL_SECRET"
        # For GCR, use gcloud auth token
        if [[ "$IMAGE_REGISTRY" == *"gcr.io"* ]]; then
            DOCKER_USER="_token"
            DOCKER_PASSWORD=$(gcloud auth print-access-token)
            DOCKER_EMAIL="${GCR_EMAIL:-$(gcloud config get-value account 2>/dev/null)}"
            kubectl create secret docker-registry "$IMAGE_PULL_SECRET" \
                --namespace "$NAMESPACE" \
                --docker-server="$IMAGE_REGISTRY" \
                --docker-username="$DOCKER_USER" \
                --docker-password="$DOCKER_PASSWORD" \
                --docker-email="$DOCKER_EMAIL"
        else
            echo "WARNING: Image pull secret '$IMAGE_PULL_SECRET' does not exist and registry is not GCR."
            echo "Please create the secret manually before running this script."
        fi
    else
        echo "Image pull secret '$IMAGE_PULL_SECRET' already exists."
    fi
fi

# Install CFK
echo ""
echo "Installing CFK..."
# shellcheck disable=SC2086
helm upgrade --install "$RELEASE_NAME" "$HELM_REPO_NAME/$CHART_NAME" \
    --version "$CFK_VERSION" \
    --namespace "$NAMESPACE" \
    --set namespaced=$NAMESPACED \
    --set name="$RELEASE_NAME" \
    $EXTRA_HELM_ARGS

# Wait for CFK to be ready
echo ""
echo "Waiting for CFK operator to be ready..."
kubectl wait --for=condition=Available deployment/"$RELEASE_NAME" -n "$NAMESPACE" --timeout=300s

echo ""
echo "=========================================="
echo "CFK Installation Complete!"
echo "=========================================="
echo "Release: $RELEASE_NAME"
echo "Namespace: $NAMESPACE"
if [ "$NAMESPACED" = "true" ]; then
    echo "Watching: $NAMESPACE only"
else
    echo "Watching: All namespaces"
fi
