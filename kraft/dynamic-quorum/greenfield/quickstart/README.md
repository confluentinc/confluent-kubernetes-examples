## Dynamic Quorum - Greenfield Quickstart

Deploy a KRaft cluster with dynamic quorum (KIP-853) in a single Kubernetes cluster with no security. This is the simplest way to get started with dynamic quorum.

### Security Configuration

| Layer | Setting |
|-------|---------|
| TLS | None |
| Authentication | None |
| Authorization (RBAC) | None |
| MDS Provider | None |
| MRC | No (single cluster) |

### Prerequisites

- Kubernetes cluster with `kubectl` configured
- Confluent for Kubernetes (CFK) 3.2+ operator deployed
- CP 7.9+ images (CP 8.2+ recommended for auto-join)

### Confluent Platform Version Compatibility

- **CP 8.2+**: Observers are automatically promoted to voters (no manual promotion needed).
- **CP 8.1 and earlier**: Observers must be manually promoted using `kafka-metadata-quorum add-controller`.

### Set the Tutorial Home

```bash
export TUTORIAL_HOME=<Tutorial directory>/kraft/dynamic-quorum/greenfield/quickstart
```


### Step 1: Create the namespace

```bash
kubectl create namespace confluent
```

### Step 2: Create the dynamic quorum ConfigMap

The ConfigMap tracks whether the bootstrap pod has formatted storage. This prevents split-brain on restarts.

```bash
kubectl create configmap kraftcontroller-dynamic-quorum \
    --from-literal=bootstrap-status='{"bootstrap_formatted": false}' \
    -n confluent
```

### Step 3: Create RBAC for ConfigMap access

The KRaftController pods need permission to read and update the ConfigMap during bootstrap.

```bash
kubectl create role kraftcontroller-dynamic-quorum-role \
    --verb=get,update,patch \
    --resource=configmaps \
    --resource-name="kraftcontroller-dynamic-quorum" \
    -n confluent

kubectl create rolebinding kraftcontroller-dynamic-quorum-binding \
    --role=kraftcontroller-dynamic-quorum-role \
    --serviceaccount=confluent:default \
    -n confluent
```

### Step 4: Deploy KRaftController

```bash
kubectl apply -f $TUTORIAL_HOME/resources/kraftcontroller-dynamic.yaml -n confluent
```

Wait for all controller pods to be ready:

```bash
kubectl wait --for=condition=ready pod -l app=kraftcontroller -n confluent --timeout=300s
```

### Step 5: Promote observers to voters (CP < 8.2 only)

Check `describe --replication` output from the previous step. If controllers show `ReplicaState: Follower` (not `Observer`), auto-join (CP 8.2+) has already promoted them and you can **skip this step**.

If controllers show `ReplicaState: Observer`, promote each observer pod to a voter. Run `add-controller` FROM the observer pod, pointing `--bootstrap-controller` to an existing voter:

```bash
# Promote kraftcontroller-1
kubectl exec kraftcontroller-1 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller \
    kraftcontroller-0.kraftcontroller.confluent.svc.cluster.local:9074 \
    --command-config /opt/confluentinc/etc/kafka/kafka.properties \
    add-controller

# Promote kraftcontroller-2
kubectl exec kraftcontroller-2 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller \
    kraftcontroller-0.kraftcontroller.confluent.svc.cluster.local:9074 \
    --command-config /opt/confluentinc/etc/kafka/kafka.properties \
    add-controller
```

### Step 6: Deploy Kafka

```bash
kubectl apply -f $TUTORIAL_HOME/resources/kafka-with-dynamic-kraft.yaml -n confluent
```

Wait for Kafka to be ready:

```bash
kubectl wait --for=condition=ready pod -l app=kafka -n confluent --timeout=300s
```

### Validate

Check that all pods are running:

```bash
kubectl get pods -n confluent
```

Check the quorum status (all controllers should be voters):

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --status
```

Check `kraft.version` is 1 (dynamic quorum active):

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-features --bootstrap-controller localhost:9074 describe | grep kraft.version
```

Monitor quorum replication:

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --replication
```

### Tear Down

```bash
kubectl delete kafka kafka -n confluent
kubectl delete kraftcontroller kraftcontroller -n confluent
kubectl delete rolebinding kraftcontroller-dynamic-quorum-binding -n confluent
kubectl delete role kraftcontroller-dynamic-quorum-role -n confluent
kubectl delete configmap kraftcontroller-dynamic-quorum -n confluent
kubectl delete namespace confluent
```

### Troubleshooting

**Migration stuck / zero voters**: If the ConfigMap shows `bootstrap_formatted:true` from a previous run, kraftcontroller-0 formats with `--no-initial-controllers` instead of `--standalone`, resulting in zero voters. Fix by resetting the ConfigMap:

```bash
kubectl patch configmap kraftcontroller-dynamic-quorum -n confluent \
    --type='merge' \
    -p '{"data":{"bootstrap-status":"{\"bootstrap_formatted\": false}"}}'
```

Then delete the KRaftController pods to restart them:

```bash
kubectl delete pods -n confluent -l app=kraftcontroller
```
