#!/bin/bash
#
# Tears down everything setup.sh created, in reverse order. Run from this directory:
# ./teardown.sh. Idempotent: missing resources are ignored.

set -uo pipefail

export TUTORIAL_HOME
TUTORIAL_HOME="$(cd "$(dirname "$0")" && pwd)"
cd "$TUTORIAL_HOME" || exit 1

ignore="--ignore-not-found=true"

echo "==> Deleting the Flink SQL chain (reverse order)..."
kubectl delete -f sql/40-statement.yaml -n operator $ignore
kubectl delete -f sql/35-create-tables.yaml -n operator $ignore
kubectl delete -f sql/31-computepool-shared.yaml -f sql/30-computepool-dedicated.yaml -n operator $ignore
kubectl delete -f sql/20-kafkadatabase.yaml -n operator $ignore
kubectl delete -f sql/10-kafkacatalog.yaml -n operator $ignore
kubectl delete -f sql/05-secretmapping.yaml -n operator $ignore
kubectl delete -f sql/00-flinksecret.yaml -n operator $ignore

echo "==> Deleting FlinkEnvironment and CMFRestClass..."
kubectl delete -f platform/flinkenvironment.yaml -f platform/cmfrestclass.yaml -n operator $ignore
kubectl delete secret cmf-day2-tls -n operator $ignore

echo "==> Deleting Kafka and Schema Registry..."
kubectl delete -f platform/kafka.yaml -n operator $ignore

echo "==> Uninstalling CFK and CMF..."
helm uninstall confluent-operator -n operator || true
helm uninstall cmf -n operator || true
kubectl delete configmap cmf-keystore cmf-truststore -n operator $ignore
kubectl delete secret cmf-license -n operator $ignore

# Deleting the chain above asks CMF to delete each statement/pool's FlinkDeployment, but FKO owns
# the FlinkDeployment finalizer and must finish terminating them before it is removed -- otherwise
# the jobs are orphaned (stuck Terminating, pods still running) in the environment's namespace.
echo "==> Waiting for Flink jobs (FlinkDeployments) to finish terminating before removing FKO..."
kubectl wait --for=delete flinkdeployment --all -n default --timeout=180s 2>/dev/null || true

echo "==> Uninstalling the Flink Kubernetes Operator..."
helm uninstall cp-flink-kubernetes-operator || true

echo "==> Removing the generated certs (certs/ca, certs/generated, certs/jks)..."
rm -rf "$TUTORIAL_HOME"/certs/ca "$TUTORIAL_HOME"/certs/generated "$TUTORIAL_HOME"/certs/jks

echo ""
echo "Teardown complete. The 'operator' namespace and cert-manager are left in place;"
echo "remove them manually if you no longer need them:"
echo "  kubectl delete namespace operator"
