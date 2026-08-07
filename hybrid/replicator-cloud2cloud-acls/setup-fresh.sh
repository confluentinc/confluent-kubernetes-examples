#!/usr/bin/env bash
# One-shot: create split SAs, ACLs, secrets, tear down old eu stack, deploy fresh Connect+SMT connector.
# Run from a shell where `confluent` is already logged in (Keychain session).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV="${ENV:-env-26m77m}"
SRC="${SRC_CLUSTER:-lkc-0x90x6p}"
DST="${DST_CLUSTER:-lkc-57wk738}"
NS="${NS:-destination}"

confluent environment use "$ENV" >/dev/null

echo "=== 1) Create service accounts (source / dest / worker) ==="
create_sa() {
  local name="$1" desc="$2"
  existing=$(confluent iam service-account list -o json | python3 -c "
import sys,json
name='$name'
for s in json.load(sys.stdin):
  if s.get('name')==name:
    print(s['id']); break
" || true)
  if [[ -n "${existing:-}" ]]; then
    echo "$existing"
  else
    confluent iam service-account create "$name" --description "$desc" -o json | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])'
  fi
}

export SA_SRC
export SA_DST
export SA_WORKER
SA_SRC=$(create_sa sa-rep-smt-src "Replicator SMT EU - SOURCE cluster only")
SA_DST=$(create_sa sa-rep-smt-dst "Replicator SMT EU - DEST connector (dest.kafka)")
SA_WORKER=$(create_sa sa-rep-smt-worker "Replicator SMT EU - Connect worker on DEST")
echo "SA_SRC=$SA_SRC"
echo "SA_DST=$SA_DST"
echo "SA_WORKER=$SA_WORKER"
printf 'SA_SRC=%s\nSA_DST=%s\nSA_WORKER=%s\n' "$SA_SRC" "$SA_DST" "$SA_WORKER" > "$DIR/sa-ids.env"

echo "=== 2) API keys ==="
# CLI JSON uses api_key/api_secret (not key/secret)
read_key() { python3 -c "import json; d=json.load(open('$1')); print(d.get('api_key') or d.get('key'))"; }
read_secret() { python3 -c "import json; d=json.load(open('$1')); print(d.get('api_secret') or d.get('secret'))"; }

create_key() {
  local sa="$1" resource="$2" outfile="$3"
  if [[ -f "$outfile" ]] && [[ -s "$outfile" ]]; then
    local k
    k=$(read_key "$outfile")
    if [[ -n "$k" ]]; then
      echo "reuse $outfile $k"
      return
    fi
  fi
  confluent api-key create --service-account "$sa" --resource "$resource" -o json | tee "$outfile" >/dev/null
  echo "created $outfile"
}

create_key "$SA_SRC" "$SRC" "$DIR/src-apikey.json"
create_key "$SA_DST" "$DST" "$DIR/dst-apikey.json"
create_key "$SA_WORKER" "$DST" "$DIR/worker-apikey.json"

SRC_KEY=$(read_key "$DIR/src-apikey.json")
SRC_SECRET=$(read_secret "$DIR/src-apikey.json")
DST_KEY=$(read_key "$DIR/dst-apikey.json")
DST_SECRET=$(read_secret "$DIR/dst-apikey.json")
WRK_KEY=$(read_key "$DIR/worker-apikey.json")
WRK_SECRET=$(read_secret "$DIR/worker-apikey.json")

echo "=== 3) Minimal ACLs ==="
# ignore already-exists errors
set +e
SA_WORKER="$SA_WORKER" SA_SRC="$SA_SRC" SA_DST="$SA_DST" bash "$DIR/acls.sh"
set -e

echo "=== 4) Ensure clean Connect name slot ==="
kubectl delete connector replicator-smt-eu -n "$NS" --ignore-not-found
kubectl delete connect replicator-smt-eu -n "$NS" --ignore-not-found
for i in $(seq 1 60); do
  kubectl get connect replicator-smt-eu -n "$NS" >/dev/null 2>&1 || break
  sleep 2
done

echo "=== 5) K8s secrets (worker + REST for topics + producer) ==="
# CFK expects username=/password= in plain.txt / basic.txt
kubectl create secret generic replicator-smt-eu-worker-plain \
  --from-file=plain.txt=<(printf 'username=%s\npassword=%s\n' "$WRK_KEY" "$WRK_SECRET") \
  -n "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic eu-smt-source-rest \
  --from-file=basic.txt=<(printf 'username=%s\npassword=%s\n' "$SRC_KEY" "$SRC_SECRET") \
  -n "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic eu-smt-dest-rest \
  --from-file=basic.txt=<(printf 'username=%s\npassword=%s\n' "$DST_KEY" "$DST_SECRET") \
  -n "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat > "$DIR/producer-kafka.properties" <<EOF
bootstrap.servers=pkc-921jm.us-east-2.aws.confluent.cloud:9092
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${SRC_KEY}" password="${SRC_SECRET}";
acks=all
EOF
kubectl create secret generic merchant-producer-config \
  --from-file=producer-kafka.properties="$DIR/producer-kafka.properties" \
  -n "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "=== 6) Render connector YAML ==="
export CONNECTOR_SRC_KEY="$SRC_KEY" CONNECTOR_SRC_SECRET="$SRC_SECRET"
export CONNECTOR_DEST_KEY="$DST_KEY" CONNECTOR_DEST_SECRET="$DST_SECRET"
# Only substitute credential vars — leave Replicator's ${topic} intact
envsubst '${CONNECTOR_SRC_KEY} ${CONNECTOR_SRC_SECRET} ${CONNECTOR_DEST_KEY} ${CONNECTOR_DEST_SECRET}' \
  < "$DIR/connector-smt-eu.yaml.template" > "$DIR/connector-smt-eu.yaml"

echo "=== 7) Ensure topics exist, deploy Connect + connector + producer ==="
kubectl apply -f "$DIR/topics.yaml"
kubectl apply -f "$DIR/components-replicator-smt-eu.yaml"

echo "Waiting for Connect READY..."
kubectl wait --for=jsonpath='{.status.phase}'=RUNNING connect/replicator-smt-eu -n "$NS" --timeout=300s || \
  kubectl get connect replicator-smt-eu -n "$NS" -o wide

kubectl apply -f "$DIR/connector-smt-eu.yaml"
kubectl apply -f "$DIR/producer.yaml"

echo "=== Status ==="
kubectl get connect,connector -n "$NS"
echo
echo "SAs: worker=$SA_WORKER src=$SA_SRC dest=$SA_DST"
echo "Done. Watch: kubectl logs -n $NS -l app=replicator-smt-eu -f"
