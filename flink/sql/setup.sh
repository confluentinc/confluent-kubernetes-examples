#!/bin/bash
#
# Sets up the CP Flink SQL tutorial end to end: FKO + CMF (mTLS) + CFK, a minimal
# Kafka + Schema Registry, then the full Day-2 chain
# (FlinkSecret -> FlinkKafkaCatalog -> FlinkKafkaDatabase -> FlinkComputePool ->
# CREATE TABLE -> FlinkStatement). Run from this directory: ./setup.sh
#
# Mirrors README.md step for step. Two prerequisites the script does NOT paper over:
#   1. Preview: Flink SQL is a preview feature — this script opts in via `enableFlinkSQL=true`
#      on the public CFK 3.3.0 chart (0.1718.10) and pins CMF 2.3.0 (see the README's Preview note).
#   2. Cert generation needs `openssl`, `cfssl`/`cfssljson`, and `keytool` on PATH. The
#      script mints a throwaway CA + CMF server cert and builds the JKS pair at runtime
#      (mirroring flink/oauth/clientCredentials); nothing under certs/ is committed.
#
# Optional env vars:
#   CMF_LICENSE_FILE    path to a CMF license.txt. If unset, CMF runs on its embedded trial license.

set -euo pipefail

export TUTORIAL_HOME
TUTORIAL_HOME="$(cd "$(dirname "$0")" && pwd)"
cd "$TUTORIAL_HOME"

CMF_LICENSE_FILE="${CMF_LICENSE_FILE:-}"
CFK_EXAMPLES_REPO_HOME="https://raw.githubusercontent.com/confluentinc/confluent-kubernetes-examples/master"

# wait_for <kind/name> <jsonpath> <expected> [timeout]
wait_for() {
  kubectl wait --for=jsonpath="$2"="$3" "$1" -n operator --timeout="${4:-180s}"
}

echo "==> Installing the Flink Kubernetes Operator (FKO) and cert-manager..."
helm repo add --force-update confluentinc https://packages.confluent.io/helm
helm repo update
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.8.2/cert-manager.yaml
kubectl wait --for=condition=available --timeout=300s deployment --all -n cert-manager
helm upgrade --install cp-flink-kubernetes-operator confluentinc/flink-kubernetes-operator

echo "==> Generating the mTLS material (throwaway CA + CMF server cert + JKS pair)..."
mkdir -p certs/ca certs/generated
openssl genrsa -out certs/ca/ca-key.pem 2048
openssl req -new -x509 -days 1000 -key certs/ca/ca-key.pem -out certs/ca/ca.pem \
  -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA"
cfssl gencert -ca=certs/ca/ca.pem -ca-key=certs/ca/ca-key.pem \
  -config=certs/server_configs/ca-config.json \
  -profile=server certs/server_configs/cmf-server-config.json | \
  cfssljson -bare certs/generated/cmf-server
curl -sSL "$CFK_EXAMPLES_REPO_HOME/scripts/create-truststore.sh" | bash -s -- certs/ca/ca.pem allpassword
curl -sSL "$CFK_EXAMPLES_REPO_HOME/scripts/create-keystore.sh" | \
  bash -s -- certs/generated/cmf-server.pem certs/generated/cmf-server-key.pem allpassword
rm -rf certs/jks && mv jks certs/jks

echo "==> Creating the operator namespace and CMF keystore/truststore configMaps..."
kubectl create namespace operator --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap cmf-keystore -n operator --from-file ./certs/jks/keystore.jks \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap cmf-truststore -n operator --from-file ./certs/jks/truststore.jks \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Deploying CMF with mTLS..."
cmf_values="$(mktemp)"
trap 'rm -f "$cmf_values"' EXIT
cat > "$cmf_values" <<'EOF'
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
  helm upgrade --install -f "$cmf_values" cmf \
    confluentinc/confluent-manager-for-apache-flink --version 2.3.0 \
    --set license.secretRef=cmf-license --namespace operator
else
  echo "    (no CMF_LICENSE_FILE set; deploying CMF on its embedded trial license)"
  helm upgrade --install -f "$cmf_values" cmf \
    confluentinc/confluent-manager-for-apache-flink --version 2.3.0 --namespace operator
fi
kubectl wait --for=condition=available --timeout=300s \
  deployment/confluent-manager-for-apache-flink -n operator

echo "==> Deploying CFK with the CMF Day-2 and Flink SQL feature flags..."
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --version 0.1718.10 \
  --namespace operator \
  --set enableCMFDay2Ops=true \
  --set enableFlinkSQL=true
kubectl rollout status deployment/confluent-operator -n operator --timeout=300s

echo "==> Deploying Kafka and Schema Registry..."
kubectl apply -f platform/kafka.yaml
# Pods come up sequentially (kraftcontroller -> kafka -> schemaregistry); sleep before each
# wait so the pod exists first, otherwise `kubectl wait` errors "no matching resources found".
sleep 30
kubectl wait --for=condition=ready --timeout=600s pod -l app=kraftcontroller -n operator
sleep 30
kubectl wait --for=condition=ready --timeout=600s pod -l app=kafka -n operator
sleep 30
kubectl wait --for=condition=ready --timeout=600s pod -l app=schemaregistry -n operator

echo "==> Creating the cmf-day2-tls secret and deploying CMFRestClass + FlinkEnvironment..."
kubectl create secret generic cmf-day2-tls -n operator \
  --from-file=fullchain.pem=./certs/generated/cmf-server.pem \
  --from-file=privkey.pem=./certs/generated/cmf-server-key.pem \
  --from-file=cacerts.pem=./certs/ca/ca.pem \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f platform/cmfrestclass.yaml
kubectl apply -f platform/flinkenvironment.yaml
wait_for flinkenvironment/flink-env1 '{.status.cfkInternalState}' CREATED

echo "==> Step 1: FlinkSecret..."
kubectl apply -f sql/flinksecret.yaml
wait_for flinksecret/flink-connection-secret '{.status.cfkInternalState}' CREATED

echo "==> Step 1b: FlinkEnvironmentSecretMapping (exposes the secret to the environment)..."
kubectl apply -f sql/secretmapping.yaml
wait_for flinkenvironmentsecretmapping/flink-connection-secret '{.status.cfkInternalState}' CREATED

echo "==> Step 2: FlinkKafkaCatalog..."
kubectl apply -f sql/kafkacatalog.yaml
wait_for flinkkafkacatalog/kafka-catalog '{.status.cfkInternalState}' CREATED

echo "==> Step 3: FlinkKafkaDatabase..."
kubectl apply -f sql/kafkadatabase.yaml
wait_for flinkkafkadatabase/clickstream '{.status.cfkInternalState}' CREATED

echo "==> Step 4: FlinkComputePool (DEDICATED and SHARED)..."
kubectl apply -f sql/computepool-dedicated.yaml
kubectl apply -f sql/computepool-shared.yaml
wait_for flinkcomputepool/dedicated-pool '{.status.cfkInternalState}' CREATED
wait_for flinkcomputepool/shared-pool '{.status.cfkInternalState}' CREATED

echo "==> Step 5: create the source and sink tables..."
kubectl apply -f sql/create-tables.yaml
wait_for flinkstatement/create-pageviews '{.status.phase}' COMPLETED
wait_for flinkstatement/create-pageviews-by-user '{.status.phase}' COMPLETED

echo "==> Step 6: FlinkStatement (streaming aggregation)..."
kubectl apply -f sql/statement.yaml
wait_for flinkstatement/pageviews-by-user '{.status.cfkInternalState}' CREATED
# CMF runs the statement as a Flink job (a FlinkDeployment) in the environment's
# namespace (default); wait for that job to come up and report RUNNING. The first
# pull of the cp-flink-sql runtime image can take several minutes, so allow ~10m.
echo "    waiting for the pageviews-by-user Flink job to reach RUNNING..."
job_state=""
for _ in $(seq 1 120); do
  job_state="$(kubectl get flinkdeployment pageviews-by-user -n default \
    -o jsonpath='{.status.jobStatus.state}' 2>/dev/null || true)"
  [ "$job_state" = "RUNNING" ] && break
  sleep 5
done
if [ "$job_state" != "RUNNING" ]; then
  echo "pageviews-by-user did not reach RUNNING (last state: ${job_state:-<none>})" >&2
  exit 1
fi

echo ""
echo "Setup complete. The chain is up; the pageviews topic starts empty, so the"
echo "statement is RUNNING but emits nothing until rows arrive (see README.md, Step 6)."
echo "To reach the CMF REST API from your machine:"
echo "  echo '127.0.0.1 confluent-manager-for-apache-flink.operator.svc.cluster.local' | sudo tee -a /etc/hosts"
echo "  while true; do kubectl port-forward service/cmf-service 8080:80 -n operator; done"
