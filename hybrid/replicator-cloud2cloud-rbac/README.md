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

Create the namespace (default `destination`; override with `NS=...`):

```bash
export NS=destination   # optional; this is the default
kubectl create ns "$NS"
```

### Deploy Confluent for Kubernetes

```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --namespace "$NS"
kubectl --namespace "$NS" get pods
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

### Required cluster identifiers

Set these before `setup-fresh.sh` or `cleanup-all.sh`. There are no lab defaults; the scripts fail if they are unset.

```bash
export ENV=env-xxxxx
export NS=destination
export SRC_CLUSTER=lkc-xxxxx
export DST_CLUSTER=lkc-xxxxx
export SR_CLUSTER=lsrc-xxxxx
export SRC_BOOTSTRAP=pkc-xxxxx.region.aws.confluent.cloud:9092
export DST_BOOTSTRAP=pkc-yyyyy.region.aws.confluent.cloud:9092
export SR_URL=https://psrc-xxxxx.region.aws.confluent.cloud
# optional; derived from the bootstrap host if unset
export SRC_KAFKA_REST=https://pkc-xxxxx.region.aws.confluent.cloud:443
export DST_KAFKA_REST=https://pkc-yyyyy.region.aws.confluent.cloud:443
```

`setup-fresh.sh` renders templates with these values (`components-connect.yaml.template`, `topics.yaml.template`, `connector.yaml.template`, `producer.yaml.template`).

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

- Connector `src.kafka` / `dest.kafka` / `confluent.topic` JAAS is **not** written into the Connector CR. Setup creates Kubernetes secrets (`replicator-smt-rbac-src-kafka`, `replicator-smt-rbac-dest-kafka`), the Connect CR mounts them (`mountedSecrets`), and the connector config uses CFK’s `${file:/mnt/secrets/...}` FileConfigProvider references. See [CFK mounted secrets](https://docs.confluent.io/operator/current/co-manage-connectors.html#mounted-secrets-for-credentials).
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
kubectl get connect,connector -n "$NS" | grep smt-rbac

kubectl exec -n "$NS" replicator-smt-rbac-0 -c replicator-smt-rbac -- \
  curl -sS http://localhost:8083/connectors/replicator-smt-rbac/status

kubectl exec -n "$NS" replicator-smt-rbac-0 -c replicator-smt-rbac -- \
  curl -sS http://localhost:8083/connectors/replicator-smt-rbac/topics

kubectl logs -n "$NS" avro-producer-0 --tail=20
```

## Tear down

```bash
cd $TUTORIAL_HOME
./cleanup-all.sh
```

Removes this demo’s K8s resources, Kafka topics, service accounts/API keys, and generated local files.

**Destructive:** it also **hard-deletes** a fixed list of Schema Registry subjects used by this demo (`demo.{orders,customers,inventory}.avro.v1-{key,value}` and `cloud.demo.*` equivalents). It does **not** scan the environment by prefix. Confirm `ENV` points at the intended Confluent Cloud environment before running this in a shared account.

## Layout

| File | Role |
|---|---|
| `setup-fresh.sh` | End-to-end deploy |
| `cleanup-all.sh` | Tear down + SR hard-delete |
| `rbac.sh` | Role bindings |
| `components-connect.yaml.template` | Connect worker |
| `topics.yaml.template` | Source + pre-SMT + post-SMT topics |
| `connector.yaml.template` | Replicator connector (JAAS via mounted secrets) |
| `producer.yaml.template` | Avro sample producer |
