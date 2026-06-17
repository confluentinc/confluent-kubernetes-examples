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

1. Deploy KRaftControllers with hold annotation in all 3 DCs (set `clusterID` on the 0.5DC KRaftController)
2. Deploy KRaftMigrationJobs one region at a time (see [sequencing guideline](#mrc-migration-sequencing) below)
3. Monitor migration to DUAL-WRITE
4. For dynamic quorum: promote observer KRCs to voters during DUAL-WRITE
5. Finalize migration one region at a time (see [sequencing guideline](#mrc-migration-sequencing) below)
6. Release CR locks and clean up ZooKeeper

Refer to the [CFK documentation](https://docs.confluent.io/operator/current/co-migrate-kraft-procedure.html)
for the full step-by-step procedure.

## MRC migration sequencing

In a Multi-Region Cluster (MRC), apply the KRaftMigrationJob to one region at a time and
wait for each region to complete its broker rolls before proceeding to the next. This applies
to both the migration and finalization stages.

During migration, each region's Kafka brokers are rolled multiple times. During finalization,
brokers are rolled again to remove the ZooKeeper dependency, and KRaft controllers are rolled
to remove migration configs. Since each region's operator rolls brokers independently with no
cross-region coordination, triggering multiple regions simultaneously can cause brokers holding
replicas of the same partition to restart at the same time — potentially making topics
unavailable even when the replication factor would otherwise survive a single-region restart.

### Migration procedure

1. Apply the KRaftMigrationJob CR in the first region. Monitor its status until it reaches
   the `MIGRATE` phase with subphase `MigrateMonitorMigrationProgress`. At this point, all
   broker rolls for this region are complete.
2. Repeat for each subsequent region, waiting for the same status before moving to the next.
3. Once the final region completes its broker rolls, the KRaft controllers across all regions
   will detect that all voters have registered and transition the cluster to `DUAL-WRITE` state.
4. Verify that all regions report the `DUAL-WRITE` phase before proceeding to finalization.

> **Note:** `DUAL-WRITE` is a cluster-wide state, not a per-region state. The last region to
> finish its broker rolls is the bottleneck for this transition.

### Finalization procedure

1. Trigger finalization in the first region. This removes the ZooKeeper dependency from Kafka
   brokers and the migration configuration from KRaft controllers, each requiring a roll. Wait
   for the region to reach the `COMPLETE` phase.
2. Repeat for each subsequent region, waiting for `COMPLETE` before moving to the next.

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

### Parallel migration (advanced)

If minimizing migration time is a priority and your cluster can tolerate multiple brokers
restarting simultaneously across regions, you can trigger all regions in parallel. Before
doing so, ensure:

- **KRaft quorum availability**: The KRaft controller quorum must be large enough to maintain
  a majority even when one controller per region is restarting simultaneously. In a 2-region
  deployment, you need at least 6 KRaft controllers (3 per region); in a 3-region deployment,
  you need at least 7. This ensures the quorum retains a majority even with one controller
  down in every region at the same time.
- **Topic availability**: The replication factor for all topics must be greater than the number
  of regions, and `min.insync.replicas` must be configured so that writes can continue even
  with one replica per region unavailable. For example, in a 3-region deployment, RF >= 4 with
  `min.insync.replicas` <= RF - 3 ensures that one broker restarting per region does not cause
  topic unavailability.

If either condition is not met, use the sequential one-region-at-a-time approach described
above.

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
