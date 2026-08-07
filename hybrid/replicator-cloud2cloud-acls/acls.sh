#!/usr/bin/env bash
# Minimal ACLs for fresh Replicator SMT EU stack (split source / dest / worker SAs)
# env-26m77m / moshe-repl
set -euo pipefail

# Override via env if needed (defaults match the moshe-repl demo)
ENV="${ENV:-env-26m77m}"
SRC="${SRC_CLUSTER:-lkc-0x90x6p}"
DST="${DST_CLUSTER:-lkc-57wk738}"

# Filled by setup-fresh.sh (or export before running)
: "${SA_WORKER:?set SA_WORKER}"
: "${SA_SRC:?set SA_SRC}"
: "${SA_DST:?set SA_DST}"

CONNECT_NAME="${CONNECT_NAME:-replicator-smt-eu}"
CONNECTOR_GROUP="${CONNECTOR_GROUP:-replicator-smt-eu}"
SRC_TOPIC="${SRC_TOPIC:-demo.orders.avro.v1}"
DST_TOPIC="${DST_TOPIC:-ccloud-eu.demo.orders.avro.v1}"
# CFK Connect storage topics / group are prefixed with the K8s namespace
NS="${NS:-destination}"

confluent environment use "$ENV" >/dev/null

echo "=== DEST: Connect worker ACLs ($SA_WORKER) ==="
confluent kafka cluster use "$DST" >/dev/null
confluent kafka acl create --allow --service-account "$SA_WORKER" --operations DESCRIBE --cluster-scope
confluent kafka acl create --allow --service-account "$SA_WORKER" --operations IDEMPOTENT_WRITE --cluster-scope
confluent kafka acl create --allow --service-account "$SA_WORKER" --operations CREATE,DESCRIBE,READ,WRITE --topic "${NS}.${CONNECT_NAME}-" --prefix
confluent kafka acl create --allow --service-account "$SA_WORKER" --operations DESCRIBE,READ --consumer-group "${NS}.${CONNECT_NAME}"
# Connect worker producer writes the post-SMT dest topic (uses worker creds, not dest.kafka.*)
confluent kafka acl create --allow --service-account "$SA_WORKER" --operations DESCRIBE,DESCRIBE_CONFIGS,WRITE --topic "$DST_TOPIC"
# pre-SMT name on dest (admin / metadata with identity rename.format)
confluent kafka acl create --allow --service-account "$SA_WORKER" --operations DESCRIBE,DESCRIBE_CONFIGS --topic "$SRC_TOPIC"
confluent kafka acl create --allow --service-account "$SA_WORKER" --operations CREATE,DESCRIBE,DESCRIBE_CONFIGS,WRITE --topic __consumer_timestamps

echo "=== DEST: Connector dest.kafka ACLs ($SA_DST) ==="
confluent kafka acl create --allow --service-account "$SA_DST" --operations DESCRIBE --cluster-scope
confluent kafka acl create --allow --service-account "$SA_DST" --operations IDEMPOTENT_WRITE --cluster-scope
# post-SMT topic (pre-created; CREATE for CFK KafkaTopic apply via dest REST)
confluent kafka acl create --allow --service-account "$SA_DST" --operations CREATE,DESCRIBE,DESCRIBE_CONFIGS,WRITE --topic "$DST_TOPIC"
# pre-SMT name on dest: Replicator admin uses topic.rename.format=${topic}; CREATE for CFK
confluent kafka acl create --allow --service-account "$SA_DST" --operations CREATE,DESCRIBE,DESCRIBE_CONFIGS --topic "$SRC_TOPIC"
confluent kafka acl create --allow --service-account "$SA_DST" --operations CREATE,DESCRIBE,READ,WRITE --topic _confluent-command

echo "=== SOURCE: Connector src.kafka ACLs ($SA_SRC) ==="
confluent kafka cluster use "$SRC" >/dev/null
confluent kafka acl create --allow --service-account "$SA_SRC" --operations DESCRIBE --cluster-scope
# CREATE so CFK KafkaTopic / producer setup can manage the source topic; READ for Replicator
confluent kafka acl create --allow --service-account "$SA_SRC" --operations CREATE,DESCRIBE,DESCRIBE_CONFIGS,READ,WRITE --topic "$SRC_TOPIC"
confluent kafka acl create --allow --service-account "$SA_SRC" --operations DESCRIBE,READ --topic __consumer_timestamps
confluent kafka acl create --allow --service-account "$SA_SRC" --operations READ,DESCRIBE --consumer-group "$CONNECTOR_GROUP"

echo "Done."
