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
kubectl delete -f sql/statement.yaml -n operator $ignore
kubectl delete -f sql/create-tables.yaml -n operator $ignore
kubectl delete -f sql/computepool-shared.yaml -f sql/computepool-dedicated.yaml -n operator $ignore
kubectl delete -f sql/kafkadatabase.yaml -n operator $ignore
kubectl delete -f sql/kafkacatalog.yaml -n operator $ignore
kubectl delete -f sql/secretmapping.yaml -n operator $ignore
kubectl delete -f sql/flinksecret.yaml -n operator $ignore

# Deleting the statements/pools above asks CMF to delete each one's FlinkDeployment, and FKO owns
# the FlinkDeployment finalizer. Wait for those jobs to drain while CMF and FKO are both still up;
# otherwise they get orphaned (stuck Terminating, pods still running) in the environment namespace.
echo "==> Waiting for Flink jobs (FlinkDeployments) to finish terminating..."
kubectl wait --for=delete flinkdeployment --all -n default --timeout=180s 2>/dev/null || true

# Delete FlinkEnvironment before CMFRestClass: the environment's delete finalizer reaches CMF through
# the CMFRestClass endpoint, so removing the CMFRestClass first can leave the environment stuck terminating.
echo "==> Deleting FlinkEnvironment..."
kubectl delete -f platform/flinkenvironment.yaml -n operator $ignore
echo "==> Deleting CMFRestClass..."
kubectl delete -f platform/cmfrestclass.yaml -n operator $ignore
kubectl delete secret cmf-day2-tls -n operator $ignore

echo "==> Deleting Kafka and Schema Registry..."
kubectl delete -f platform/kafka.yaml -n operator $ignore

echo "==> Uninstalling CFK and CMF..."
helm uninstall confluent-operator -n operator || true
helm uninstall cmf -n operator || true
kubectl delete configmap cmf-keystore cmf-truststore -n operator $ignore
kubectl delete secret cmf-license -n operator $ignore

echo "==> Uninstalling the Flink Kubernetes Operator..."
helm uninstall cp-flink-kubernetes-operator || true

echo "==> Removing the generated certs (certs/ca, certs/generated, certs/jks)..."
rm -rf "$TUTORIAL_HOME"/certs/ca "$TUTORIAL_HOME"/certs/generated "$TUTORIAL_HOME"/certs/jks

echo ""
echo "Teardown complete. The 'operator' namespace and cert-manager are left in place;"
echo "remove them manually if you no longer need them:"
echo "  kubectl delete namespace operator"
