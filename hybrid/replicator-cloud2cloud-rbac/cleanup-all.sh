#!/usr/bin/env bash
# Tear down replicator-cloud2cloud-rbac demo (K8s + Confluent Cloud + SR hard-delete).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
: "${ENV:?Set ENV (e.g. env-xxxxx)}"
: "${SRC_CLUSTER:?Set SRC_CLUSTER (e.g. lkc-xxxxx)}"
: "${DST_CLUSTER:?Set DST_CLUSTER (e.g. lkc-xxxxx)}"
: "${SRC_BOOTSTRAP:?Set SRC_BOOTSTRAP (e.g. pkc-xxxxx.region.aws.confluent.cloud:9092)}"
: "${DST_BOOTSTRAP:?Set DST_BOOTSTRAP (e.g. pkc-yyyyy.region.aws.confluent.cloud:9092)}"
NS="${NS:-destination}"
SRC_KAFKA_REST="${SRC_KAFKA_REST:-https://${SRC_BOOTSTRAP%%:*}:443}"
DST_KAFKA_REST="${DST_KAFKA_REST:-https://${DST_BOOTSTRAP%%:*}:443}"
SRC="$SRC_CLUSTER"
DST="$DST_CLUSTER"

confluent environment use "$ENV" >/dev/null

kubectl delete connector replicator-smt-rbac -n "$NS" --wait=false --ignore-not-found
kubectl delete connect replicator-smt-rbac -n "$NS" --wait=false --ignore-not-found
kubectl delete sts avro-producer -n "$NS" --ignore-not-found --wait=false
kubectl delete svc avro-producer -n "$NS" --ignore-not-found
for kt in $(kubectl get kafkatopic -n "$NS" -o name 2>/dev/null || true); do
  name=$(kubectl get "$kt" -n "$NS" -o jsonpath='{.spec.name}' 2>/dev/null || true)
  case "$name" in
    demo.*|cloud.demo.*)
      kubectl delete "$kt" -n "$NS" --ignore-not-found --wait=false || true
      ;;
  esac
done
sleep 2
for r in $(kubectl get connect,connector,kafkatopic -n "$NS" -o name 2>/dev/null | grep -E 'smt-rbac|demo-|cloud-|presmt|src-' || true); do
  kubectl patch "$r" -n "$NS" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
done
kubectl delete pods -n "$NS" -l app=replicator-smt-rbac --force --grace-period=0 --ignore-not-found 2>/dev/null || true
kubectl delete pods -n "$NS" -l app=avro-producer --force --grace-period=0 --ignore-not-found 2>/dev/null || true
kubectl delete secret smt-rbac-worker-plain eu-rbac-source-rest eu-rbac-dest-rest \
  replicator-smt-rbac-src-kafka replicator-smt-rbac-dest-kafka avro-producer-config \
  -n "$NS" --ignore-not-found

SRC_ADMIN_KEY=$(sed -n 's/^username=//p' "$DIR/source-creds-client-kafka-sasl-user.txt")
SRC_ADMIN_SECRET=$(sed -n 's/^password=//p' "$DIR/source-creds-client-kafka-sasl-user.txt")
DST_ADMIN_KEY=$(sed -n 's/^username=//p' "$DIR/destination-creds-client-kafka-sasl-user.txt")
DST_ADMIN_SECRET=$(sed -n 's/^password=//p' "$DIR/destination-creds-client-kafka-sasl-user.txt")

del() {
  local rest="$1" cluster="$2" key="$3" secret="$4" topic="$5"
  local enc; enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$topic")
  curl -sS -o /dev/null -w "  del [$cluster] $topic -> %{http_code}\n" -u "${key}:${secret}" -X DELETE \
    "${rest}/kafka/v3/clusters/${cluster}/topics/${enc}" || true
}

SRC_TOPICS=(
  "demo.orders.avro.v1"
  "demo.customers.avro.v1"
  "demo.inventory.avro.v1"
)
DST_TOPICS=(
  "${SRC_TOPICS[@]}"
  "cloud.demo.orders.avro.v1"
  "cloud.demo.customers.avro.v1"
  "cloud.demo.inventory.avro.v1"
  "${NS}.replicator-smt-rbac-configs"
  "${NS}.replicator-smt-rbac-offsets"
  "${NS}.replicator-smt-rbac-status"
)
for t in "${DST_TOPICS[@]}"; do del "$DST_KAFKA_REST" "$DST" "$DST_ADMIN_KEY" "$DST_ADMIN_SECRET" "$t"; done
for t in "${SRC_TOPICS[@]}"; do del "$SRC_KAFKA_REST" "$SRC" "$SRC_ADMIN_KEY" "$SRC_ADMIN_SECRET" "$t"; done

# Exact demo subjects only (not a prefix scan of demo. / cloud.demo. in the environment).
SR_SUBJECTS=(
  "demo.orders.avro.v1-key"
  "demo.orders.avro.v1-value"
  "demo.customers.avro.v1-key"
  "demo.customers.avro.v1-value"
  "demo.inventory.avro.v1-key"
  "demo.inventory.avro.v1-value"
  "cloud.demo.orders.avro.v1-key"
  "cloud.demo.orders.avro.v1-value"
  "cloud.demo.customers.avro.v1-key"
  "cloud.demo.customers.avro.v1-value"
  "cloud.demo.inventory.avro.v1-key"
  "cloud.demo.inventory.avro.v1-value"
)

hard_del_subject() {
  local subject="$1"
  soft=$(confluent schema-registry schema delete --subject "$subject" --version all --force \
    --environment "$ENV" 2>&1 || true)
  hard=$(confluent schema-registry schema delete --subject "$subject" --version all --permanent --force \
    --environment "$ENV" 2>&1 || true)
  echo "  del-schema ${subject}"
  echo "    soft: ${soft}"
  echo "    hard: ${hard}"
}

echo "=== Schema Registry hard delete (exact demo subjects) ==="
for subj in "${SR_SUBJECTS[@]}"; do
  hard_del_subject "$subj"
done

if [[ -f "$DIR/sa-ids.env" ]]; then
  # shellcheck disable=SC1091
  source "$DIR/sa-ids.env"
  for said in "$SA_SRC" "$SA_DST" "$SA_WORKER"; do
    confluent api-key list --service-account "$said" -o json 2>/dev/null | python3 -c "
import sys,json,subprocess
try: keys=json.load(sys.stdin)
except Exception: keys=[]
for k in keys:
  kid=k.get('key') or k.get('api_key')
  if kid: subprocess.run(['confluent','api-key','delete',kid,'--force'], check=False)
" || true
    confluent iam service-account delete "$said" --force 2>&1 || true
  done
fi

rm -f "$DIR"/*-apikey.json "$DIR"/sa-ids.env \
  "$DIR"/connector.yaml "$DIR"/components-connect.yaml "$DIR"/topics.yaml \
  "$DIR"/producer.yaml "$DIR"/producer.properties "$DIR"/producer.env

echo "Cleanup done."
