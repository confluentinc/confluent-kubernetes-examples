# Replicator Cloud-to-Cloud (ACLs + RegexRouter SMT)

Replicate a topic from one Confluent Cloud cluster to another using **Confluent Replicator on CFK**, with:

- **Kafka ACLs** (minimal, split service accounts)
- **RegexRouter SMT** owning the destination topic name
- Wire-format passthrough (`ByteArrayConverter`)

Sibling demos:

- [`../replicator-cloud2cloud/`](../replicator-cloud2cloud/) — original cloud-to-cloud tutorial (Control Center)
- [`../replicator-cloud2cloud-rbac/`](../replicator-cloud2cloud-rbac/) — same SMT pattern with **RBAC** and Avro

## What you deploy

| Piece | Name |
|---|---|
| Connect (Replicator) | `replicator-smt-eu` |
| Connector | `replicator-smt-eu` |
| Sample producer | `merchant-producer` |

| Source topic | Destination (post-SMT) |
|---|---|
| `demo.orders.avro.v1` | `ccloud-eu.demo.orders.avro.v1` |

`topic.rename.format` is identity (`${topic}`). RegexRouter prefixes the produce target (`^(.*)$` → `ccloud-eu.$1`). With `topic.auto.create: false`, **pre-create both** the pre-SMT name (`demo.orders.avro.v1`) and the post-SMT name (`ccloud-eu.demo.orders.avro.v1`) on the destination.

## Set up pre-requisites

Set the tutorial directory:

```bash
export TUTORIAL_HOME=<Tutorial directory>/hybrid/replicator-cloud2cloud-acls
```

Create the namespace:

```bash
kubectl create ns destination
```

### Deploy Confluent for Kubernetes

```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --namespace destination
kubectl --namespace destination get pods
```

### Prep Confluent Cloud admin credentials

Edit the placeholder files in `$TUTORIAL_HOME` (used by cleanup / Kafka REST):

```
source-creds-client-kafka-sasl-user.txt
destination-creds-client-kafka-sasl-user.txt
```

```
username=<source-or-dest-cloud-api-key>
password=<source-or-dest-cloud-api-secret>
```

You also need a logged-in `confluent` CLI user that can create service accounts, API keys, and ACLs.

### Optional cluster overrides

Defaults match a lab environment. Override as needed before setup:

```bash
export ENV=env-xxxxx
export SRC_CLUSTER=lkc-xxxxx
export DST_CLUSTER=lkc-xxxxx
export BOOTSTRAP=pkc-xxxxx.region.aws.confluent.cloud:9092
export KAFKA_REST=https://pkc-xxxxx.region.aws.confluent.cloud:443
```

If you change clusters, also update hardcoded bootstrap / cluster IDs in:

- `components-replicator-smt-eu.yaml`
- `topics.yaml`
- `connector-smt-eu.yaml.template`

## Deploy the demo

```bash
cd $TUTORIAL_HOME
./setup-fresh.sh
```

This will:

1. Create three service accounts (source / dest connector / Connect worker)
2. Create API keys
3. Apply minimal ACLs (`acls.sh`)
4. Create Kubernetes secrets
5. Render and apply topics, Connect, connector, and producer

## Service accounts and ACLs

| SA | Cluster | Purpose |
|---|---|---|
| `sa-rep-smt-src` | source | `src.kafka.*`, source KafkaTopic REST, sample producer |
| `sa-rep-smt-dst` | destination | `dest.kafka.*` / `confluent.topic.*`, dest KafkaTopic REST |
| `sa-rep-smt-worker` | destination | Connect storage topics + **produce** of post-SMT records |

Connect produces post-SMT data with the **worker** credentials (not `dest.kafka.*`).

See `acls.sh` for the exact ACL set. Notable destination ACLs:

- Worker: `WRITE` on post-SMT topic; `DESCRIBE` / `DESCRIBE_CONFIGS` on pre-SMT name
- Dest connector: `CREATE` / `DESCRIBE` on pre-SMT and post-SMT names (admin + CFK)

## Verify

```bash
kubectl get connect,connector -n destination | grep smt-eu

kubectl exec -n destination replicator-smt-eu-0 -c replicator-smt-eu -- \
  curl -sS http://localhost:8083/connectors/replicator-smt-eu/status

kubectl exec -n destination replicator-smt-eu-0 -c replicator-smt-eu -- \
  curl -sS http://localhost:8083/connectors/replicator-smt-eu/topics

kubectl logs -n destination merchant-producer-0 --tail=20
```

## Tear down

```bash
cd $TUTORIAL_HOME
./cleanup-all.sh
```

Removes this demo’s Connect/connector/producer, topics, secrets, service accounts/API keys, and generated local files.

## Layout

| File | Role |
|---|---|
| `setup-fresh.sh` | End-to-end deploy |
| `cleanup-all.sh` | Tear down |
| `acls.sh` | Minimal ACLs |
| `components-replicator-smt-eu.yaml` | Connect worker |
| `connector-smt-eu.yaml.template` | Replicator connector (credentials substituted at apply time) |
| `topics.yaml` | Source + pre-SMT dest + post-SMT dest topics |
| `producer.yaml` | Sample producer |
