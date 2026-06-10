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
2. Deploy KRaftMigrationJobs in all 3 DCs (lite-mode for 0.5DC, full-mode for DC1/DC2)
3. Monitor migration to DUAL-WRITE (0.5DC completes faster — no Kafka to roll)
4. For dynamic quorum: promote observer KRCs to voters during DUAL-WRITE
5. Finalize migration on all 3 DCs
6. Release CR locks and clean up ZooKeeper

Refer to the [CFK documentation](https://docs.confluent.io/operator/current/co-migrate-kraft-procedure.html)
for the full step-by-step procedure.

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
