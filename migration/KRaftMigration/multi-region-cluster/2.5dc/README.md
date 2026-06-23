# 2.5DC KRaft Migration (ZooKeeper to KRaft)

Example YAMLs for migrating a 2.5DC (two-and-a-half datacenter) multi-region Confluent Platform
deployment from ZooKeeper to KRaft using CFK 3.3.0+.

## Architecture

```
Cluster 1 (east)                Cluster 2 (west)                Cluster 3 (central) - 0.5DC
+----------------------------+  +----------------------------+  +----------------------------+
| DC1                        |  | DC2                        |  | DC3                        |
|  ZooKeeper + Kafka         |  |  ZooKeeper + Kafka         |  |  ZooKeeper only            |
|  KRaftController           |  |  KRaftController           |  |  KRaftController           |
|  KRaftMigrationJob (full)  |  |  KRaftMigrationJob (full)  |  |  KRaftMigrationJob (lite)  |
+----------------------------+  +----------------------------+  |  NO Kafka                  |
                                                                +----------------------------+
```

Each DC runs on a separate Kubernetes cluster. Cross-cluster communication is via
ExternalDNS + LoadBalancer services.

The 0.5DC (central) acts as the tiebreaker for the ZooKeeper and KRaft quorums.
It runs ZooKeeper and a KRaft controller but no Kafka brokers.

## What's different from 3DC migration

In the 0.5DC datacenter:

- **Lite-mode KRaftMigrationJob**: Omit `spec.dependencies.kafka` to trigger lite mode.
  The KMJ skips Kafka-specific sub-phases and sources ZK config from the KRaftController.

- **KRaftController `spec.dependencies.migration.zookeeper`**: Required because there is no
  Kafka CR to derive ZK connection details from. Set `endpoint` to the full multi-host ZK
  connect string including chroot.

- **Manual `spec.clusterID`**: Must be fetched from an existing Kafka broker and set on the
  0.5DC KRaftController before deploying the KRaftMigrationJob:
  ```bash
  CLUSTER_ID=$(kubectl exec kafka-0 -n east -- \
    grep cluster.id /mnt/data/data0/logs/meta.properties | cut -d= -f2)
  ```

- **No `zookeeper.connect` configOverride needed**: CFK 3.3.0+ correctly derives the ZK
  endpoint for KRaft controllers.

## Scenarios

### plaintext/

Non-secured 2.5DC migration with static quorum. Start here for the simplest example.

### mtls-rbac/

Secured 2.5DC migration with mTLS, SASL/PLAIN authentication, and RBAC authorization via MDS.
The 0.5DC KRaftController additionally requires:
- `spec.dependencies.mdsKafkaCluster` pointing to a Kafka cluster in a full-mode DC
- `spec.dependencies.migration.zookeeper.tls.enabled: true` with the TLS ZK port (2182)

The following secrets must exist in each namespace before deploying KRaftControllers:
- `tls-<region>` (e.g., `tls-east`, `tls-west`, `tls-central`) — TLS certificates for each KRaftController
- `credential` — JAAS credentials for replication and controller listeners
- `credential-mds` — MDS client credentials for RBAC authorization

### dynamic-quorum/

2.5DC migration with KIP-853 dynamic quorum. Key differences from static quorum:
- `dynamicQuorumConfig.enabled: true` on all KRaftControllers
- `bootstrapPod: 0` on the DC1 KRaftController (the initial voter)
- `advertisedListenersEnabled: true` on all KRaftControllers (required for cross-cluster
  `add-controller` to succeed)
- Bootstrap ConfigMap + RBAC in the bootstrap voter's namespace (DC1)
- All other controllers start as observers and must be promoted to voters during DUAL-WRITE

## Prerequisites

- CFK 3.3.0 or later
- An existing ZooKeeper-based MRC Confluent Platform deployment across the 2.5DC topology
- Cross-cluster DNS via ExternalDNS with LoadBalancer services
  (see [3dc/zookeeper-based-cluster](../3dc/zookeeper-based-cluster/) for ExternalDNS setup reference)

## Migration steps

1. Deploy KRaftControllers with hold annotation in all DCs (set `clusterID` on the 0.5DC KRaftController)
2. Deploy KRaftMigrationJobs in all DCs (see [MRC migration sequencing](#mrc-migration-sequencing) below)
3. Monitor migration to DUAL-WRITE
4. For dynamic quorum: promote observer KRCs to voters during DUAL-WRITE
5. Finalize migration one region at a time
6. Release CR locks and clean up ZooKeeper

Refer to the [CFK documentation](https://docs.confluent.io/operator/current/co-migrate-kraft-mrc.html)
for the full step-by-step MRC migration procedure.

## MRC migration sequencing

KRaftMigrationJobs must be applied in **all regions** for migration to proceed. The KMJ in
each region releases the `kraft-migration-hold-krc-creation` annotation on that region's
KRaft controllers — without all KMJs applied, controllers in the remaining regions stay in
HOLD and the migration gets stuck.

> **Static vs dynamic quorum — why all KMJs are required:**
> - **Static quorum** (the `plaintext/` and `mtls-rbac/` scenarios): every controller across
>   all regions is a voter, so a quorum **majority cannot form** until enough regions' KMJs
>   are applied to bring up a majority of voters. Starting in only a minority-voter region is
>   the most common stuck-migration cause — on secured clusters the controllers crash-loop
>   because the RBAC authorizer cannot initialize without a quorum leader.
> - **Dynamic quorum** (the `dynamic-quorum/` scenario): the bootstrap voter forms the quorum
>   on its own and the other controllers join as **observers**, so quorum-majority is not the
>   blocker. All KMJs are still required because **DUAL-WRITE is cluster-wide** — it cannot
>   begin until every region's brokers are in migration mode, and each region's controllers
>   stay in HOLD until that region's KMJ runs.

During migration, each region's Kafka brokers are rolled multiple times. During finalization,
brokers are rolled again to remove the ZooKeeper dependency, and KRaft controllers are rolled
to remove migration configs. Each region's operator rolls brokers independently — within a
region, only one broker restarts at a time, and the operator gates on cluster-wide URP=0
(under-replicated partitions = 0) before rolling the next. Because the URP check is
cluster-wide, a broker restart in one region blocks other regions from rolling a broker that
shares a partition replica.

However, there is no distributed lock across regions — each region's operator evaluates the
URP check on its own loop. There is a small theoretical timing window where two operators
could both read URP=0 and begin a restart before either shutdown registers. To close this
gap, the recommended approaches are described below.

### Prerequisites

- **>= 2 brokers per region.** Restarting a region's only broker leaves that region with
  nothing running — guaranteed outage. This was the root cause of downtime in production
  incidents.
- **`zookeeper.connect` on KRaftController must exactly match the Kafka CR's ZK endpoint**
  (same hosts, same chroot). A mismatch causes the migration to loop indefinitely.

### Migration procedure

There are three valid approaches — they trade off migration speed vs. simplicity:

**Approach 1 (Recommended) — Apply all regions, rely on URP gating**

Apply KRaftMigrationJobs in all regions. The operator's cluster-wide URP=0 check serializes
broker restarts at the partition-availability level — at most one replica of any given
partition is offline at a time. With >= 2 brokers per region and appropriate RF, this provides
zero downtime. You can stagger the KMJ starts by a few minutes across regions to further
reduce the small URP race window.

```bash
kubectl --context $CTX1 apply -f migration-east.yaml
kubectl --context $CTX2 apply -f migration-west.yaml
kubectl --context $CTX3 apply -f migration-central.yaml
```

Monitor all regions until they reach `DUAL-WRITE`:
```bash
kubectl --context $CTX1 get kmj kraftmigrationjob -n east -w -oyaml
kubectl --context $CTX2 get kmj kraftmigrationjob -n west -w -oyaml
kubectl --context $CTX3 get kmj kraftmigrationjob -n central -w -oyaml
```

> **Note:** `DUAL-WRITE` is a cluster-wide state, not a per-region state. The last region to
> finish its broker rolls is the bottleneck for this transition.

**Approach 2 — Increase RF before migration**

If you want extra protection against the URP race window, increase the replication factor for
all topics before starting migration. The extra replicas give headroom so that even if brokers
in multiple regions restart concurrently, partitions stay above `min.insync.replicas`. Then
apply all KMJs simultaneously.

- In a 3-region deployment: RF >= 4 with `min.insync.replicas` <= RF - 3
- In a 2-region deployment: RF >= 4 with `min.insync.replicas` <= RF - 2

**Approach 3 — Staggered starts**

If you cannot change RF: apply the KMJ in the first region, wait a short gap (e.g., until
its brokers have started their first roll), then apply the next region. This keeps the
per-region rolling restarts from aligning in time.

### Finalization procedure

Trigger finalization **one region at a time**. This removes the ZooKeeper dependency from
Kafka brokers and the migration configuration from KRaft controllers, each requiring a roll.
Wait for each region to reach the `COMPLETE` phase before proceeding to the next.

> **Note:** Finalization is irreversible — once ZooKeeper is removed from a region's brokers,
> that region cannot roll back to ZooKeeper mode.

### Rollback procedure

If you need to roll back to ZooKeeper, trigger rollback one region at a time. Rollback
involves up to multiple Kafka broker rolls per region, plus a manual step to delete ZooKeeper
znodes.

1. Trigger rollback in the first region. Monitor its status until it reaches
   `RollbackToZkWaitForManualNodeRemovalFromZk`, which indicates the first broker roll is
   complete and the job is waiting for manual intervention.
2. Delete the `/controller` and `/migration` znodes from ZooKeeper as directed by the status
   condition, then apply the continue annotation to resume the rollback. Wait for the region
   to reach `RollbackToZkComplete`.
3. Repeat for each subsequent region, waiting for `RollbackToZkComplete` before moving to
   the next.

## File structure

```
2.5dc/
├── plaintext/                  # Non-secured, static quorum
│   ├── zookeeper/              # ZK CRs for east, west, central
│   ├── kafka/                  # Kafka CRs for east, west (no central)
│   ├── kraft/                  # KRC CRs — kraft-central.yaml is the 0.5DC example
│   └── migration/              # KMJ CRs — migration-central.yaml is lite-mode
├── mtls-rbac/                  # mTLS + RBAC, static quorum
│   ├── zookeeper/
│   ├── kafka/
│   ├── kraft/                  # kraft-central.yaml includes mdsKafkaCluster + TLS
│   └── migration/
└── dynamic-quorum/             # Plaintext, KIP-853 dynamic quorum
    ├── bootstrap/              # ConfigMap + RBAC for bootstrap voter (DC1 only)
    ├── zookeeper/
    ├── kafka/
    ├── kraft/                  # All KRCs have dynamicQuorumConfig.enabled: true
    └── migration/
```
