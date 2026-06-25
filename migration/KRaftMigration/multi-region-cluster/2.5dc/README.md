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

## Recommended target: KRaft with dynamic quorum (KIP-853)

For new migrations — and **especially MRC** — dynamic quorum (`kraft.version=1`) is the
recommended end state, not static quorum (`kraft.version=0`). Dynamic quorum lets you
add/remove controllers (`add-controller` / `remove-controller`) and reshape the voter set
**without** rewriting every node's `controller.quorum.voters` and rolling, and it enables KRaft
disaster-recovery tooling (`force-standalone` / controller re-join). For MRC this directly
mitigates the static-quorum rigidity that makes a lost or split-quorum region hard to recover
(static quorum cannot `remove-controller` at all).

**It also de-risks the migration itself — dynamic quorum does not wait for a majority to form.**
With dynamic quorum the bootstrap voter forms the quorum on its own and the other controllers
join as observers, so **quorum formation does not wait for a cross-region voter majority.** You 
still apply all regions' KMJs — that is required to reach cluster-wide DUAL-WRITE — but with 
dynamic quorum the quorum no longer has to wait for a cross-region majority to form first, so 
the migration is far more forgiving of cross-region timing and ordering.

**Version requirement.** The ZK→KRaft migration runs only on CP 7.9.x (ZooKeeper is removed in
CP 8.0+). On **CP 7.9.6+** you can land directly on `kraft.version=1` in a single migration —
this is the recommended path; use the [`dynamic-quorum/`](dynamic-quorum/) scenario.

If you are not adopting dynamic quorum yet, the `plaintext/` and `mtls-rbac/` scenarios migrate
to static quorum (`kraft.version=0`) instead. Static quorum works, but be aware of the
cross-region quorum-formation constraint described in
[MRC migration sequencing](#mrc-migration-sequencing), and that a lost region cannot be recovered
with `remove-controller`.

## Scenarios

### plaintext/

Non-secured 2.5DC migration with **static quorum** — the simplest example for learning the
migration flow. For a production target, prefer `dynamic-quorum/` (see
[Recommended target](#recommended-target-kraft-with-dynamic-quorum-kip-853)).

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

1. Deploy KRaftControllers with hold annotation in all DCs (set `clusterID` on the 0.5DC KRaftController — full DCs get it automatically from the KMJ's Kafka dependency; the 0.5DC runs in lite mode with no Kafka, so `clusterID` must be set manually)
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

> **Static vs dynamic quorum — how KMJ sequencing differs:**
> - **Static quorum** (the `plaintext/` and `mtls-rbac/` scenarios): every controller across
>   all regions is a voter, so the quorum needs a **majority of voters** up to elect a leader
>   (e.g. 3 of 5) — not all of them, and all regions' KMJs are needed to reach cluster-wide
>   DUAL-WRITE. Because the 0.5DC tiebreaker has a voter but **no brokers**, you can form the
>   quorum with the tiebreaker + one broker region and keep only one broker-bearing region
>   rolling at a time — this is **safe for both plaintext and secured (`mtls-rbac/`)** clusters.
>   See the static-quorum migration procedure below.
> - **Dynamic quorum** (the `dynamic-quorum/` scenario): the bootstrap voter forms the quorum
>   on its own, so KMJs can be applied **one region at a time**. Apply the bootstrap voter's
>   region first, wait for it to reach the `MIGRATE` phase with subphase
>   `MigrateMonitorMigrationProgress` (all broker rolls in that region complete), then apply
>   the next region. This sequences the broker rolls so only one region rolls at a time,
>   eliminating the cross-region URP race window entirely.

During migration, each region's Kafka brokers are rolled multiple times. During finalization,
brokers are rolled again to remove the ZooKeeper dependency, and KRaft controllers are rolled
to remove migration configs. Each region's operator rolls brokers independently — within a
region, only one broker restarts at a time, and the operator gates on cluster-wide URP=0
(under-replicated partitions = 0) before rolling the next. Because the URP check is
cluster-wide, a broker restart in one region blocks other regions from rolling a broker that
shares a partition replica.

However, there is no distributed lock across regions — each region's operator evaluates the
URP check on its own loop. There is a small theoretical timing window where two operators
could both read URP=0 and begin a restart before either shutdown registers.

### Migration procedure — static quorum

The quorum needs a **majority of voters** up to elect a leader, and a region's brokers don't
roll until the quorum has formed. The 0.5DC tiebreaker (central) has a voter but **no brokers**,
so you can form the quorum with the tiebreaker plus one broker region and keep broker rolls
serialized — this works for **both the plaintext and secured (`mtls-rbac/`) scenarios**:

1. Apply the 0.5DC tiebreaker + the first broker region. Their voters are a majority
   (e.g. central 1 + east 2 = 3 of 5), so the quorum forms; only the broker region rolls
   (the tiebreaker has no brokers):
   ```bash
   kubectl --context $CTX3 apply -f migration-central.yaml   # 0.5DC tiebreaker (lite, no brokers)
   kubectl --context $CTX1 apply -f migration-east.yaml      # first broker region — rolls now
   ```
2. Wait for the broker region to reach `MIGRATE` / `MigrateMonitorMigrationProgress` (its rolls
   are done and it parks):
   ```bash
   kubectl --context $CTX1 get kmj kraftmigrationjob -n east -w -oyaml
   ```
3. Apply the remaining broker region — it now rolls alone:
   ```bash
   kubectl --context $CTX2 apply -f migration-west.yaml
   ```

Monitor all regions until they reach `DUAL-WRITE`:
```bash
kubectl --context $CTX1 get kmj kraftmigrationjob -n east -w -oyaml
kubectl --context $CTX2 get kmj kraftmigrationjob -n west -w -oyaml
kubectl --context $CTX3 get kmj kraftmigrationjob -n central -w -oyaml
```

> **Note:** `DUAL-WRITE` is a cluster-wide state, not a per-region state. The last region to
> finish its broker rolls is the bottleneck for this transition.

### Migration procedure — dynamic quorum

Apply KRaftMigrationJobs **one region at a time**, starting with the bootstrap voter's region.
Wait for each region to reach `MIGRATE` phase with subphase `MigrateMonitorMigrationProgress`
(all broker rolls complete) before applying the next. This sequences the broker rolls so only
one region rolls at a time, eliminating the cross-region URP race window entirely.

```bash
# Region 1 (bootstrap voter) — quorum forms, brokers roll through SETUP into MIGRATE
kubectl --context $CTX1 apply -f migration-east.yaml
# Wait for: phase=MIGRATE, subPhase=MigrateMonitorMigrationProgress

# Region 2 — only after region 1 broker rolls are done
kubectl --context $CTX2 apply -f migration-west.yaml
# Wait for: phase=MIGRATE, subPhase=MigrateMonitorMigrationProgress

# Region 3 (0.5DC) — lite mode, no Kafka to roll
kubectl --context $CTX3 apply -f migration-central.yaml
```

Monitor all regions until they reach `DUAL-WRITE`:
```bash
kubectl --context $CTX1 get kmj kraftmigrationjob -n east -w -oyaml
kubectl --context $CTX2 get kmj kraftmigrationjob -n west -w -oyaml
kubectl --context $CTX3 get kmj kraftmigrationjob -n central -w -oyaml
```

> **Note:** `DUAL-WRITE` is a cluster-wide state. The last region to finish is the bottleneck.

### Finalization procedure

Trigger finalization **one region at a time**. This removes the ZooKeeper dependency from
Kafka brokers and the migration configuration from KRaft controllers, each requiring a roll.
Wait for each region to reach the `COMPLETE` phase before proceeding to the next.

> **Note:** Finalization is irreversible — once ZooKeeper is removed from a region's brokers,
> that region cannot roll back to ZooKeeper mode.

### Rollback procedure

If you need to roll back to ZooKeeper, trigger rollback **one region at a time** to avoid
simultaneous cross-region broker rolls (same URP-race concern as migration). Rollback involves
up to multiple Kafka broker rolls per region, plus a manual step to delete ZooKeeper znodes.
Wait for each region to reach `RollbackToZkComplete` before starting the next.

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
