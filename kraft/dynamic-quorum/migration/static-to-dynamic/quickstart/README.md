## Static to Dynamic Quorum Migration (kraft.version 0 to 1)

Migrates an existing KRaft cluster from static quorum (`kraft.version=0`) to dynamic quorum (`kraft.version=1`). Requires **CP 8.0+**.

### Security Configuration

| Layer | Setting |
|-------|---------|
| TLS | None |
| Authentication | None |
| Authorization (RBAC) | None |
| MDS Provider | None |
| MRC | No (single cluster) |

### Overview

Static quorum uses `controller.quorum.voters` with fixed controller membership. Dynamic quorum (KIP-853) uses `controller.quorum.bootstrap.servers` and supports adding/removing controllers without downtime.

### Version Requirements

| Component | Minimum Version | Notes |
|-----------|----------------|-------|
| **CFK** | 3.2+ | Dynamic quorum support |
| **CP** | 8.0+ | Required for kraft.version upgrade |

### Prerequisites

- A **running KRaft cluster** with static quorum (`kraft.version=0`) and Kafka brokers
- CFK 3.2+ operator deployed
- CP 8.0+ images
- `kubectl` configured with cluster access

If you do not have a running cluster, see [Reference: Setting Up a Test Cluster](#reference-setting-up-a-test-cluster) below.

### Set the Tutorial Home

```bash
export TUTORIAL_HOME=<Tutorial directory>/kraft/dynamic-quorum/migration/static-to-dynamic/quickstart
```


### Migration Flow

This migration is a one-time operation with 4 phases. Phase 1 is MRC-only; quickstart starts at Phase 2.

```
Phase 1 (MRC only)           Phase 2                  Phase 3                          Phase 4
Add advertised listeners --> Upgrade kraft.version --> Switch to dynamicQuorumConfig --> Roll Kafka brokers
(skip for quickstart)    (metadata-level,          (CFK generates                   (pick up new
                              no YAML change)           bootstrap.servers,               bootstrap.servers)
                                                        controllers roll)
```

**Properties at Each Phase:**

| Phase | KRaft properties | Kafka properties | kraft.version |
|-------|-----------------|-----------------|---------------|
| Start | voters | voters | 0 |
| After Phase 2 | voters (unchanged) | voters (unchanged) | 1 |
| After Phase 3 | bootstrap.servers | voters (unchanged) | 1 |
| After Phase 4 | bootstrap.servers | bootstrap.servers | 1 |

#### Pre-migration: Verify starting state

Confirm the cluster is running with static quorum (`kraft.version=0`):

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-features --bootstrap-controller localhost:9074 describe | grep kraft.version
```

Expected: `FinalizedVersionLevel: 0`

Check quorum health:

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --replication
```

All controllers should be voters with low lag.

#### Phase 2: Upgrade kraft.version (metadata-level)

Upgrade kraft.version from 0 to 1 via the `kafka-features` CLI. This is a metadata-level operation -- no YAML change needed, no rolling restart.

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-features --bootstrap-controller localhost:9074 \
  upgrade --feature kraft.version=1
```

Verify:

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-features --bootstrap-controller localhost:9074 describe | grep kraft.version
```

Expected: `FinalizedVersionLevel: 1`

Check that DirectoryIds changed from placeholder `AAAAAAAAAAAAAAAAAAAAAA` to unique UUIDs (expected after kraft.version upgrade):

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --replication
```

#### Phase 3: Switch to dynamicQuorumConfig

Apply KRaftController with `dynamicQuorumConfig.enabled: true`. CFK generates `controller.quorum.bootstrap.servers` (replacing the static `controller.quorum.voters`). This triggers a rolling restart of KRaft controllers.

```bash
kubectl apply -f $TUTORIAL_HOME/resources/kraftcontroller-phase2-dynamic.yaml -n confluent

kubectl wait --for=condition=platform.confluent.io/cluster-ready \
    kraftcontroller/kraftcontroller -n confluent --timeout=10m
```

Verify quorum is healthy after the roll:

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --status

kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --replication
```

#### Phase 4: Roll Kafka Brokers

Force a rolling restart of Kafka brokers so they pick up the new `controller.quorum.bootstrap.servers` configuration:

```bash
kubectl patch kafka kafka -n confluent --type merge \
    -p '{"spec":{"podTemplate":{"annotations":{"kafkacluster-manual-roll":"phase4"}}}}'

kubectl wait --for=condition=platform.confluent.io/cluster-ready \
    kafka/kafka -n confluent --timeout=10m
```

### Validate

Check kraft.version is 1:

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-features --bootstrap-controller localhost:9074 describe | grep kraft.version
```

Check quorum status:

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --status
```

Check quorum replication (shows all controllers with their IDs):

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --replication
```

Prove dynamic quorum works -- remove a controller and re-add it:

```bash
# Get controller ID and directory ID from replication output
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --replication

# Remove a controller (use the ID and directory ID from the output above)
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 \
  remove-controller --controller-id <ID> --controller-directory-id <DIR_ID>

# Re-add the removed controller (run FROM the removed pod)
kubectl exec <removed-pod> -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller \
    kraftcontroller-0.kraftcontroller.confluent.svc.cluster.local:9074 \
  add-controller
```

### Reference: Setting Up a Test Cluster

If you don't already have a running cluster, follow these steps to set one up for testing this migration.

#### Step 1: Create namespace

```bash
kubectl create namespace confluent
```

#### Step 2: Deploy CFK operator

```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --namespace confluent
```

#### Step 3: Deploy Static Quorum Cluster

Deploy a standard KRaft cluster with static quorum (no `dynamicQuorumConfig`):

```bash
kubectl apply -f $TUTORIAL_HOME/resources/kraftcontroller-phase0-static.yaml -n confluent

kubectl wait --for=condition=platform.confluent.io/cluster-ready \
    kraftcontroller/kraftcontroller -n confluent --timeout=10m
```

Deploy Kafka brokers:

```bash
kubectl apply -f $TUTORIAL_HOME/resources/kafka.yaml -n confluent

kubectl wait --for=condition=platform.confluent.io/cluster-ready \
    kafka/kafka -n confluent --timeout=10m
```

Verify `kraft.version=0`:

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-features --bootstrap-controller localhost:9074 describe | grep kraft.version
```

Expected output: `FinalizedVersionLevel: 0`

### Tear Down

```bash
# Phase 1: Delete CP resources
kubectl delete kafka kafka -n confluent --timeout=5m
kubectl delete kraftcontroller kraftcontroller -n confluent --timeout=5m

# Wait for pods to terminate
kubectl wait --for=delete pod -l app=kafka -n confluent --timeout=3m
kubectl wait --for=delete pod -l app=kraftcontroller -n confluent --timeout=3m

# Delete PVCs
kubectl delete pvc -l app=kafka -n confluent
kubectl delete pvc -l app=kraftcontroller -n confluent

# Phase 2: Delete operator
helm uninstall confluent-operator -n confluent

# Phase 3: Delete namespace
kubectl delete namespace confluent
```

### Files

| File | Description |
|------|-------------|
| `resources/kraftcontroller-phase0-static.yaml` | Static quorum, no dynamicQuorumConfig |
| `resources/kraftcontroller-phase2-dynamic.yaml` | dynamicQuorumConfig enabled |
| `resources/kafka.yaml` | Kafka brokers (unchanged throughout migration) |
