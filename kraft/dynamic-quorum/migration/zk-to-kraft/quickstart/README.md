## ZK to KRaft Migration with Dynamic Quorum

Migrate a ZooKeeper-based Kafka cluster to KRaft with KIP-853 dynamic quorum (`kraft.version=1`). Single Kubernetes cluster, no security.

> **Note**: This example migrates from ZooKeeper to KRaft with dynamic quorum (`kraft.version=1`). If you want to migrate to KRaft with static quorum (`kraft.version=0`), refer to the KRaftMigrationJob examples in the confluent-kubernetes-examples repo.

> **Important**: CP 7.9.0 has a bug where `kraft.version=0` is enforced during migration, blocking observer promotion. Use **CP 7.9.6+** or later.

### Security Configuration

| Layer | Setting |
|-------|---------|
| TLS | None |
| Authentication | None |
| Authorization (RBAC) | None |
| MDS Provider | None |
| MRC | No (single cluster) |

### Version Requirements

| Component | Minimum Version | Notes |
|-----------|----------------|-------|
| **CFK** | 3.2+ | Dynamic quorum + ZK-to-KRaft migration support |
| **CP** | 7.9.6+ | Critical for dynamic quorum during migration |

### Prerequisites

- A **running ZooKeeper-based Kafka cluster** with ZooKeeper and Kafka deployed
- CFK 3.2+ operator deployed
- **CP 7.9.6+** images
- Dynamic quorum RBAC and ConfigMap deployed (see [Reference: Setting Up a Test Cluster](#reference-setting-up-a-test-cluster) for details)
- `kubectl` configured with cluster access

If you do not have a running cluster, see [Reference: Setting Up a Test Cluster](#reference-setting-up-a-test-cluster) below.

### Set the Tutorial Home

```bash
export TUTORIAL_HOME=<Tutorial directory>/kraft/dynamic-quorum/migration/zk-to-kraft/quickstart
```


### Migration Flow

This migration takes a ZooKeeper-based Kafka cluster through to a pure KRaft cluster with dynamic quorum in 9 steps:

```
Step 1               Step 2            Step 3              Step 4
Deploy bootstrap --> Deploy          Start            --> Monitor migration
resources            KRaftController  KRaftMigrationJob    -> DUAL_WRITE
(ConfigMap + RBAC)

Step 5              Step 6                Step 7              Step 8                  Step 9
Verify           --> Promote           --> Finalize        --> Switch Kafka to     --> Decommission
kraft.version=1      observers to          migration           KRaft dependency       ZooKeeper
in DUAL_WRITE        voters
```

#### Step 1: Deploy dynamic quorum bootstrap resources

The ConfigMap tracks whether the bootstrap pod has formatted storage. The RBAC allows the bootstrap pod to update the ConfigMap.

```bash
kubectl apply -f $TUTORIAL_HOME/resources/dynamic-quorum-rbac.yaml
kubectl apply -f $TUTORIAL_HOME/resources/dynamic-quorum-configmap.yaml
```


#### Step 2: Deploy KRaftController with dynamic quorum

The KRaftController will remain on hold until the migration job starts.

```bash
kubectl apply -f $TUTORIAL_HOME/resources/kraftcontroller.yaml
```

#### Step 3: Start migration

Create the KRaftMigrationJob to begin ZK-to-KRaft migration:

```bash
kubectl apply -f $TUTORIAL_HOME/resources/kraftmigrationjob.yaml
```

#### Step 4: Monitor migration

Poll KRaftMigrationJob status until DUAL_WRITE:

```bash
kubectl get kraftmigrationjob -n confluent -w
```

Wait for the migration to reach `DUAL_WRITE` phase.

#### Step 5: Verify kraft.version=1 in DUAL_WRITE

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-features --bootstrap-controller localhost:9074 describe | grep kraft.version
```

Expected: `FinalizedVersionLevel: 1`

Check initial quorum state (should show 1 voter, multiple observers):

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --status
```

Check replication status (all controllers should show low lag):

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --replication
```

#### Step 6: Promote observers to voters

Since ZK-to-KRaft migration requires CP 7.9.x (ZK is removed in 8.0+), auto-join is not available and manual promotion is always required.

Run `add-controller` FROM each observer pod, pointing `--bootstrap-controller` to an existing voter:

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

Verify all 3 controllers are voters:

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --status
```

Check replication status (all controllers should show low lag):

```bash
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --replication
```

#### Step 7: Finalize migration

Once all controllers are voters:

```bash
kubectl annotate kraftmigrationjob kraftmigrationjob -n confluent \
  platform.confluent.io/kraft-migration-trigger-finalize-to-kraft='true'
```

#### Step 8: Switch Kafka to KRaft dependency

Apply the updated Kafka YAML that points to KRaft instead of ZooKeeper:

```bash
kubectl apply -f $TUTORIAL_HOME/resources/kafka-kraft-dependency.yaml -n confluent

kubectl wait --for=condition=platform.confluent.io/cluster-ready \
    kafka/kafka -n confluent --timeout=10m
```

#### Step 9: Decommission ZooKeeper

After verifying quorum status and data integrity, delete ZooKeeper:

```bash
kubectl delete zookeeper zookeeper -n confluent
```

Final state: pure KRaft cluster with 3-voter dynamic quorum.

### Validate

```bash
# Migration phase (should be COMPLETE)
kubectl get kraftmigrationjob kraftmigrationjob -n confluent \
  -o jsonpath='{.status.phase}{"\n"}{.status.subPhase}{"\n"}'

# kraft.version
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-features --bootstrap-controller localhost:9074 describe | grep kraft.version

# Quorum status (all 3 should be voters)
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --status

# Replication status (all controllers should show low lag)
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --replication

# ConfigMap state
kubectl get configmap kraftcontroller-dynamic-quorum -n confluent -o yaml | grep bootstrap_formatted
```

### Troubleshooting

**Migration stuck at SubPhaseMigrateMonitorMigrationProgress**: Zero voters -- ConfigMap had `bootstrap_formatted:true` from a previous run. Fix: delete KMJ and KRaftController, reset ConfigMap (`bootstrap_formatted:false`), redeploy.

**Observer promotion crashes controllers**: `IllegalArgumentException: Unexpected type for requestData: UpdateRaftVoterRequestData`. Cause: CP 7.9.0. Fix: upgrade to CP 7.9.6+.

**add-controller fails**: Common mistake is connecting to a non-voter observer via `--bootstrap-controller localhost:9074`. Always point `--bootstrap-controller` to an existing voter's FQDN.

**Direct-to-controller APIs blocked**: `UnsupportedVersionException`. Causes: CP 7.9.0 (upgrade to 7.9.6), IBP below 3.9 (auto-inferred from the image on standard CP; only an issue on a custom image without the annotation), or not yet in DUAL_WRITE phase.

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

#### Step 3: Deploy ZooKeeper

```bash
kubectl apply -f $TUTORIAL_HOME/resources/zookeeper.yaml

kubectl wait --for=condition=platform.confluent.io/cluster-ready \
    zookeeper/zookeeper -n confluent --timeout=10m
```

#### Step 4: Deploy Kafka with ZooKeeper dependency

**IBP version**: the migration needs `inter.broker.protocol.version` at 3.9 (default 3.6 is incompatible with `kraft.version=1`). On standard CP images **CFK auto-infers this from the image tag** — you don't set it. The `platform.confluent.io/kraft-migration-ibp-version` annotation is only needed for custom images CFK can't map:

```yaml
metadata:
  annotations:
    platform.confluent.io/kraft-migration-ibp-version: "3.9"   # only for custom images
```

```bash
kubectl apply -f $TUTORIAL_HOME/resources/kafka.yaml

kubectl wait --for=condition=platform.confluent.io/cluster-ready \
    kafka/kafka -n confluent --timeout=10m
```

### Tear Down

```bash
kubectl delete kraftmigrationjob kraftmigrationjob -n confluent --ignore-not-found=true
kubectl delete kafka kafka -n confluent --ignore-not-found=true --timeout=120s
kubectl delete kraftcontroller kraftcontroller -n confluent --ignore-not-found=true --timeout=120s
kubectl delete zookeeper zookeeper -n confluent --ignore-not-found=true --timeout=120s
kubectl delete configmap kraftcontroller-dynamic-quorum -n confluent --ignore-not-found=true
kubectl delete -f $TUTORIAL_HOME/resources/dynamic-quorum-rbac.yaml --ignore-not-found=true
kubectl delete pvc --all -n confluent --timeout=60s
kubectl delete namespace confluent
```
