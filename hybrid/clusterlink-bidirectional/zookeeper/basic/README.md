# Bidirectional Cluster Linking - ZooKeeper Basic

This example demonstrates **Bidirectional Cluster Linking** with ZooKeeper mode using plaintext authentication. This is suitable for development and testing with Confluent Platform 7.x.

- [Set the current tutorial directory](#set-the-current-tutorial-directory)
- [Prerequisites](#prerequisites)
- [Deploy Confluent for Kubernetes](#deploy-confluent-for-kubernetes)
- [Deploy the source and destination clusters](#deploy-the-source-and-destination-clusters)
- [Create KafkaRestClass and topics](#create-kafkarestclass-and-topics)
- [Create bidirectional ClusterLinks](#create-bidirectional-clusterlinks)
- [Validate](#validate)
- [Tear down](#tear-down)

> **Availability**: CFK 3.2.0+ and Confluent Platform 7.4+

## Overview

This example sets up:
- Two Kafka clusters with ZooKeeper (traditional mode)
- One in `src` namespace
- One in `dest` namespace
- Bidirectional cluster link enabling data flow in both directions

## Key Difference from KRaft Mode

For ZooKeeper-based clusters, bidirectional linking requires `inter.broker.protocol.version=3.1` or higher:

```yaml
spec:
  configOverrides:
    server:
      - inter.broker.protocol.version=3.1
```

This is **required** because bidirectional cluster linking needs IBP 3.1 or higher. KRaft mode automatically uses metadata.version >= 3.3-IV0, so this override is not needed for KRaft.

## What Gets Deployed

### Source Cluster (namespace: `src`)
- ZooKeeper (3 replicas)
- Kafka (3 replicas) with `inter.broker.protocol.version=3.1`
- KafkaRestClass
- KafkaTopic: `forward-topic`
- ClusterLink: `src-cluster-link` (reverse mirroring)

### Destination Cluster (namespace: `dest`)
- ZooKeeper (3 replicas)
- Kafka (3 replicas) with `inter.broker.protocol.version=3.1`
- KafkaRestClass
- KafkaTopic: `reverse-topic`
- ClusterLink: `dest-cluster-link` (forward mirroring)

## Set the current tutorial directory

```bash
export TUTORIAL_HOME=<Github repo directory>/hybrid/clusterlink-bidirectional/zookeeper/basic
```

## Prerequisites

Before continuing with this scenario, ensure that you have:

- A Kubernetes cluster with kubectl configured
- Helm 3.x installed
- [CFK prerequisites](/README.md#prerequisites)

## Deploy Confluent for Kubernetes

**Important**: Bidirectional cluster linking across namespaces requires a single CFK watching all namespaces (`namespaced=false`). When using two separate namespaced CFK instances, each operator can only cache resources from its own namespace. The ClusterLink CR needs to access KafkaRestClass from both `src` and `dest` namespaces.

1. Set up the Helm Chart:

```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
```

2. Install CFK to watch all namespaces:

```bash
kubectl create namespace confluent
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --namespace confluent \
  --set namespaced=false
```

3. Check that the CFK pod comes up and is running:

```bash
kubectl get pods -n confluent
```

## Deploy the source and destination clusters

1. Create the namespaces:

```bash
kubectl create namespace src
kubectl create namespace dest
```

2. Create the password encoder secret in both namespaces:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/secrets/ -n src
kubectl apply -f $TUTORIAL_HOME/manifests/secrets/ -n dest
```

3. Deploy the source cluster ZooKeeper and Kafka:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/zookeeper.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/kafka.yaml
```

4. Deploy the destination cluster ZooKeeper and Kafka:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/zookeeper.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/kafka.yaml
```

5. Wait for ZooKeeper clusters to be ready:

```bash
kubectl wait --for=condition=Ready pod -l app=zookeeper -n src --timeout=300s
kubectl wait --for=condition=Ready pod -l app=zookeeper -n dest --timeout=300s
```

6. Wait for Kafka clusters to be ready:

```bash
kubectl wait --for=condition=Ready pod -l app=kafka -n src --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kafka -n dest --timeout=300s
```

## Create KafkaRestClass and topics

1. Create KafkaRestClass resources:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/kafkarestclass.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/kafkarestclass.yaml
```

2. Wait for the REST API to become available:

```bash
sleep 10
```

3. Create topics:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/topics.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/topics.yaml
```

4. Wait for topics to be created:

```bash
sleep 10
```

## Create bidirectional ClusterLinks

1. Create the destination-side ClusterLink (forward mirroring) and source-side ClusterLink (reverse mirroring):

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/clusterlink.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/clusterlink.yaml
```

2. Monitor ClusterLink status until both show `CREATED`:

```bash
kubectl get clusterlink -n src
kubectl get clusterlink -n dest
```

## Validate

1. Verify both ClusterLinks are in `CREATED` state:

```bash
kubectl get clusterlink src-cluster-link -n src -o jsonpath='{.status.state}'
kubectl get clusterlink dest-cluster-link -n dest -o jsonpath='{.status.state}'
```

2. Test forward mirroring (source to destination). Produce a message to `forward-topic` on the source cluster:

```bash
kubectl exec -n src kafka-0 -- bash -c \
  "echo 'hello from source' | kafka-console-producer --topic forward-topic --bootstrap-server kafka.src.svc.cluster.local:9092"
```

3. Consume the mirrored message from the destination cluster:

```bash
kubectl exec -n dest kafka-0 -- kafka-console-consumer \
  --topic forward-topic \
  --bootstrap-server kafka.dest.svc.cluster.local:9092 \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 30000
```

4. Test reverse mirroring (destination to source). Produce a message to `reverse-topic` on the destination cluster:

```bash
kubectl exec -n dest kafka-0 -- bash -c \
  "echo 'hello from destination' | kafka-console-producer --topic reverse-topic --bootstrap-server kafka.dest.svc.cluster.local:9092"
```

5. Consume the mirrored message from the source cluster:

```bash
kubectl exec -n src kafka-0 -- kafka-console-consumer \
  --topic reverse-topic \
  --bootstrap-server kafka.src.svc.cluster.local:9092 \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 30000
```

## Tear down

1. Delete all Confluent Platform resources:

```bash
for resource in clusterlink kafkatopic kafkarestclass kafka zookeeper; do
  kubectl delete $resource --all -n src --ignore-not-found=true
  kubectl delete $resource --all -n dest --ignore-not-found=true
done
```

2. Delete secrets:

```bash
kubectl delete secret password-encoder-secret -n src --ignore-not-found=true
kubectl delete secret password-encoder-secret -n dest --ignore-not-found=true
```

3. Optionally delete the namespaces:

```bash
kubectl delete namespace src
kubectl delete namespace dest
```

4. Uninstall CFK:

```bash
helm uninstall confluent-operator -n confluent
kubectl delete namespace confluent
```

## Important Gotchas

### inter.broker.protocol.version Required

For ZooKeeper mode, you **must** set `inter.broker.protocol.version=3.1` or higher. Without this, bidirectional cluster linking will fail with `UnsupportedVersionException`.

### Single CFK Required for Cross-Namespace Links

Each ClusterLink CR references KafkaRestClass from both namespaces. A namespaced CFK can only cache resources from its own namespace, causing:
```
"unable to get: src/src-rest because of unknown namespace for the cache"
```

### Both Links Share the Same spec.name

Same as KRaft mode - both ClusterLink CRs must have the same `spec.name`.

### Source/Destination Swapped for Reverse Mirroring

Same as KRaft mode - for the source-side link, the source/destination are swapped.

### Password Encoder Secret Format

The password encoder secret must use the key `password-encoder.txt` with format `password=<your-password>`.

## Troubleshooting

### "unknown namespace for the cache"

This means you're running with `namespaced=true` but the ClusterLink needs to access resources from another namespace. **Solution**: Use a single CFK with `namespaced=false`.

### "UnsupportedVersionException" or "UNSUPPORTED_VERSION"

This indicates `inter.broker.protocol.version` is not set correctly:
1. Verify the config override is applied:
   ```bash
   kubectl get kafka -n src -o yaml | grep -A5 configOverrides
   ```
2. The minimum required version is 3.1

### ClusterLink Not Creating

1. Check ZooKeeper is healthy:
   ```bash
   kubectl get zookeeper -A
   ```

2. Check Kafka cluster health:
   ```bash
   kubectl get kafka -A
   ```

3. Check CFK operator logs:
   ```bash
   kubectl logs -n confluent -l app=confluent-operator --tail=50
   ```

## References

- [Bidirectional Cluster Linking Docs](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/configs.html#bidirectional-mode)
