#!/usr/bin/env bash
# Tear down replicator-cloud2cloud-acls demo (K8s + Confluent Cloud).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV="${ENV:-env-26m77m}"
SRC="${SRC_CLUSTER:-lkc-0x90x6p}"
DST="${DST_CLUSTER:-lkc-57wk738}"
NS="${NS:-destination}"
BOOTSTRAP="${BOOTSTRAP:-pkc-921jm.us-east-2.aws.confluent.cloud:9092}"
REST="${KAFKA_REST:-https://${BOOTSTRAP%%:*}:443}"

confluent environment use "$ENV" >/dev/null

echo "=== 1) Delete K8s resources for this demo ==="
kubectl delete connector replicator-smt-eu -n "$NS" --ignore-not-found --wait=false
kubectl delete connect replicator-smt-eu -n "$NS" --ignore-not-found --wait=false
kubectl delete sts merchant-producer -n "$NS" --ignore-not-found --wait=false
kubectl delete svc merchant-producer -n "$NS" --ignore-not-found
for kt in $(kubectl get kafkatopic -n "$NS" -o name 2>/dev/null || true); do
  name=$(kubectl get "$kt" -n "$NS" -o jsonpath='{.spec.name}' 2>/dev/null || true)
  case "$name" in
    demo.orders.avro.v1|\
    ccloud-eu.demo.orders.avro.v1)
      kubectl delete "$kt" -n "$NS" --ignore-not-found --wait=false || true
      ;;
  esac
done
sleep 2
for r in $(kubectl get connect,connector,kafkatopic -n "$NS" -o name 2>/dev/null | grep -E 'smt-eu|demo-orders' || true); do
  kubectl patch "$r" -n "$NS" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
done
kubectl delete pods -n "$NS" -l app=replicator-smt-eu --force --grace-period=0 --ignore-not-found 2>/dev/null || true
kubectl delete pods -n "$NS" -l app=merchant-producer --force --grace-period=0 --ignore-not-found 2>/dev/null || true
kubectl delete secret replicator-smt-eu-worker-plain eu-smt-source-rest eu-smt-dest-rest \
  merchant-producer-config -n "$NS" --ignore-not-found || true

echo "=== 2) Delete cloud topics via Kafka REST ==="
SRC_ADMIN_KEY=$(sed -n 's/^username=//p' "$DIR/source-creds-client-kafka-sasl-user.txt")
SRC_ADMIN_SECRET=$(sed -n 's/^password=//p' "$DIR/source-creds-client-kafka-sasl-user.txt")
DST_ADMIN_KEY=$(sed -n 's/^username=//p' "$DIR/destination-creds-client-kafka-sasl-user.txt")
DST_ADMIN_SECRET=$(sed -n 's/^password=//p' "$DIR/destination-creds-client-kafka-sasl-user.txt")

delete_topic_rest() {
  local cluster="$1" key="$2" secret="$3" topic="$4"
  local enc code
  enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$topic")
  code=$(curl -sS -o /tmp/tdel.out -w '%{http_code}' -u "${key}:${secret}" -X DELETE \
    "${REST}/kafka/v3/clusters/${cluster}/topics/${enc}" || echo err)
  echo "  delete [$cluster] $topic -> HTTP $code"
}

for t in \
  "demo.orders.avro.v1" \
  "ccloud-eu.demo.orders.avro.v1" \
  "destination.replicator-smt-eu-configs" \
  "destination.replicator-smt-eu-offsets" \
  "destination.replicator-smt-eu-status"
do
  delete_topic_rest "$DST" "$DST_ADMIN_KEY" "$DST_ADMIN_SECRET" "$t"
done
delete_topic_rest "$SRC" "$SRC_ADMIN_KEY" "$SRC_ADMIN_SECRET" \
  "demo.orders.avro.v1"

echo "=== 3) Delete demo service accounts ==="
delete_sa() {
  local said="$1"
  [[ -z "$said" ]] && return 0
  confluent api-key list --service-account "$said" -o json 2>/dev/null | python3 -c "
import sys,json,subprocess
try: keys=json.load(sys.stdin)
except Exception: keys=[]
for k in keys:
  kid=k.get('key') or k.get('api_key')
  if kid: subprocess.run(['confluent','api-key','delete',kid,'--force'], check=False)
" || true
  confluent iam service-account delete "$said" --force 2>&1 || true
}

if [[ -f "$DIR/sa-ids.env" ]]; then
  # shellcheck disable=SC1091
  source "$DIR/sa-ids.env"
  delete_sa "${SA_SRC:-}"
  delete_sa "${SA_DST:-}"
  delete_sa "${SA_WORKER:-}"
else
  confluent iam service-account list -o json | python3 -c '
import json,sys
names={"sa-rep-smt-src","sa-rep-smt-dst","sa-rep-smt-worker"}
for s in json.load(sys.stdin):
  if s.get("name") in names:
    print(s["id"])
' | while read -r said; do
    delete_sa "$said"
  done
fi

echo "=== 4) Clear local generated files ==="
rm -f "$DIR"/src-apikey.json "$DIR"/dst-apikey.json "$DIR"/worker-apikey.json \
  "$DIR"/sa-ids.env "$DIR"/connector-smt-eu.yaml "$DIR"/producer-kafka.properties

echo "Cleanup done."
