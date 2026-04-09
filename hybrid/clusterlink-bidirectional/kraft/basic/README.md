# Bidirectional Cluster Linking - KRaft Basic

This example demonstrates **Bidirectional Cluster Linking** with KRaft mode using plaintext authentication. This is ideal for learning, development, and testing environments.

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
- Two Kafka clusters in KRaft mode (no ZooKeeper)
- One in `src` namespace (source cluster)
- One in `dest` namespace (destination cluster)
- Bidirectional cluster link enabling data flow in both directions

```
+---------------------+                    +---------------------+
|   SOURCE CLUSTER    |   Forward Mirror   | DESTINATION CLUSTER |
|   (Namespace: src)  | -----------------> |  (Namespace: dest)  |
|                     |                    |                     |
|  reverse-topic <----|  Reverse Mirror    |  forward-topic      |
|    (mirror)         | <----------------- |    (original)       |
|                     |                    |                     |
|  forward-topic      |                    |  forward-topic      |
|    (original)       |                    |    (mirror)         |
+---------------------+                    +---------------------+
```

## What Gets Deployed

### Source Cluster (namespace: `src`)
- KRaftController (3 replicas)
- Kafka (3 replicas)
- KafkaRestClass
- KafkaTopic: `forward-topic` (original topic to mirror to destination)
- KafkaTopic: `reverse-topic` (will become mirror of destination's topic)
- ClusterLink: `src-cluster-link` (handles reverse mirroring)

### Destination Cluster (namespace: `dest`)
- KRaftController (3 replicas)
- Kafka (3 replicas)
- KafkaRestClass
- KafkaTopic: `reverse-topic` (original topic to mirror to source)
- ClusterLink: `dest-cluster-link` (handles forward mirroring)

## Set the current tutorial directory

```bash
export TUTORIAL_HOME=<Github repo directory>/hybrid/clusterlink-bidirectional/kraft/basic
```

## Prerequisites

Before continuing with this scenario, ensure that you have:

- A Kubernetes cluster with kubectl configured
- Helm 3.x installed
- [CFK prerequisites](/README.md#prerequisites)

## Deploy Confluent for Kubernetes

**Important**: Bidirectional cluster linking across namespaces requires a single CFK watching all namespaces (`namespaced=false`). When using two separate namespaced CFK instances, each operator can only cache resources from its own namespace. The ClusterLink CR needs to access KafkaRestClass from both namespaces.

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

1. Create the namespaces for source and destination clusters:

```bash
kubectl create namespace src
kubectl create namespace dest
```

2. Create the password encoder secret in both namespaces. This is required for Kafka clusters participating in cluster linking:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/secrets/ -n src
kubectl apply -f $TUTORIAL_HOME/manifests/secrets/ -n dest
```

3. Deploy the source cluster KRaft controllers and Kafka brokers:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/kraftcontroller.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/kafka.yaml
```

4. Deploy the destination cluster KRaft controllers and Kafka brokers:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/kraftcontroller.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/kafka.yaml
```

5. Wait for KRaft controllers to be ready:

```bash
kubectl wait --for=condition=Ready pod -l app=kraftcontroller -n src --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kraftcontroller -n dest --timeout=300s
```

6. Wait for Kafka clusters to be ready:

```bash
kubectl wait --for=condition=Ready pod -l app=kafka -n src --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kafka -n dest --timeout=300s
```

## Create KafkaRestClass and topics

1. Create KafkaRestClass resources for both clusters:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/kafkarestclass.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/kafkarestclass.yaml
```

2. Wait for the REST API to become available (allow about 10 seconds):

```bash
sleep 10
```

3. Create topics on both clusters:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/topics.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/topics.yaml
```

4. Wait for topics to be created:

```bash
sleep 15
```

## Create bidirectional ClusterLinks

Both ClusterLink CRs must be created for the bidirectional link to work. They share the same `spec.name` which associates them as a bidirectional pair.

1. Create the destination-side ClusterLink (handles forward mirroring from source to destination):

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/clusterlink.yaml
```

2. Create the source-side ClusterLink (handles reverse mirroring from destination to source):

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/clusterlink.yaml
```

3. Wait for both ClusterLinks to become healthy. This may take 2-3 minutes:

```bash
kubectl get clusterlink -n src
kubectl get clusterlink -n dest
```

Both should show `CREATED` state once healthy.

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

1. Delete ClusterLinks:

```bash
kubectl delete clusterlink --all -n src --ignore-not-found=true
kubectl delete clusterlink --all -n dest --ignore-not-found=true
```

2. Delete topics:

```bash
kubectl delete kafkatopic --all -n src --ignore-not-found=true
kubectl delete kafkatopic --all -n dest --ignore-not-found=true
```

3. Delete KafkaRestClass:

```bash
kubectl delete kafkarestclass --all -n src --ignore-not-found=true
kubectl delete kafkarestclass --all -n dest --ignore-not-found=true
```

4. Delete Kafka clusters:

```bash
kubectl delete kafka --all -n src --ignore-not-found=true
kubectl delete kafka --all -n dest --ignore-not-found=true
```

5. Delete KRaft controllers:

```bash
kubectl delete kraftcontroller --all -n src --ignore-not-found=true
kubectl delete kraftcontroller --all -n dest --ignore-not-found=true
```

6. Delete secrets:

```bash
kubectl delete secret password-encoder-secret -n src --ignore-not-found=true
kubectl delete secret password-encoder-secret -n dest --ignore-not-found=true
```

7. Optionally delete the namespaces:

```bash
kubectl delete namespace src
kubectl delete namespace dest
```

8. Uninstall CFK:

```bash
helm uninstall confluent-operator -n confluent
kubectl delete namespace confluent
```

## Important Gotchas

### Both ClusterLinks Must Share the Same `spec.name`

Both CRs must use the same link name:

```yaml
# Destination-side ClusterLink
spec:
  name: bidirectional-link  # Must match

# Source-side ClusterLink  
spec:
  name: bidirectional-link  # Same name
```

### Source/Destination Are Swapped for Reverse Mirroring

For the **source-side ClusterLink** (that creates mirror topics in the source namespace):
- `sourceKafkaCluster` points to the **destination** cluster (where data originates)
- `destinationKafkaCluster` points to the **source** cluster (where mirror is created)

This is counter-intuitive but necessary because the "source" of data being mirrored is the destination cluster.

### Create Both ClusterLinks Before Waiting

For bidirectional links to work, both sides must exist. The system won't report them as healthy until both are in place.

### Password Encoder Secret Required

Kafka clusters participating in cluster linking require a password encoder secret with specific format:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: password-encoder-secret
type: Opaque
stringData:
  password-encoder.txt: "password=my-secret-encoder-password"
```

The key must be `password-encoder.txt` and the value must be prefixed with `password=`.

### KRaft Mode - No inter.broker.protocol.version

For KRaft mode, do NOT set `inter.broker.protocol.version`. KRaft automatically uses a compatible metadata version. Setting IBP will cause errors.

## Troubleshooting

### ClusterLink Stuck in "Creating" State

1. Ensure both Kafka clusters are healthy:
   ```bash
   kubectl get kafka -A
   kubectl get kraftcontroller -A
   ```

2. Check KafkaRestClass status:
   ```bash
   kubectl get kafkarestclass -A -o yaml | grep -A10 status
   ```

3. Check ClusterLink events:
   ```bash
   kubectl describe clusterlink -n src src-cluster-link
   kubectl describe clusterlink -n dest dest-cluster-link
   ```

### Mirror Topics Not Created

1. Verify the source topic exists and has data
2. Check ClusterLink status for errors:
   ```bash
   kubectl get clusterlink -n dest dest-cluster-link -o yaml
   ```

### "Timed out waiting for node assignment" Error

This usually means the link cannot connect to the remote cluster:
- Verify network connectivity between namespaces
- Check bootstrap endpoint is correct
- Ensure Kafka REST API is accessible

## References

- [Bidirectional Cluster Linking Docs](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/configs.html#bidirectional-mode)
- [CFK ClusterLink API](https://docs.confluent.io/operator/current/co-api.html#tag/ClusterLink)
