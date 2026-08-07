# Replicator Cloud-to-Cloud (RBAC + RegexRouter SMT + Avro)

Replicate topics from one Confluent Cloud cluster to another using **Confluent Replicator on CFK**, with:

- **RBAC role bindings only** (no Kafka ACLs)
- **RegexRouter SMT** owning destination topic names (`demo.*` → `cloud.demo.*`)
- **Avro** via shared Schema Registry and **ByteArrayConverter** passthrough
- Split service accounts: source / dest connector / Connect worker

Sibling demos:

- [`../replicator-cloud2cloud/`](../replicator-cloud2cloud/) — original cloud-to-cloud tutorial (Control Center)
- [`../replicator-cloud2cloud-acls/`](../replicator-cloud2cloud-acls/) — same SMT pattern with **ACLs**


## What you deploy

| Piece | Name |
|---|---|
| Connect (Replicator) | `replicator-smt-rbac` |
| Connector | `replicator-smt-rbac` |
| Sample Avro producer | `avro-producer` |

| Source | Destination (post-SMT) |
|---|---|
| `demo.orders.avro.v1` | `cloud.demo.orders.avro.v1` |
| `demo.customers.avro.v1` | `cloud.demo.customers.avro.v1` |
| `demo.inventory.avro.v1` | `cloud.demo.inventory.avro.v1` |

Topic selection uses regex (no whitelist):

```text
demo\.(orders|customers|inventory)\.avro\.v1
```

`topic.rename.format` is identity (`${topic}`). RegexRouter rewrites `^(.*)$` → `cloud.$1`. With `topic.auto.create: false`, **pre-create both** pre-SMT (`demo.*`) and post-SMT (`cloud.demo.*`) topics on the destination.

## Set up pre-requisites

Set the tutorial directory:

```bash
export TUTORIAL_HOME=<Tutorial directory>/hybrid/replicator-cloud2cloud-rbac
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

Edit the placeholder files in `$TUTORIAL_HOME`:

```
source-creds-client-kafka-sasl-user.txt
destination-creds-client-kafka-sasl-user.txt
destination-creds-schemaRegistry-user.txt
```

```
username=<cloud-api-key>
password=<cloud-api-secret>
```

You need a logged-in `confluent` CLI user that can create service accounts, API keys, and RBAC role bindings.

### Optional overrides

```bash
export ENV=env-xxxxx
export SRC_CLUSTER=lkc-xxxxx
export DST_CLUSTER=lkc-xxxxx
export SR_CLUSTER=lsrc-xxxxx
export BOOTSTRAP=pkc-xxxxx.region.aws.confluent.cloud:9092
export SR_URL=https://psrc-xxxxx.region.aws.confluent.cloud
export KAFKA_REST=https://pkc-xxxxx.region.aws.confluent.cloud:443
```

`setup-fresh.sh` renders templates with these values (`components-connect.yaml.template`, `topics.yaml.template`, `connector.yaml.template`).

## Deploy the demo

```bash
cd $TUTORIAL_HOME
./setup-fresh.sh
```

This will:

1. Create three service accounts and API keys (Kafka + Schema Registry)
2. Apply RBAC bindings (`rbac.sh`)
3. Create Kubernetes secrets
4. Render manifests and deploy topics, Connect, connector, and Avro producer

## Service accounts and RBAC

| SA | Used for | Roles (summary) |
|---|---|---|
| `sa-rep-smt-rbac-src` | `src.kafka.*`, source KafkaTopic REST, Avro producer | Source: `ResourceOwner` on `Topic:demo` (prefix) and `Topic:__consumer_timestamps`; `DeveloperRead` on `Group:replicator-smt-rbac`; SR `ResourceOwner` on `Subject:demo` (prefix) |
| `sa-rep-smt-rbac-dst` | `dest.kafka.*` / `confluent.topic.*`, dest KafkaTopic REST | Dest: `CloudClusterAdmin`; SR `ResourceOwner` on `Subject:demo` / `Subject:cloud` (prefix) |
| `sa-rep-smt-rbac-worker` | Connect worker Kafka auth | Dest: `CloudClusterAdmin`; SR `ResourceOwner` on `Subject:demo` / `Subject:cloud` (prefix) |

Connect produces post-SMT records with the **worker** credentials, not `dest.kafka.*`.

## Connector notes

- `offset.topic.commit=false` and `offset.timestamps.commit=false` avoid provenance topic create issues under tighter auth
- Use **`ByteArrayConverter`** for key/value/header  
  Do **not** use `AvroConverter` with Replicator + SMT: Replicator emits opaque bytes, and AvroConverter registers `["null","bytes"]` under post-SMT subjects

### Shared Schema Registry

Passthrough keeps the **source schema ID** in the payload. Consumers resolve Avro by ID from the shared SR.

- Pre-SMT dest topics may appear schema-linked in the UI because `{topic}-value` matches the shared subject name (association by name; data is written to `cloud.demo.*`)
- Post-SMT subjects often are **not** registered with ByteArrayConverter — expected
- **Separate SRs:** ByteArrayConverter alone fails until schemas are linked/migrated

## Verify

```bash
kubectl get connect,connector -n destination | grep smt-rbac

kubectl exec -n destination replicator-smt-rbac-0 -c replicator-smt-rbac -- \
  curl -sS http://localhost:8083/connectors/replicator-smt-rbac/status

kubectl exec -n destination replicator-smt-rbac-0 -c replicator-smt-rbac -- \
  curl -sS http://localhost:8083/connectors/replicator-smt-rbac/topics

kubectl logs -n destination avro-producer-0 --tail=20
```

## Tear down

```bash
cd $TUTORIAL_HOME
./cleanup-all.sh
```

Removes this demo’s K8s resources, Kafka topics, **hard-deletes** matching Schema Registry subjects, service accounts/API keys, and generated local files.

## Layout

| File | Role |
|---|---|
| `setup-fresh.sh` | End-to-end deploy |
| `cleanup-all.sh` | Tear down + SR hard-delete |
| `rbac.sh` | Role bindings |
| `components-connect.yaml.template` | Connect worker |
| `topics.yaml.template` | Source + pre-SMT + post-SMT topics |
| `connector.yaml.template` | Replicator connector |
| `producer.yaml` | Avro sample producer |
