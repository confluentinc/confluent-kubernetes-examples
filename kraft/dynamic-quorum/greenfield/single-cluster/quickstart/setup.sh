#!/bin/bash
# Dynamic Quorum (KIP-853) Setup Script
# This script sets up the required RBAC and ConfigMap for dynamic quorum,
# then deploys the KRaftController with dynamic quorum enabled.

set -e

NAMESPACE="${NAMESPACE:-confluent}"
KRAFTCONTROLLER_NAME="${KRAFTCONTROLLER_NAME:-kraftcontroller}"
CONFIG_MAP_NAME="${KRAFTCONTROLLER_NAME}-dynamic-quorum"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  setup            Create ConfigMap and RBAC, then apply KRaftController (default)"
    echo "  promote          Promote observer controllers to voters (for CP < 8.2)"
    echo "  deploy-kafka     Deploy Kafka cluster with dynamic KRaft controllers"
    echo "  cleanup          Delete KRaftController, ConfigMap, and RBAC resources"
    echo "  reset            Delete pods to restart with fresh ConfigMap state"
    echo "  status           Show status of dynamic quorum resources"
    echo "  watch            Watch quorum replication status (voters/observers)"
    echo ""
    echo "Environment variables:"
    echo "  NAMESPACE            Kubernetes namespace (default: confluent)"
    echo "  KRAFTCONTROLLER_NAME Name of KRaftController (default: kraftcontroller)"
    echo ""
    echo "Examples:"
    echo "  $0 setup"
    echo "  $0 promote           # For CP < 8.2 only (8.2+ auto-promotes)"
    echo "  $0 deploy-kafka"
    echo "  $0 watch             # Monitor voter/observer status (Ctrl+C to stop)"
    echo "  NAMESPACE=kafka $0 setup"
    echo "  $0 cleanup"
    exit 1
}

create_namespace() {
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        echo_info "Creating namespace $NAMESPACE..."
        kubectl create namespace "$NAMESPACE"
    else
        echo_info "Namespace $NAMESPACE already exists"
    fi
}

create_configmap() {
    echo_info "Creating ConfigMap $CONFIG_MAP_NAME..."
    if kubectl get configmap "$CONFIG_MAP_NAME" -n "$NAMESPACE" &>/dev/null; then
        echo_warn "ConfigMap already exists, deleting and recreating..."
        kubectl delete configmap "$CONFIG_MAP_NAME" -n "$NAMESPACE"
    fi
    
    kubectl create configmap "$CONFIG_MAP_NAME" \
        --from-literal=bootstrap-status='{"bootstrap_formatted": false}' \
        -n "$NAMESPACE"
    
    echo_info "ConfigMap created successfully"
}

create_rbac() {
    local role_name="${CONFIG_MAP_NAME}-role"
    local binding_name="${CONFIG_MAP_NAME}-binding"
    local service_account="${SERVICE_ACCOUNT:-default}"
    
    echo_info "Creating RBAC resources..."
    
    # Delete existing role and rolebinding if they exist
    kubectl delete role "$role_name" -n "$NAMESPACE" 2>/dev/null || true
    kubectl delete rolebinding "$binding_name" -n "$NAMESPACE" 2>/dev/null || true
    
    # Create Role
    kubectl create role "$role_name" \
        --verb=get,update,patch \
        --resource=configmaps \
        --resource-name="$CONFIG_MAP_NAME" \
        -n "$NAMESPACE"
    
    # Create RoleBinding
    kubectl create rolebinding "$binding_name" \
        --role="$role_name" \
        --serviceaccount="${NAMESPACE}:${service_account}" \
        -n "$NAMESPACE"
    
    echo_info "RBAC resources created successfully"
}

apply_kraftcontroller() {
    local yaml_file="$SCRIPT_DIR/resources/kraftcontroller-dynamic.yaml"
    
    if [ ! -f "$yaml_file" ]; then
        echo_error "KRaftController YAML not found at $yaml_file"
        exit 1
    fi
    
    echo_info "Applying KRaftController from $yaml_file..."
    
    # Apply with namespace override if needed
    kubectl apply -f "$yaml_file" -n "$NAMESPACE"
    
    echo_info "KRaftController applied successfully"
    echo ""
    echo_info "Monitor pods with: kubectl get pods -n $NAMESPACE -l app=kraftcontroller -w"
    echo_info "Check init logs: kubectl logs <pod-name> -n $NAMESPACE -c config-init-container"
    echo_info "Check ConfigMap: kubectl get configmap $CONFIG_MAP_NAME -n $NAMESPACE -o yaml"
}

cleanup() {
    echo_info "Cleaning up dynamic quorum resources..."
    
    local role_name="${CONFIG_MAP_NAME}-role"
    local binding_name="${CONFIG_MAP_NAME}-binding"
    
    echo_info "Deleting KRaftController..."
    kubectl delete kraftcontroller "$KRAFTCONTROLLER_NAME" -n "$NAMESPACE" 2>/dev/null || echo_warn "KRaftController not found"
    
    echo_info "Deleting RBAC resources..."
    kubectl delete rolebinding "$binding_name" -n "$NAMESPACE" 2>/dev/null || echo_warn "RoleBinding not found"
    kubectl delete role "$role_name" -n "$NAMESPACE" 2>/dev/null || echo_warn "Role not found"
    
    echo_info "Deleting ConfigMap..."
    kubectl delete configmap "$CONFIG_MAP_NAME" -n "$NAMESPACE" 2>/dev/null || echo_warn "ConfigMap not found"
    
    echo_info "Cleanup complete"
}

reset_pods() {
    echo_info "Resetting dynamic quorum pods..."
    
    # Reset ConfigMap
    echo_info "Resetting ConfigMap to initial state..."
    kubectl patch configmap "$CONFIG_MAP_NAME" -n "$NAMESPACE" \
        --type='merge' \
        -p '{"data":{"bootstrap-status":"{\"bootstrap_formatted\": false}"}}'
    
    # Delete pods
    echo_info "Deleting KRaftController pods..."
    kubectl delete pods -n "$NAMESPACE" -l "app=kraftcontroller,platform.confluent.io/name=$KRAFTCONTROLLER_NAME"
    
    echo_info "Pods will be recreated by StatefulSet"
    echo_info "Monitor with: kubectl get pods -n $NAMESPACE -l app=kraftcontroller -w"
}

promote_observers() {
    echo_info "=== Promoting Observer Controllers to Voters ==="
    echo ""

    # Get replica count
    REPLICAS=$(kubectl get kraftcontroller "$KRAFTCONTROLLER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    if [ -z "$REPLICAS" ]; then
        echo_error "Failed to get replica count from KRaftController"
        return 1
    fi

    echo_info "KRaftController has $REPLICAS replicas"

    # Wait for all pods to be ready
    echo_info "Waiting for all KRaftController pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=kraftcontroller -n "$NAMESPACE" --timeout=300s || {
        echo_warn "Some pods may not be ready yet, continuing anyway..."
    }

    # Get bootstrap pod index from CR
    BOOTSTRAP_POD=$(kubectl get kraftcontroller "$KRAFTCONTROLLER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.dynamicQuorumConfig.bootstrapPod}' 2>/dev/null)
    BOOTSTRAP_POD=${BOOTSTRAP_POD:-0}

    echo_info "Bootstrap pod index: $BOOTSTRAP_POD"
    echo_info "Bootstrap controller: ${KRAFTCONTROLLER_NAME}-${BOOTSTRAP_POD}"
    echo ""

    # Show current quorum status before promotion
    echo_info "Current quorum status:"
    kubectl exec "${KRAFTCONTROLLER_NAME}-${BOOTSTRAP_POD}" -n "$NAMESPACE" -- \
        kafka-metadata-quorum --bootstrap-controller "${KRAFTCONTROLLER_NAME}-${BOOTSTRAP_POD}.${KRAFTCONTROLLER_NAME}.${NAMESPACE}.svc.cluster.local:9074" \
        describe --status 2>/dev/null || echo_warn "Failed to get quorum status"
    echo ""

    # Promote each observer to voter (skip bootstrap pod)
    for ((i=0; i<REPLICAS; i++)); do
        if [ "$i" -eq "$BOOTSTRAP_POD" ]; then
            echo_info "Skipping ${KRAFTCONTROLLER_NAME}-${i} (bootstrap pod, already a voter)"
            continue
        fi

        POD_NAME="${KRAFTCONTROLLER_NAME}-${i}"
        echo_info "Promoting ${POD_NAME} from observer to voter..."

        # Check if pod exists and is ready
        if ! kubectl get pod "$POD_NAME" -n "$NAMESPACE" &>/dev/null; then
            echo_warn "Pod ${POD_NAME} not found, skipping..."
            continue
        fi

        # Add controller to quorum
        # Execute FROM the observer pod, connecting TO the bootstrap controller
        # The observer pod adds itself to the quorum
        
        # Create a temporary config file with expanded POD_NAME variable
        # The kafka-metadata-quorum CLI tool doesn't expand ConfigProvider variables like ${env:POD_NAME}
        # so we need to expand them manually
        kubectl exec "${POD_NAME}" -n "$NAMESPACE" -- \
            sh -c "sed 's/\${env:POD_NAME}/'${POD_NAME}'/g' /opt/confluentinc/etc/kafka/kafka.properties > /tmp/kafka.properties"
        
        kubectl exec "${POD_NAME}" -n "$NAMESPACE" -- \
            kafka-metadata-quorum --bootstrap-controller "${KRAFTCONTROLLER_NAME}-${BOOTSTRAP_POD}.${KRAFTCONTROLLER_NAME}.${NAMESPACE}.svc.cluster.local:9074" \
            --command-config /tmp/kafka.properties \
            add-controller && {
            echo_info "✓ Successfully promoted ${POD_NAME}"
        } || {
            echo_error "✗ Failed to promote ${POD_NAME}"
        }
        echo ""

        # Small delay between promotions
        sleep 2
    done

    echo ""
    echo_info "=== Final Quorum Status ==="
    kubectl exec "${KRAFTCONTROLLER_NAME}-${BOOTSTRAP_POD}" -n "$NAMESPACE" -- \
        kafka-metadata-quorum --bootstrap-controller "${KRAFTCONTROLLER_NAME}-${BOOTSTRAP_POD}.${KRAFTCONTROLLER_NAME}.${NAMESPACE}.svc.cluster.local:9074" \
        describe --status 2>/dev/null || echo_warn "Failed to get final quorum status"
}

deploy_kafka() {
    local kafka_yaml="$SCRIPT_DIR/resources/kafka-with-dynamic-kraft.yaml"

    if [ ! -f "$kafka_yaml" ]; then
        echo_error "Kafka YAML not found at $kafka_yaml"
        return 1
    fi

    echo_info "=== Deploying Kafka with Dynamic KRaft ==="
    kubectl apply -f "$kafka_yaml" -n "$NAMESPACE"

    echo_info "Kafka deployed successfully"
    echo_info "Monitor with: kubectl get pods -n $NAMESPACE -l app=kafka -w"
}

show_status() {
    echo_info "=== Dynamic Quorum Status ==="
    echo ""

    echo_info "ConfigMap:"
    kubectl get configmap "$CONFIG_MAP_NAME" -n "$NAMESPACE" -o yaml 2>/dev/null || echo_warn "ConfigMap not found"
    echo ""

    echo_info "RBAC:"
    kubectl get role "${CONFIG_MAP_NAME}-role" -n "$NAMESPACE" 2>/dev/null || echo_warn "Role not found"
    kubectl get rolebinding "${CONFIG_MAP_NAME}-binding" -n "$NAMESPACE" 2>/dev/null || echo_warn "RoleBinding not found"
    echo ""

    echo_info "KRaftController:"
    kubectl get kraftcontroller "$KRAFTCONTROLLER_NAME" -n "$NAMESPACE" 2>/dev/null || echo_warn "KRaftController not found"
    echo ""

    echo_info "Pods:"
    kubectl get pods -n "$NAMESPACE" -l "app=kraftcontroller" -o wide 2>/dev/null || echo_warn "No pods found"
    echo ""

    echo_info "Quorum Status:"
    BOOTSTRAP_POD=$(kubectl get kraftcontroller "$KRAFTCONTROLLER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.dynamicQuorumConfig.bootstrapPod}' 2>/dev/null)
    BOOTSTRAP_POD=${BOOTSTRAP_POD:-0}
    kubectl exec "${KRAFTCONTROLLER_NAME}-${BOOTSTRAP_POD}" -n "$NAMESPACE" -- \
        kafka-metadata-quorum --bootstrap-controller "${KRAFTCONTROLLER_NAME}-${BOOTSTRAP_POD}.${KRAFTCONTROLLER_NAME}.${NAMESPACE}.svc.cluster.local:9074" \
        describe --status 2>/dev/null || echo_warn "Failed to get quorum status"
}

watch_quorum() {
    echo_info "=== Watching Quorum Replication Status ==="
    echo ""

    # Get bootstrap pod index from CR
    BOOTSTRAP_POD=$(kubectl get kraftcontroller "$KRAFTCONTROLLER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.dynamicQuorumConfig.bootstrapPod}' 2>/dev/null)
    BOOTSTRAP_POD=${BOOTSTRAP_POD:-0}

    echo_info "Bootstrap controller: ${KRAFTCONTROLLER_NAME}-${BOOTSTRAP_POD}"
    echo_info "Press Ctrl+C to stop watching"
    echo ""

    # Use watch to continuously monitor replication status
    watch -n 2 "kubectl exec ${KRAFTCONTROLLER_NAME}-${BOOTSTRAP_POD} -n $NAMESPACE -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        describe --replication 2>/dev/null || echo 'Failed to get replication status'"
}

# Main
COMMAND="${1:-setup}"

case "$COMMAND" in
    setup)
        create_namespace
        create_configmap
        create_rbac
        apply_kraftcontroller
        ;;
    promote)
        promote_observers
        ;;
    deploy-kafka)
        deploy_kafka
        ;;
    cleanup)
        cleanup
        ;;
    reset)
        reset_pods
        ;;
    status)
        show_status
        ;;
    watch)
        watch_quorum
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo_error "Unknown command: $COMMAND"
        usage
        ;;
esac


