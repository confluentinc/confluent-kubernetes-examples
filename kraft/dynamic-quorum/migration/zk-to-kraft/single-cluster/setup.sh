#!/bin/bash
# Setup script for quickstart ZK to KRaft migration with dynamic quorum

NAMESPACE="confluent"

echo "=========================================="
echo "  Quickstart ZK→KRaft Migration Setup"
echo "=========================================="
echo ""
echo "This script will guide you through each setup step."
echo "You can skip steps that are already completed."
echo ""

# Helper function for yes/no prompts
ask_step() {
    while true; do
        read -p "$1 (y/n): " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

# Health check functions
check_zk_health() {
    echo "  Checking ZooKeeper quorum..."
    for i in 0 1 2; do
        local mode=$(kubectl exec zookeeper-$i -n $NAMESPACE -- bash -c "
            kafka-run-class org.apache.zookeeper.client.FourLetterWordMain localhost 2181 srvr 2>/dev/null
        " 2>/dev/null | grep "Mode:" | awk '{print $2}')
        if [ -n "$mode" ]; then
            echo "    zookeeper-$i: $mode"
        fi
    done
}

check_kafka_health() {
    echo "  Testing Kafka cluster (create/produce/consume)..."
    local topic="test-topic-$(date +%s)"
    local test_message="test-message-$(date +%s)"

    echo "    Topic: $topic"
    echo "    Message: $test_message"
    echo ""

    # Create test topic
    echo "    → Creating topic..."
    if ! kubectl exec kafka-0 -n $NAMESPACE -- kafka-topics --bootstrap-server localhost:9092 \
        --create --topic "$topic" --partitions 1 --replication-factor 1; then
        echo "    ⚠️  Cannot create topic (Kafka may still be starting)"
        return 1
    fi
    echo ""

    # Produce message
    echo "    → Producing message..."
    if ! kubectl exec kafka-0 -n $NAMESPACE -- bash -c \
        "echo '$test_message' | kafka-console-producer --bootstrap-server localhost:9092 --topic $topic"; then
        echo "    ⚠️  Cannot produce messages"
        kubectl exec kafka-0 -n $NAMESPACE -- kafka-topics --bootstrap-server localhost:9092 --delete --topic "$topic"
        return 1
    fi
    echo ""

    # Consume message
    echo "    → Consuming message..."
    if ! kubectl exec kafka-0 -n $NAMESPACE -- kafka-console-consumer --bootstrap-server localhost:9092 \
        --topic "$topic" --from-beginning --max-messages 1 --timeout-ms 5000; then
        echo "    ⚠️  Cannot consume messages"
        kubectl exec kafka-0 -n $NAMESPACE -- kafka-topics --bootstrap-server localhost:9092 --delete --topic "$topic"
        return 1
    fi
    echo ""

    # Cleanup
    echo "    → Deleting test topic..."
    kubectl exec kafka-0 -n $NAMESPACE -- kafka-topics --bootstrap-server localhost:9092 --delete --topic "$topic"
    echo ""

    echo "    ✓ Kafka cluster healthy (create/produce/consume all working)"
}

# Step 1: Create namespace
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Create namespace '$NAMESPACE'"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ask_step "Create/update namespace?"; then
    kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
    echo "✓ Namespace ready"
else
    echo "⊘ Skipped"
fi
echo ""

# Step 2: Deploy dynamic quorum RBAC
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Deploy dynamic quorum RBAC"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ask_step "Deploy ServiceAccount, Role, and RoleBinding for ConfigMap updates?"; then
    kubectl apply -f resources/dynamic-quorum-rbac.yaml
    echo "✓ RBAC resources created"
else
    echo "⊘ Skipped"
fi
echo ""

# Step 3: Deploy ConfigMap
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Deploy dynamic quorum ConfigMap"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ask_step "Deploy/update dynamic quorum ConfigMap?"; then
    kubectl apply -f resources/dynamic-quorum-configmap.yaml
    echo "✓ ConfigMap created"
else
    echo "⊘ Skipped"
fi
echo ""

# Step 4: Deploy ZooKeeper
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4: Deploy ZooKeeper (3 replicas)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ask_step "Deploy/update ZooKeeper?"; then
    kubectl apply -f resources/zookeeper.yaml
    if ask_step "Wait for ZooKeeper to be ready?"; then
        echo "Waiting for ZooKeeper..."
        kubectl wait --for=condition=platform.confluent.io/cluster-ready zookeeper/zookeeper -n $NAMESPACE --timeout=10m || echo "⚠️  Timeout - check status manually"
    fi
    echo "✓ ZooKeeper deployed"
else
    echo "⊘ Skipped"
fi

if ask_step "Check ZooKeeper health (quorum status)?"; then
    check_zk_health
fi
echo ""

# Step 5: Deploy Kafka
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5: Deploy Kafka (3 replicas)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ask_step "Deploy/update Kafka?"; then
    kubectl apply -f resources/kafka.yaml
    if ask_step "Wait for Kafka to be ready?"; then
        echo "Waiting for Kafka..."
        kubectl wait --for=condition=platform.confluent.io/cluster-ready kafka/kafka -n $NAMESPACE --timeout=10m || echo "⚠️  Timeout - check status manually"
    fi
    echo "✓ Kafka deployed"
else
    echo "⊘ Skipped"
fi

if ask_step "Check Kafka health (broker status)?"; then
    check_kafka_health
fi
echo ""

# Step 6: Deploy KRaftController
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 6: Deploy KRaftController (3 replicas with dynamic quorum)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Note: KRaftController will remain on hold until migration job starts"
if ask_step "Deploy/update KRaftController?"; then
    kubectl apply -f resources/kraftcontroller.yaml
    echo "✓ KRaftController deployed (holding for migration)"
else
    echo "⊘ Skipped"
fi
echo ""

# Show status
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Current Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kubectl get zookeeper,kafka,kraftcontroller -n $NAMESPACE
echo ""

echo "=========================================="
echo "  ✅ Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo ""
echo "1. Start migration:"
echo "   kubectl apply -f resources/kraftmigrationjob.yaml"
echo ""
echo "2. Monitor progress:"
echo "   kubectl get kraftmigrationjob -n $NAMESPACE -w"
echo ""
echo "3. Once migration reaches DUAL_WRITE phase:"
echo "   - Verify system stability"
echo "   - Promote KRaft observer pods (1 and 2) to voters:"
echo "     kubectl exec kraftcontroller-0 -n $NAMESPACE -- \\"
echo "       kafka-metadata-quorum --bootstrap-controller localhost:9074 add-voter 9991 kraftcontroller-1.kraftcontroller.$NAMESPACE.svc.cluster.local:9074"
echo "     kubectl exec kraftcontroller-0 -n $NAMESPACE -- \\"
echo "       kafka-metadata-quorum --bootstrap-controller localhost:9074 add-voter 9992 kraftcontroller-2.kraftcontroller.$NAMESPACE.svc.cluster.local:9074"
echo ""
echo "4. Check quorum status:"
echo "   kubectl exec kraftcontroller-0 -n $NAMESPACE -- \\"
echo "     kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --status"
echo ""
echo "5. After verification, finalize migration:"
echo "   kubectl annotate kraftmigrationjob kraftmigrationjob -n $NAMESPACE \\"
echo "     platform.confluent.io/kraft-migration-trigger-finalize-to-kraft='true'"
echo ""
