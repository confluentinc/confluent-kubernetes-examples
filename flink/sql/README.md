# CP Flink SQL on CFK (Day-2)

This playbook walks through the Confluent Platform Flink **SQL** Day-2 resources managed by
CFK through the Confluent Manager for Apache Flink (CMF). You will build the full chain:

```
FlinkSecret + FlinkEnvironmentSecretMapping → FlinkKafkaCatalog → FlinkKafkaDatabase → FlinkComputePool → FlinkStatement
```

- **FlinkSecret** – syncs a Kubernetes Secret (Kafka / Schema Registry credentials) to CMF.
- **FlinkEnvironmentSecretMapping** – exposes that secret to an environment so catalogs and
  databases can reference it (by the mapping's name).
- **FlinkKafkaCatalog** – binds a Schema Registry instance for its databases.
- **FlinkKafkaDatabase** – a SQL database inside a catalog, mapped to a Kafka cluster.
- **FlinkComputePool** – the compute that runs statements (DEDICATED and SHARED variants).
- **FlinkStatement** – a single Flink SQL statement (a streaming job).

It uses the same minimal **mTLS** CMF setup as [`../mTLS`](../mTLS), plus a small Kafka +
Schema Registry for the catalog to connect to.

> **Preview.** Flink SQL is a preview feature in **CFK 3.3.0** (opt-in via the top-level
> `enableFlinkSQL` chart value, which takes effect only when `enableCMFDay2Ops` is also
> enabled), paired with **CMF 2.3.0** and the runtime image
> **`confluentinc/cp-flink-sql:1.19-cp8`** (set on the compute pool `clusterSpec.image`). This guide
> pins those versions — the CFK chart is `confluentinc/confluent-for-kubernetes` `0.1718.10` (the
> 3.3.0 build). All are on the public Helm repo / DockerHub, so no extra registry access is needed.

## Quick start with scripts

[`setup.sh`](setup.sh) runs the whole walkthrough end to end and [`teardown.sh`](teardown.sh)
reverses it; both encode exactly the commands documented below (including installing the pinned
CFK 3.3.0 and CMF 2.3.0 builds). To go step by step instead, follow the rest of this guide.

## Setup Certs

This playbook **generates** the mTLS material for CMF at runtime — only the cert configs
under `certs/server_configs/` are committed. `setup.sh` does this for you; to do it by hand
(or to see what it creates), run from this directory:

```bash
# 1. A throwaway CA
mkdir -p certs/ca certs/generated
openssl genrsa -out certs/ca/ca-key.pem 2048
openssl req -new -x509 -days 1000 -key certs/ca/ca-key.pem -out certs/ca/ca.pem \
  -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA"

# 2. A CMF server cert (CN/SANs come from certs/server_configs/cmf-server-config.json)
cfssl gencert -ca=certs/ca/ca.pem -ca-key=certs/ca/ca-key.pem \
  -config=certs/server_configs/ca-config.json \
  -profile=server certs/server_configs/cmf-server-config.json | \
  cfssljson -bare certs/generated/cmf-server

# 3. The keystore/truststore CMF mounts (password: allpassword)
REPO=https://raw.githubusercontent.com/confluentinc/confluent-kubernetes-examples/master
curl -sSL "$REPO/scripts/create-truststore.sh" | bash -s -- certs/ca/ca.pem allpassword
curl -sSL "$REPO/scripts/create-keystore.sh" | \
  bash -s -- certs/generated/cmf-server.pem certs/generated/cmf-server-key.pem allpassword
rm -rf certs/jks && mv jks certs/jks
```

This mirrors [`../oauth/clientCredentials`](../oauth/clientCredentials); the generated CA,
server cert, and JKS (under `certs/ca`, `certs/generated`, `certs/jks`) are git-ignored.
Minting fresh material each run means there is no committed private key to leak and no cert
to expire.

## Prerequisites

* `kubectl`, `helm`, and a Kubernetes cluster.
* `openssl`, `cfssl` + `cfssljson`, and `keytool` (JDK) on PATH — used to generate the mTLS certs.
* CFK >= 3.3.0 (with `enableFlinkSQL`) and a CMF version exposing the Flink SQL REST API.

## Install Confluent Platform for Apache Flink Kubernetes operator (FKO)

```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
kubectl create -f https://github.com/jetstack/cert-manager/releases/download/v1.8.2/cert-manager.yaml
helm upgrade --install cp-flink-kubernetes-operator confluentinc/flink-kubernetes-operator
```

## Deploy CMF

1. Create the namespace:
    ```bash
    kubectl create ns operator
    ```
2. Create the keystore/truststore configMaps (from the generated JKS):
    ```bash
    kubectl create configmap cmf-keystore -n operator --from-file ./certs/jks/keystore.jks
    kubectl create configmap cmf-truststore -n operator --from-file ./certs/jks/truststore.jks
    ```
3. `local.yaml` for CMF with mTLS:
    ```yaml
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
    ```
4. Deploy via Helm. Pin CMF to the version aligned with your runtime image (2.3.0 for
   `cp-flink-sql:1.19-cp8`). CMF ships an embedded trial license, so a license secret is **optional**:
    ```bash
    # Trial license (no secret needed):
    helm upgrade --install -f local.yaml cmf confluentinc/confluent-manager-for-apache-flink \
      --version 2.3.0 --namespace operator

    # Or, with your own Confluent Platform license:
    kubectl create secret generic cmf-license --from-file=license.txt -n operator
    helm upgrade --install -f local.yaml cmf confluentinc/confluent-manager-for-apache-flink \
      --version 2.3.0 --set license.secretRef=cmf-license --namespace operator
    ```
5. **Optional — only to reach the CMF REST API from your laptop.** The CFK operator talks to CMF
   in-cluster (via the CMFRestClass endpoint), so the chain below does not need this. To curl CMF
   yourself, add the local name to `/etc/hosts`:
    ```
    127.0.0.1       confluent-manager-for-apache-flink.operator.svc.cluster.local
    ```
   then port-forward in a **separate terminal**:
    ```bash
    kubectl port-forward service/cmf-service 8080:80 -n operator
    ```

## Deploy CFK

Deploy CFK with both Day-2 flags so it reconciles the CMF and Flink SQL CRs:

```bash
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes --version 0.1718.10 \
  --namespace operator \
  --set enableCMFDay2Ops=true \
  --set enableFlinkSQL=true
```

`enableCMFDay2Ops` turns on CMFRestClass / FlinkEnvironment / FlinkApplication; `enableFlinkSQL`
adds the SQL CRs used below (FlinkSecret, FlinkKafkaCatalog, FlinkKafkaDatabase,
FlinkComputePool, FlinkStatement).

## Deploy Kafka and Schema Registry

The catalog connects to a Kafka cluster and a Schema Registry. Deploy a minimal pair:

```bash
kubectl apply -f platform/kafka.yaml
kubectl get pods -n operator -w   # wait for kafka and schemaregistry to be Ready
```

## Deploy CMFRestClass and FlinkEnvironment

1. Create the `cmf-day2-tls` secret and deploy the CMFRestClass:
    ```bash
    kubectl create secret generic cmf-day2-tls -n operator \
      --from-file=fullchain.pem=./certs/generated/cmf-server.pem \
      --from-file=privkey.pem=./certs/generated/cmf-server-key.pem \
      --from-file=cacerts.pem=./certs/ca/ca.pem
    kubectl apply -f platform/cmfrestclass.yaml
    kubectl get cmfrestclass default -n operator -oyaml   # status.endpoint populated
    ```
2. Deploy the FlinkEnvironment and wait for it to sync:
    ```bash
    kubectl apply -f platform/flinkenvironment.yaml
    kubectl get flinkenvironment flink-env1 -n operator -oyaml
    ```
    Expect `cfkInternalState: CREATED` and `cmfSync.status: Created`.

## Step 1 – FlinkSecret

CMF needs credentials to reach Kafka and Schema Registry. A FlinkSecret syncs a Kubernetes
Secret to CMF under the FlinkSecret's name; the catalog/database reference it by that name.

```bash
kubectl apply -f sql/flinksecret.yaml
kubectl get flinksecret flink-connection-secret -n operator -oyaml
```

Expect `cfkInternalState: CREATED` and `cmfSync.status: Created`. (To source the backing
Secret from Vault / Sealed Secrets / ESO instead, see [Using an external secret
manager](#using-an-external-secret-manager).)

## Step 1b – FlinkEnvironmentSecretMapping

The secret must be mapped into the environment before a catalog can use it — otherwise CMF
silently ignores the catalog. The mapping's **name must equal the `connectionSecretId`** the
catalog/database reference (CMF keys an environment's secrets by the mapping name):

```bash
kubectl apply -f sql/secretmapping.yaml
kubectl get flinkenvironmentsecretmapping flink-connection-secret -n operator -oyaml
```

Expect `cfkInternalState: CREATED` and `cmfSync.status: Created`.

## Step 2 – FlinkKafkaCatalog

```bash
kubectl apply -f sql/kafkacatalog.yaml
kubectl get flinkkafkacatalog kafka-catalog -n operator -oyaml
```

The catalog binds a Schema Registry instance (`srInstance`); `connectionSecretId` references the
secret mapping from step 1b. Kafka-backed databases are added via FlinkKafkaDatabase (next step),
not in the catalog spec.

## Step 3 – FlinkKafkaDatabase

```bash
kubectl apply -f sql/kafkadatabase.yaml
kubectl get flinkkafkadatabase clickstream -n operator -oyaml
```

The database belongs to the catalog (`catalogRef`) and is the SQL namespace your statements
read and write; existing Kafka topics surface as tables, and `CREATE TABLE` (step 5) adds new ones.

## Step 4 – FlinkComputePool (DEDICATED and SHARED)

A statement runs on a compute pool. Deploy a DEDICATED pool (reserved resources) and a SHARED
pool (multiplexed, supports `state: RUNNING|SUSPENDED`):

```bash
kubectl apply -f sql/computepool-dedicated.yaml
kubectl apply -f sql/computepool-shared.yaml
kubectl get flinkcomputepool -n operator
```

`spec.type` is immutable. `spec.state` is valid only on SHARED pools (enforced by a CEL rule);
set it to `SUSPENDED` to pause a SHARED pool without deleting it. `clusterSpec` sets the Flink
version, the statement runtime `image` (`confluentinc/cp-flink-sql:1.19-cp8` here — it must be at
least the minimum SQL image version documented for your CMF version), and the JobManager/TaskManager
resources statements run with — these are required (the Flink operator rejects a deployment without
`jobManager.resource.memory`).

## Step 5 – Create the source and sink tables

The statement in step 6 reads a `pageviews` table and writes per-user counts to
`pageviews_by_user`. Create both in the `clickstream` database — DDL runs as a FlinkStatement,
gated by the database's `ddlEnvironments`:

```bash
kubectl apply -f sql/create-tables.yaml
kubectl get flinkstatement create-pageviews create-pageviews-by-user -n operator
```

On a Kafka-backed catalog the connector is `confluent` and the bootstrap servers / Schema
Registry come from the catalog binding, so each table maps to a Kafka topic with its schema in
SR. CREATE TABLE is DDL, so each statement runs once and reaches `status.phase: COMPLETED`.

## Step 6 – FlinkStatement

`sql/statement.yaml` runs a streaming SQL statement on the DEDICATED pool. It aggregates the
`pageviews` source into `pageviews_by_user` (both in the `clickstream` database, created in
step 5). A streaming INSERT requires checkpointing, so the statement sets
`execution.checkpointing.interval` in its `flinkConfiguration`.

```bash
kubectl apply -f sql/statement.yaml
kubectl get flinkstatement pageviews-by-user -n operator \
  -o jsonpath='cfkInternalState={.status.cfkInternalState} cmfSync={.status.cmfSync.status}{"\n"}'
```

Expect `cfkInternalState: CREATED` and `cmfSync.status: Created`. CMF runs the statement as a Flink
job in the environment's namespace (`default`); confirm the job is up by checking its FlinkDeployment:

```bash
kubectl get flinkdeployment pageviews-by-user -n default \
  -o jsonpath='{.status.jobStatus.state}{"\n"}'   # RUNNING
```

The `pageviews` topic starts empty, so the job runs but emits nothing until rows arrive — seed a few
with an `INSERT INTO ... pageviews VALUES (...)` statement, or point the source at an existing
topic. `spec.statement` is immutable once running; set `spec.stopped: true` to stop without
deleting.

Note: Reading a statement's results isn't supported through these CFK resources at the moment; results are accessed via the CMF statements API.

## Step 7 – Seed the source

With the streaming statement RUNNING, seed a few rows into `pageviews`. A bounded
`INSERT ... VALUES` runs once and reaches `status.phase: COMPLETED`:

```bash
kubectl apply -f sql/seed-pageviews.yaml
kubectl get flinkstatement seed-pageviews -n operator \
  -o jsonpath='{.status.phase}{"\n"}'   # COMPLETED
```

The streaming statement then aggregates these rows into `pageviews_by_user`, one row per `user_id`.

## Using an external secret manager

The FlinkSecret consumes a standard Kubernetes Secret, so the backing Secret
(`flink-connection-credentials`) can be produced by any tool that emits one. Each option below
materializes the same Secret; the FlinkSecret CR is unchanged.

- **External Secrets Operator** – [`secret-managers/eso-externalsecret.yaml`](secret-managers/eso-externalsecret.yaml)
- **Sealed Secrets** – [`secret-managers/sealed-secret.yaml`](secret-managers/sealed-secret.yaml)
- **HashiCorp Vault (VSO)** – [`secret-managers/vault-flinksecret.md`](secret-managers/vault-flinksecret.md)

To use one, install that operator, apply its manifest instead of the inline Secret in
`sql/flinksecret.yaml`, then apply the FlinkSecret as in step 1.

## Tear down

[`teardown.sh`](teardown.sh) reverses the whole walkthrough. To do it by hand, delete the chain in
reverse (so each CMF-side resource is removed before its parent), then uninstall the operators and
clean up:

```bash
# 1. The Flink SQL chain (reverse order)
kubectl delete -f sql/seed-pageviews.yaml
kubectl delete -f sql/statement.yaml
kubectl delete -f sql/create-tables.yaml
kubectl delete -f sql/computepool-shared.yaml -f sql/computepool-dedicated.yaml
kubectl delete -f sql/kafkadatabase.yaml
kubectl delete -f sql/kafkacatalog.yaml
kubectl delete -f sql/secretmapping.yaml
kubectl delete -f sql/flinksecret.yaml

# 2. Wait for the statements'/pools' Flink jobs to drain while CMF + FKO are still up
#    (FKO owns the FlinkDeployment finalizer; removing it before they drain orphans the jobs)
kubectl wait --for=delete flinkdeployment --all -n default --timeout=180s

# 3. FlinkEnvironment first (its delete finalizer reaches CMF via the CMFRestClass), then CMFRestClass
kubectl delete -f platform/flinkenvironment.yaml
kubectl delete -f platform/cmfrestclass.yaml
kubectl delete secret cmf-day2-tls -n operator

# 4. Kafka and Schema Registry
kubectl delete -f platform/kafka.yaml

# 5. CFK, CMF, and the Flink Kubernetes Operator (plus the CMF keystore/truststore configMaps)
helm uninstall confluent-operator -n operator
helm uninstall cmf -n operator
kubectl delete configmap cmf-keystore cmf-truststore -n operator
helm uninstall cp-flink-kubernetes-operator

# 6. The generated cert material
rm -rf certs/ca certs/generated certs/jks
```

The `operator` namespace and cert-manager are left in place; remove them with
`kubectl delete namespace operator` if you no longer need them.
