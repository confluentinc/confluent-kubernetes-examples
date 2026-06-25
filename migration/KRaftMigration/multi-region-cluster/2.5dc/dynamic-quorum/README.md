# 2.5DC KRaft Migration with Dynamic Quorum (KIP-853)

Example YAMLs for migrating a 2.5DC multi-region cluster from ZooKeeper to KRaft
using dynamic quorum (KIP-853). Requires CFK 3.3.0+ and CP 7.9.6+.

> **This is the recommended target for 2.5DC migrations.** Dynamic quorum enables
> `add-controller` / `remove-controller` and `force-standalone` disaster recovery (static quorum
> cannot `remove-controller`), and during migration the bootstrap voter forms the quorum on its
> own — so quorum formation does not wait for a cross-region voter majority, avoiding the
> static-quorum minority-region wedge. See the
> [2.5DC migration overview](../README.md#recommended-target-kraft-with-dynamic-quorum-kip-853).

This example is **plaintext** (no security) and includes 2.5DC-specific resources: lite-mode
KMJ for the 0.5DC, KRaftController with manual `clusterID`, and the tiebreaker topology. For
the secured variant of admin commands (`--command-config`, admin.properties creation), see the
[secured dynamic quorum MRC migration](../../../../../kraft/dynamic-quorum/migration/zk-to-kraft/mrc/).

## How dynamic quorum differs from static quorum

In static quorum, all KRaft controllers start as voters with a fixed
`controllerQuorumVoters` list. In dynamic quorum:

- **One controller is the bootstrap voter** (`bootstrapPod: 0` on DC1 KRC).
  It starts the quorum standalone.
- **All other controllers start as observers.** They join the quorum but
  cannot vote until promoted.
- **Observers are promoted to voters** during DUAL-WRITE using
  `kafka-metadata-quorum --bootstrap-controller <endpoint> add-controller`.

## Key configuration

All KRaftControllers require:
- `dynamicQuorumConfig.enabled: true`
- `advertisedListenersEnabled: true` — without this, voters advertise internal
  `svc.cluster.local` addresses and cross-cluster `add-controller` fails
- `controllerQuorumVoters` listing ALL controllers across all DCs — the migration
  driver needs the full list to know the expected quorum size

Only the bootstrap voter (DC1 kraft-east) has:
- `dynamicQuorumConfig.bootstrapPod: 0`
- `podTemplate.serviceAccountName: kraftcontroller-sa` (for bootstrap ConfigMap access)

## Bootstrap resources (DC1 only)

The `bootstrap/` directory contains resources needed only in the bootstrap voter's namespace:
- `bootstrap-configmap.yaml` — tracks whether the bootstrap voter has completed initial
  formatting. The init container reads this to decide between `--standalone` (first time)
  and `--no-initial-controllers` (rejoining).
- `rbac.yaml` — ServiceAccount and RoleBinding for the bootstrap voter pod to read/update
  the ConfigMap.

## Migration steps

1. Deploy ZooKeeper (all 3 DCs) and Kafka (DC1 + DC2)
2. Deploy bootstrap ConfigMap + RBAC in DC1 namespace
3. Fetch `clusterID` from Kafka broker and set on the 0.5DC KRaftController
4. Deploy KRaftControllers in all 3 DCs
5. Deploy KRaftMigrationJobs — apply the bootstrap voter's region (DC1) + the 0.5DC
   tiebreaker (central, lite mode, no brokers) together, then wait for DC1 to reach the
   `MIGRATE` phase with subphase `MigrateMonitorMigrationProgress` (all broker rolls in DC1
   complete) before applying DC2. The 0.5DC has no Kafka, so it never rolls brokers — applying
   it alongside DC1 is safe. This keeps only one broker-bearing region rolling at a time. See
   the [MRC migration sequencing](../README.md#mrc-migration-sequencing) section for details.
6. Wait for all regions to reach `DUAL-WRITE`
7. **Promote observers to voters (during DUAL-WRITE).** Run `add-controller` on each
   observer pod — it promotes the controller it is run on. Skip `kraftcontroller-east-0`
   (already a voter). Point `--bootstrap-controller` at the bootstrap voter's external DNS.
   No `--command-config` is needed for plaintext. For secured clusters, pass
   `--command-config /opt/confluentinc/etc/kafka/kafka-client.properties` (CFK 3.3.x+) — see
   the [secured MRC example](../../../../../kraft/dynamic-quorum/migration/zk-to-kraft/mrc/#step-6-promote-observers-to-voters-dual_write).

   ```bash
   BOOTSTRAP=<bootstrap-voter-external-dns>:9074

   kubectl --context $CTX_EAST    exec kraftcontroller-east-1    -n east    -- \
     kafka-metadata-quorum --bootstrap-controller $BOOTSTRAP add-controller
   kubectl --context $CTX_WEST    exec kraftcontroller-west-0    -n west    -- \
     kafka-metadata-quorum --bootstrap-controller $BOOTSTRAP add-controller
   kubectl --context $CTX_WEST    exec kraftcontroller-west-1    -n west    -- \
     kafka-metadata-quorum --bootstrap-controller $BOOTSTRAP add-controller
   kubectl --context $CTX_CENTRAL exec kraftcontroller-central-0 -n central -- \
     kafka-metadata-quorum --bootstrap-controller $BOOTSTRAP add-controller
   ```

   Verify all controllers are now voters:
   ```bash
   kubectl --context $CTX_EAST exec kraftcontroller-east-0 -n east -- \
     kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --replication
   ```
8. Finalize migration **one region at a time** — trigger finalization in the first region
   and wait for it to reach `COMPLETE` before proceeding to the next.
9. Release CR locks and clean up ZooKeeper

## Files

```
dynamic-quorum/
├── bootstrap/
│   ├── bootstrap-configmap.yaml    # Bootstrap tracking ConfigMap (DC1 only)
│   └── rbac.yaml                   # ServiceAccount + RoleBinding (DC1 only)
├── zookeeper/
│   ├── zookeeper-east.yaml         # DC1 ZK
│   ├── zookeeper-west.yaml         # DC2 ZK
│   └── zookeeper-central.yaml      # 0.5DC ZK (tiebreaker)
├── kafka/
│   ├── kafka-east.yaml             # DC1 Kafka
│   └── kafka-west.yaml             # DC2 Kafka (no central — 0.5DC has no Kafka)
├── kraft/
│   ├── kraft-east.yaml             # DC1 KRC — bootstrap voter (bootstrapPod: 0)
│   ├── kraft-west.yaml             # DC2 KRC — observer
│   └── kraft-central.yaml          # 0.5DC KRC — observer, lite mode
└── migration/
    ├── migration-east.yaml         # DC1 KMJ — full mode
    ├── migration-west.yaml         # DC2 KMJ — full mode
    └── migration-central.yaml      # 0.5DC KMJ — lite mode (no kafka dependency)
```
