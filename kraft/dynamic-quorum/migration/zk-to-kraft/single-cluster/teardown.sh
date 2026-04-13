#!/bin/bash
# Teardown script for quickstart ZK to KRaft migration

set -e

NAMESPACE="confluent"

echo "=========================================="
echo "  Quickstart Migration Cleanup"
echo "=========================================="
echo ""

# Delete KRaftMigrationJob
echo "🗑️  Deleting KRaftMigrationJob"
kubectl delete kraftmigrationjob kraftmigrationjob -n $NAMESPACE --ignore-not-found=true
echo ""

# Delete Kafka
echo "🗑️  Deleting Kafka"
kubectl delete kafka kafka -n $NAMESPACE --ignore-not-found=true --timeout=120s
echo ""

# Delete KRaftController
echo "🗑️  Deleting KRaftController"
kubectl delete kraftcontroller kraftcontroller -n $NAMESPACE --ignore-not-found=true --timeout=120s
echo ""

# Delete ZooKeeper
echo "🗑️  Deleting ZooKeeper"
kubectl delete zookeeper zookeeper -n $NAMESPACE --ignore-not-found=true --timeout=120s
echo ""

# Delete ConfigMap and RBAC
echo "🗑️  Deleting ConfigMap and RBAC resources"
kubectl delete configmap kraftcontroller-dynamic-quorum -n $NAMESPACE --ignore-not-found=true
kubectl delete rolebinding kraftcontroller-configmap-updater -n $NAMESPACE --ignore-not-found=true
kubectl delete role kraftcontroller-configmap-updater -n $NAMESPACE --ignore-not-found=true
kubectl delete serviceaccount kraftcontroller -n $NAMESPACE --ignore-not-found=true
echo ""

# Delete PVCs
echo "🗑️  Deleting PVCs"
kubectl delete pvc --all -n $NAMESPACE --timeout=60s
echo ""

# Option to delete namespace
echo ""
read -p "Delete namespace '$NAMESPACE'? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🗑️  Deleting namespace: $NAMESPACE"
    kubectl delete namespace $NAMESPACE --timeout=120s
    echo "✅ Cleanup complete!"
else
    echo "✅ Cleanup complete (namespace preserved)!"
fi
echo ""
