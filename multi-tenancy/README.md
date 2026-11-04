# Multi-Tenancy

Multi-Tenancy in Confluent Private Cloud runs many isolated Logical Kafka Clusters (LKCs) on one shared Physical Kafka Cluster (PKC). Each LKC has its own topics, consumer groups, access control, quotas, and limits.

For concepts and production guidance, see [Multi-Tenancy Overview](https://docs.confluent.io/platform/current/private-cloud/multi-tenancy/overview.html).

| Example | What it shows |
|---|---|
| [quickstart](quickstart/) | Deploy a PKC on kind, create two LKCs, and check that each LKC admin sees only their own LKC. |

## Versions

| Component | Minimum version |
|---|---|
| Confluent for Kubernetes | 3.4.0 |
| Confluent Platform | 8.4.0 |
| Control Center (next-gen) | 2.7.0 |
