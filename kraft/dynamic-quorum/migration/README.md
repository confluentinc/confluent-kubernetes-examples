## Migration Examples

Two separate migration paths for enabling dynamic quorum. These are independent -- do not mix them.

### Static KRaft to Dynamic KRaft

For clusters already running KRaft with static quorum (`kraft.version=0`).
Migrates to dynamic quorum (`kraft.version=1`). Requires **CP 8.0+**.

No bootstrapPod, ConfigMap, or RBAC needed -- the cluster is already formatted.

| Example | Description |
|---------|-------------|
| [Quickstart](static-to-dynamic/quickstart/) | Single-cluster migration (no security) |
| [MRC (Secured)](static-to-dynamic/mrc/) | True multi-cluster MRC migration with TLS + SASL/PLAIN + OAuth + RBAC |

### ZooKeeper to KRaft (with Dynamic Quorum)

For clusters running ZooKeeper that need to migrate directly to KRaft with dynamic quorum (`kraft.version=1`).
Requires bootstrapPod, ConfigMap, RBAC for initial cluster formatting.

| Example | Description |
|---------|-------------|
| [Quickstart](zk-to-kraft/quickstart/) | Single-cluster ZK to KRaft migration (no security) |
| [MRC (Secured)](zk-to-kraft/secured/) | True multi-cluster MRC ZK to KRaft migration with full security |

**Note**: These examples migrate to KRaft with dynamic quorum (`kraft.version=1`). If you want to migrate to KRaft with static quorum (`kraft.version=0`), refer to the [KRaftMigrationJob examples in the confluent-kubernetes-examples repo](https://github.com/confluentinc/confluent-kubernetes-examples).
