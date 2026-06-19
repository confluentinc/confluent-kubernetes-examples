#!/bin/bash
#
# Sets up the CP Flink SQL tutorial end to end: FKO + CMF (mTLS) + CFK, a minimal
# Kafka + Schema Registry, then the full Day-2 chain
# (FlinkSecret -> FlinkKafkaCatalog -> FlinkKafkaDatabase -> FlinkComputePool ->
# CREATE TABLE -> FlinkStatement). Run from this directory: ./setup.sh
#
# Mirrors Readme.md step for step. Two prerequisites the script does NOT paper over:
#   1. Preview: needs a CFK build that ships `enableFlinkSQL` and a CMF build with the
#      Flink SQL REST API. With the public chart this is not yet available.
#   2. The committed certs/ + jks/ are demo material shared with flink/mTLS and are
#      EXPIRED; regenerate them (and the cmf-keystore/cmf-truststore inputs) for a real
#      run, or mTLS to CMF will fail.
#
# Optional env vars:
#   CMF_LICENSE_FILE   path to a CMF license.txt (if set, a license secret is created)

set -euo pipefail

export TUTORIAL_HOME
TUTORIAL_HOME="$(cd "$(dirname "$0")" && pwd)"
cd "$TUTORIAL_HOME"

CMF_LICENSE_FILE="${CMF_LICENSE_FILE:-}"

# wait_for <kind/name> <jsonpath> <expected> [timeout]
wait_for() {
  kubectl wait --for=jsonpath="$2"="$3" "$1" -n operator --timeout="${4:-180s}"
}

echo "==> Installing the Flink Kubernetes Operator (FKO) and cert-manager..."
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.8.2/cert-manager.yaml
kubectl wait --for=condition=available --timeout=300s deployment --all -n cert-manager
helm upgrade --install cp-flink-kubernetes-operator confluentinc/flink-kubernetes-operator

echo "==> Creating the operator namespace and CMF keystore/truststore configMaps..."
kubectl create namespace operator --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap cmf-keystore -n operator --from-file ./jks/keystore.jks \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap cmf-truststore -n operator --from-file ./jks/truststore.jks \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Deploying CMF with mTLS..."
cat > /tmp/cmf-local.yaml <<'EOF'
cmf:
  ssl:
    keystore: /opt/keystore/keystore.jks
    keystore-password: allpassword
    trust-store: /opt/truststore/truststore.jks
    trust-store-password: allpassword
    client-auth: need
  authentication:
    type: mtls
  k8s:
    enabled: true
mountedVolumes:
  volumeMounts:
    - name: truststore
      mountPath: /opt/truststore
    - name: keystore
      mountPath: /opt/keystore
  volumes:
    - name: truststore
      configMap:
        name: cmf-truststore
    - name: keystore
      configMap:
        name: cmf-keystore
EOF
if [ -n "$CMF_LICENSE_FILE" ]; then
  kubectl create secret generic cmf-license -n operator \
    --from-file=license.txt="$CMF_LICENSE_FILE" --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install -f /tmp/cmf-local.yaml cmf \
    confluentinc/confluent-manager-for-apache-flink \
    --set license.secretRef=cmf-license --namespace operator
else
  echo "    (no CMF_LICENSE_FILE set; deploying CMF in trial mode)"
  helm upgrade --install -f /tmp/cmf-local.yaml cmf \
    confluentinc/confluent-manager-for-apache-flink --namespace operator
fi
kubectl wait --for=condition=available --timeout=300s \
  deployment/confluent-manager-for-apache-flink -n operator

echo "==> Deploying CFK with the CMF Day-2 and Flink SQL feature flags..."
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --namespace operator \
  --set enableCMFDay2Ops=true \
  --set enableFlinkSQL=true
kubectl rollout status deployment/confluent-operator -n operator --timeout=300s

echo "==> Deploying Kafka and Schema Registry..."
kubectl apply -f platform/kafka.yaml
kubectl wait --for=condition=ready --timeout=600s pod -l app=kafka -n operator
kubectl wait --for=condition=ready --timeout=600s pod -l app=schemaregistry -n operator

echo "==> Creating the cmf-day2-tls secret and deploying CMFRestClass + FlinkEnvironment..."
kubectl create secret generic cmf-day2-tls -n operator \
  --from-file=fullchain.pem=./certs/server.pem \
  --from-file=privkey.pem=./certs/server-key.pem \
  --from-file=cacerts.pem=./certs/cacerts.pem \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f platform/cmfrestclass.yaml
kubectl apply -f platform/flinkenvironment.yaml
wait_for flinkenvironment/flink-env1 '{.status.cfkInternalState}' CREATED

echo "==> Step 1: FlinkSecret..."
kubectl apply -f sql/00-flinksecret.yaml
wait_for flinksecret/flink-connection-secret '{.status.cfkInternalState}' CREATED

echo "==> Step 1b: FlinkEnvironmentSecretMapping (exposes the secret to the environment)..."
kubectl apply -f sql/05-secretmapping.yaml
wait_for flinkenvironmentsecretmapping/flink-connection-secret '{.status.cfkInternalState}' CREATED

echo "==> Step 2: FlinkKafkaCatalog..."
kubectl apply -f sql/10-kafkacatalog.yaml
wait_for flinkkafkacatalog/kafka-catalog '{.status.cfkInternalState}' CREATED

echo "==> Step 3: FlinkKafkaDatabase..."
kubectl apply -f sql/20-kafkadatabase.yaml
wait_for flinkkafkadatabase/clickstream '{.status.cfkInternalState}' CREATED

echo "==> Step 4: FlinkComputePool (DEDICATED and SHARED)..."
kubectl apply -f sql/30-computepool-dedicated.yaml
kubectl apply -f sql/31-computepool-shared.yaml
wait_for flinkcomputepool/dedicated-pool '{.status.cfkInternalState}' CREATED
wait_for flinkcomputepool/shared-pool '{.status.cfkInternalState}' CREATED

echo "==> Step 5: create the source and sink tables..."
kubectl apply -f sql/35-create-tables.yaml
wait_for flinkstatement/create-pageviews '{.status.phase}' COMPLETED
wait_for flinkstatement/create-pageviews-by-user '{.status.phase}' COMPLETED

echo "==> Step 6: FlinkStatement (streaming aggregation)..."
kubectl apply -f sql/40-statement.yaml
wait_for flinkstatement/pageviews-by-user '{.status.phase}' RUNNING

echo ""
echo "Setup complete. The chain is up; the pageviews topic starts empty, so the"
echo "statement is RUNNING but emits nothing until rows arrive (see Readme.md, Step 6)."
echo "To reach the CMF REST API from your machine:"
echo "  echo '127.0.0.1 confluent-manager-for-apache-flink.operator.svc.cluster.local' | sudo tee -a /etc/hosts"
echo "  while true; do kubectl port-forward service/cmf-service 8080:80 -n operator; done"
