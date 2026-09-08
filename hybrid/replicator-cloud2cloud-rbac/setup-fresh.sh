#!/usr/bin/env bash
# Create SAs, RBAC bindings (no ACLs), secrets, topics, Connect + Avro SMT connector + producer.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
: "${ENV:?Set ENV (e.g. env-xxxxx)}"
: "${SRC_CLUSTER:?Set SRC_CLUSTER (e.g. lkc-xxxxx)}"
: "${DST_CLUSTER:?Set DST_CLUSTER (e.g. lkc-xxxxx)}"
: "${SR_CLUSTER:?Set SR_CLUSTER (e.g. lsrc-xxxxx)}"
: "${SRC_BOOTSTRAP:?Set SRC_BOOTSTRAP (e.g. pkc-xxxxx.region.aws.confluent.cloud:9092)}"
: "${DST_BOOTSTRAP:?Set DST_BOOTSTRAP (e.g. pkc-yyyyy.region.aws.confluent.cloud:9092)}"
: "${SR_URL:?Set SR_URL (e.g. https://psrc-xxxxx.region.aws.confluent.cloud)}"
NS="${NS:-destination}"
SRC_KAFKA_REST="${SRC_KAFKA_REST:-https://${SRC_BOOTSTRAP%%:*}:443}"
DST_KAFKA_REST="${DST_KAFKA_REST:-https://${DST_BOOTSTRAP%%:*}:443}"
SRC="$SRC_CLUSTER"
DST="$DST_CLUSTER"
SR="$SR_CLUSTER"

export ENV SRC_CLUSTER DST_CLUSTER SR_CLUSTER SRC_BOOTSTRAP DST_BOOTSTRAP SRC_KAFKA_REST DST_KAFKA_REST SR_URL NS
echo "Endpoints: SRC_BOOTSTRAP=$SRC_BOOTSTRAP DST_BOOTSTRAP=$DST_BOOTSTRAP SR_URL=$SR_URL"
echo "REST: SRC_KAFKA_REST=$SRC_KAFKA_REST DST_KAFKA_REST=$DST_KAFKA_REST"
echo "Clusters: SRC=$SRC DST=$DST SR=$SR NS=$NS"

confluent environment use "$ENV" >/dev/null

create_sa() {
  local name="$1" desc="$2"
  existing=$(confluent iam service-account list -o json | python3 -c "
import sys,json
name='$name'
for s in json.load(sys.stdin):
  if s.get('name')==name:
    print(s['id']); break
" || true)
  if [[ -n "${existing:-}" ]]; then echo "$existing"
  else
    confluent iam service-account create "$name" --description "$desc" -o json \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])'
  fi
}

read_key() { python3 -c "import json; d=json.load(open('$1')); print(d.get('api_key') or d.get('key'))"; }
read_secret() { python3 -c "import json; d=json.load(open('$1')); print(d.get('api_secret') or d.get('secret'))"; }

create_key() {
  local sa="$1" resource="$2" outfile="$3"
  if [[ -f "$outfile" ]] && [[ -s "$outfile" ]]; then
    local k; k=$(read_key "$outfile" || true)
    if [[ -n "${k:-}" ]]; then echo "reuse $outfile $k"; return; fi
  fi
  confluent api-key create --service-account "$sa" --resource "$resource" -o json | tee "$outfile" >/dev/null
  echo "created $outfile"
}

echo "=== 1) Service accounts ==="
export SA_SRC SA_DST SA_WORKER
SA_SRC=$(create_sa sa-rep-smt-rbac-src "Replicator SMT RBAC — SOURCE")
SA_DST=$(create_sa sa-rep-smt-rbac-dst "Replicator SMT RBAC — DEST connector")
SA_WORKER=$(create_sa sa-rep-smt-rbac-worker "Replicator SMT RBAC — Connect worker")
printf 'SA_SRC=%s\nSA_DST=%s\nSA_WORKER=%s\n' "$SA_SRC" "$SA_DST" "$SA_WORKER" | tee "$DIR/sa-ids.env"
echo "SA_SRC=$SA_SRC SA_DST=$SA_DST SA_WORKER=$SA_WORKER"

echo "=== 2) API keys (Kafka + Schema Registry) ==="
create_key "$SA_SRC" "$SRC" "$DIR/src-apikey.json"
create_key "$SA_DST" "$DST" "$DIR/dst-apikey.json"
create_key "$SA_WORKER" "$DST" "$DIR/worker-apikey.json"
create_key "$SA_SRC" "$SR" "$DIR/src-sr-apikey.json"
create_key "$SA_DST" "$SR" "$DIR/dst-sr-apikey.json"

SRC_KEY=$(read_key "$DIR/src-apikey.json"); SRC_SECRET=$(read_secret "$DIR/src-apikey.json")
DST_KEY=$(read_key "$DIR/dst-apikey.json"); DST_SECRET=$(read_secret "$DIR/dst-apikey.json")
WRK_KEY=$(read_key "$DIR/worker-apikey.json"); WRK_SECRET=$(read_secret "$DIR/worker-apikey.json")
SR_KEY=$(read_key "$DIR/dst-sr-apikey.json"); SR_SECRET=$(read_secret "$DIR/dst-sr-apikey.json")
SRC_SR_KEY=$(read_key "$DIR/src-sr-apikey.json"); SRC_SR_SECRET=$(read_secret "$DIR/src-sr-apikey.json")

echo "=== 3) RBAC bindings (no ACLs) ==="
SA_WORKER="$SA_WORKER" SA_SRC="$SA_SRC" SA_DST="$SA_DST" bash "$DIR/rbac.sh"

echo "=== 4) K8s secrets ==="
kubectl create secret generic smt-rbac-worker-plain \
  --from-file=plain.txt=<(printf 'username=%s\npassword=%s\n' "$WRK_KEY" "$WRK_SECRET") \
  -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic eu-rbac-source-rest \
  --from-file=basic.txt=<(printf 'username=%s\npassword=%s\n' "$SRC_KEY" "$SRC_SECRET") \
  -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic eu-rbac-dest-rest \
  --from-file=basic.txt=<(printf 'username=%s\npassword=%s\n' "$DST_KEY" "$DST_SECRET") \
  -n "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Connector JAAS — mounted into Connect and referenced via ${file:...} (not inlined in the CR).
kubectl create secret generic replicator-smt-rbac-src-kafka \
  --from-file=plain.txt=<(printf 'username=%s\npassword=%s\n' "$SRC_KEY" "$SRC_SECRET") \
  -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic replicator-smt-rbac-dest-kafka \
  --from-file=plain.txt=<(printf 'username=%s\npassword=%s\n' "$DST_KEY" "$DST_SECRET") \
  -n "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Ensure destination SR secret exists for Connect
if ! kubectl get secret destination-cloud-sr-access -n "$NS" >/dev/null 2>&1; then
  kubectl create secret generic destination-cloud-sr-access \
    --from-file=basic.txt="$DIR/destination-creds-schemaRegistry-user.txt" \
    -n "$NS"
fi

cat > "$DIR/producer.properties" <<EOF
bootstrap.servers=${SRC_BOOTSTRAP}
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${SRC_KEY}" password="${SRC_SECRET}";
EOF
cat > "$DIR/producer.env" <<EOF
BOOTSTRAP=${SRC_BOOTSTRAP}
SR_URL=${SR_URL}
SR_KEY=${SRC_SR_KEY}
SR_SECRET=${SRC_SR_SECRET}
EOF
kubectl create secret generic avro-producer-config \
  --from-file=producer.properties="$DIR/producer.properties" \
  --from-file=producer.env="$DIR/producer.env" \
  -n "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "=== 5) Render manifests (URLs) ==="
# Only substitute listed vars so Replicator's ${topic} and ${file:...} stay literal.
envsubst '${NS} ${SRC_BOOTSTRAP} ${DST_BOOTSTRAP}' \
  < "$DIR/connector.yaml.template" > "$DIR/connector.yaml"
envsubst '${NS} ${DST_BOOTSTRAP} ${SR_URL}' \
  < "$DIR/components-connect.yaml.template" > "$DIR/components-connect.yaml"
envsubst '${NS} ${SRC_KAFKA_REST} ${DST_KAFKA_REST} ${SRC_CLUSTER} ${DST_CLUSTER}' \
  < "$DIR/topics.yaml.template" > "$DIR/topics.yaml"
envsubst '${NS}' < "$DIR/producer.yaml.template" > "$DIR/producer.yaml"
grep -E 'namespace:|rename.format|converter|topic.regex|bootstrapEndpoint|schemaRegistry:|endpoint:|kafkaClusterID:' \
  "$DIR/connector.yaml" "$DIR/components-connect.yaml" "$DIR/topics.yaml" "$DIR/producer.yaml" | head -30

echo "=== 6) Deploy topics, Connect, connector, producer ==="
kubectl apply -f "$DIR/topics.yaml"
kubectl apply -f "$DIR/components-connect.yaml"
kubectl wait --for=jsonpath='{.status.phase}'=RUNNING connect/replicator-smt-rbac -n "$NS" --timeout=300s \
  || kubectl get connect replicator-smt-rbac -n "$NS" -o wide
kubectl apply -f "$DIR/connector.yaml"
kubectl apply -f "$DIR/producer.yaml"

echo "=== Status ==="
kubectl get connect,connector,kafkatopic,sts -n "$NS"
echo "SAs: worker=$SA_WORKER src=$SA_SRC dest=$SA_DST"
echo "Done."
