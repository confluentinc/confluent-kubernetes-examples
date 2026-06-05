# CP Flink SQL on CFK (Day-2, mTLS)

This playbook walks through the Confluent Platform Flink **SQL** Day-2 resources managed by
CFK through the Confluent Manager for Apache Flink (CMF). You will build the full chain:

```
FlinkSecret → FlinkKafkaCatalog → FlinkKafkaDatabase → FlinkComputePool → FlinkStatement
```

- **FlinkSecret** – syncs a Kubernetes Secret (Kafka / Schema Registry credentials) to CMF.
- **FlinkKafkaCatalog** – binds a Schema Registry instance and one or more Kafka clusters.
- **FlinkKafkaDatabase** – a SQL database inside a catalog, mapped to a Kafka cluster.
- **FlinkComputePool** – the compute that runs statements (DEDICATED and SHARED variants).
- **FlinkStatement** – a single Flink SQL statement (a streaming job).

It uses the same minimal **mTLS** CMF setup as [`../mTLS`](../mTLS), plus a small Kafka +
Schema Registry for the catalog to connect to.

> **Preview.** The Flink SQL controllers are an opt-in CFK feature (`enableFlinkSQL`). Use a
> CFK release and a CMF version that ship them (CFK >= 3.3.0, CMF with the Flink SQL REST API).
> Pin these versions for your environment before running.

## Setup Certs

Certificates with appropriate Subject Alternate Names (SANs) for the CMF mTLS setup are
provided under:

1. `certs/` – certs in PEM
2. `jks/` – keystore & truststore

## Prerequisites

* `kubectl`, `helm`, and a Kubernetes cluster.
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
2. Create the keystore/truststore configMaps:
    ```bash
    kubectl create configmap cmf-keystore -n operator --from-file ./jks/keystore.jks
    kubectl create configmap cmf-truststore -n operator --from-file ./jks/truststore.jks
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
4. Deploy via Helm:
    ```bash
    kubectl create secret generic <license-secret-name> --from-file=license.txt -n operator
    helm upgrade --install -f local.yaml cmf confluentinc/confluent-manager-for-apache-flink \
      --set license.secretRef=<license-secret-name> --namespace operator
    ```
5. Add the local name to `/etc/hosts` and port-forward:
    ```
    127.0.0.1       confluent-manager-for-apache-flink.operator.svc.cluster.local
    ```
    ```bash
    while true; do kubectl port-forward service/cmf-service 8080:80 -n operator; done
    ```

## Deploy CFK

Deploy CFK with both Day-2 flags so it reconciles the CMF and Flink SQL CRs:

```bash
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes \
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
      --from-file=fullchain.pem=./certs/server.pem \
      --from-file=privkey.pem=./certs/server-key.pem \
      --from-file=cacerts.pem=./certs/cacerts.pem
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
kubectl apply -f sql/00-flinksecret.yaml
kubectl get flinksecret flink-connection-secret -n operator -oyaml
```

Expect `cfkInternalState: CREATED` and `cmfSync.status: Created`. (To source the backing
Secret from Vault / Sealed Secrets / ESO instead, see [Using an external secret
manager](#using-an-external-secret-manager).)

## Step 2 – FlinkKafkaCatalog

```bash
kubectl apply -f sql/10-kafkacatalog.yaml
kubectl get flinkkafkacatalog kafka-catalog -n operator -oyaml
```

The catalog wires Schema Registry (`srInstance`) and a Kafka cluster (`kafkaClusters`, each
exposed as a database). `connectionSecretId` references the FlinkSecret from step 1.

## Step 3 – FlinkKafkaDatabase

```bash
kubectl apply -f sql/20-kafkadatabase.yaml
kubectl get flinkkafkadatabase examples -n operator -oyaml
```

The database belongs to the catalog (`catalogRef`) and is the SQL namespace your statements
read and write. Topics in the bound Kafka cluster surface as tables.

## Step 4 – FlinkComputePool (DEDICATED and SHARED)

A statement runs on a compute pool. Deploy a DEDICATED pool (reserved resources) and a SHARED
pool (multiplexed, supports `state: RUNNING|SUSPENDED`):

```bash
kubectl apply -f sql/30-computepool-dedicated.yaml
kubectl apply -f sql/31-computepool-shared.yaml
kubectl get flinkcomputepool -n operator
```

`spec.type` is immutable. `spec.state` is valid only on SHARED pools (enforced by a CEL rule);
set it to `SUSPENDED` to pause a SHARED pool without deleting it.

## Step 5 – FlinkStatement

`sql/40-statement.yaml` runs a streaming SQL statement on the DEDICATED pool. It reads a
`pageviews` table and writes per-user counts to `pageviews_by_user`, both in the `examples`
database. Create those tables first (or point at existing Kafka topics) — for example, run
`CREATE TABLE` statements as their own FlinkStatements, or let the database map existing topics.

```bash
kubectl apply -f sql/40-statement.yaml
kubectl get flinkstatement pageviews-by-user -n operator -oyaml
```

Expect `cfkInternalState: CREATED`, `cmfSync.status: Created`, and `status.phase: RUNNING`.
`spec.statement` is immutable once running; set `spec.stopped: true` to stop without deleting.

## Using an external secret manager

The FlinkSecret consumes a standard Kubernetes Secret, so the backing Secret
(`flink-connection-credentials`) can be produced by any tool that emits one. Each option below
materializes the same Secret; the FlinkSecret CR is unchanged.

- **External Secrets Operator** – [`secret-managers/eso-externalsecret.yaml`](secret-managers/eso-externalsecret.yaml)
- **Sealed Secrets** – [`secret-managers/sealed-secret.yaml`](secret-managers/sealed-secret.yaml)
- **HashiCorp Vault (VSO)** – [`secret-managers/vault-flinksecret.md`](secret-managers/vault-flinksecret.md)

To use one, install that operator, apply its manifest instead of the inline Secret in
`sql/00-flinksecret.yaml`, then apply the FlinkSecret as in step 1.

## Tear down

Delete in reverse so each CMF-side resource is removed before its parent:

```bash
kubectl delete -f sql/40-statement.yaml
kubectl delete -f sql/31-computepool-shared.yaml -f sql/30-computepool-dedicated.yaml
kubectl delete -f sql/20-kafkadatabase.yaml
kubectl delete -f sql/10-kafkacatalog.yaml
kubectl delete -f sql/00-flinksecret.yaml
kubectl delete -f platform/flinkenvironment.yaml -f platform/cmfrestclass.yaml
kubectl delete -f platform/kafka.yaml
```
