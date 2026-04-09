# Bidirectional Cluster Linking

This directory contains examples for setting up **Bidirectional Cluster Linking** using Confluent for Kubernetes (CFK).

> **Availability**: Bidirectional Cluster Linking is available starting **CFK 3.2.0** and **Confluent Platform 7.4+**.

## Overview

Bidirectional Cluster Linking allows data to flow in **both directions** between two Kafka clusters:
- **Forward Mirroring**: Topics from Cluster A to Cluster B
- **Reverse Mirroring**: Topics from Cluster B to Cluster A

This is achieved by creating **two ClusterLink CRs** that share the same logical link name (`spec.name`).

## Architecture

```
+-----------------------------------------------------------------------------+
|                      BIDIRECTIONAL CLUSTER LINKING                           |
+-----------------------------------------------------------------------------+
|                                                                             |
|   +---------------------+                    +---------------------+        |
|   |   SOURCE CLUSTER    |                    | DESTINATION CLUSTER |        |
|   |   (Namespace: src)  |                    |  (Namespace: dest)  |        |
|   +---------------------+                    +---------------------+        |
|   |                     |   Forward Mirror   |                     |        |
|   |  topic-a --------------------------------------------> topic-a (mirror) |
|   |                     |                    |                     |        |
|   |  topic-b (mirror) <------------------------------------------ topic-b  |
|   |                     |   Reverse Mirror   |                     |        |
|   +---------------------+                    +---------------------+        |
|   |                     |                    |                     |        |
|   |  ClusterLink CR     |<------------------>|  ClusterLink CR     |        |
|   |  (src-cluster-link) |  Same link name    |  (dest-cluster-link)|        |
|   |                     |                    |                     |        |
|   +---------------------+                    +---------------------+        |
|                                                                             |
+-----------------------------------------------------------------------------+
```

## Examples

| Example | Mode | Security | Use Case |
|---------|------|----------|----------|
| [kraft/basic](kraft/basic/) | KRaft | Plaintext | Quick start, learning, dev/test |
| [kraft/sasl-ssl](kraft/sasl-ssl/) | KRaft | SASL-SSL | Production deployment |
| [kraft/private-sasl-ssl](kraft/private-sasl-ssl/) | KRaft | SASL-SSL | Private cluster behind firewall |
| [zookeeper/basic](zookeeper/basic/) | ZooKeeper | Plaintext | Quick start for CP 7.x |
| [zookeeper/sasl-ssl](zookeeper/sasl-ssl/) | ZooKeeper | SASL-SSL | Production for CP 7.x |
| [zookeeper/private-sasl-ssl](zookeeper/private-sasl-ssl/) | ZooKeeper | SASL-SSL | Private cluster for CP 7.x |

## Key Concepts

### Standard Bidirectional vs Private Cluster

| Aspect | Standard Bidirectional | Private Cluster |
|--------|------------------------|-----------------|
| Connection Mode | Both use default (OUTBOUND) | Source: OUTBOUND, Destination: INBOUND |
| Network | Both clusters reachable | One cluster behind firewall |
| Connection Initiator | Either side | Only the "public" cluster |
| Use Case | General replication | DMZ, private networks |

### ClusterLink CR Structure

For bidirectional linking, you need **two ClusterLink CRs** with the same `spec.name`:

```yaml
# Destination-side ClusterLink (receives forward mirrors)
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: dest-cluster-link
  namespace: destination
spec:
  name: bidirectional-link          # Same link name on both sides
  sourceInitiatedLink:
    linkMode: Bidirectional         # Required for bidirectional
  destinationKafkaCluster:
    # Points to destination cluster
  sourceKafkaCluster:
    # Points to source cluster
  mirrorTopics:
    - name: forward-topic
      direction: toDestination      # Forward: source -> destination
```

```yaml
# Source-side ClusterLink (receives reverse mirrors)
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: src-cluster-link
  namespace: source
spec:
  name: bidirectional-link          # Same link name as destination
  sourceInitiatedLink:
    linkMode: Bidirectional
  # Note: Source/Destination are SWAPPED for reverse mirroring
  sourceKafkaCluster:
    # Points to destination cluster (where reverse-topic exists)
  destinationKafkaCluster:
    # Points to source cluster (where mirror is created)
  mirrorTopics:
    - name: reverse-topic
      direction: toDestination      # Reverse: destination -> source
```

## Important Gotchas and Best Practices

### 1. Link Name Must Match

Both ClusterLink CRs **must** have the same `spec.name`. This is what associates them as a bidirectional pair:

```yaml
# Correct - same spec.name
dest-cluster-link:
  spec.name: "my-bidirectional-link"
src-cluster-link:
  spec.name: "my-bidirectional-link"
```

### 2. Source/Destination Are Swapped for Reverse Mirroring

For the **source-side ClusterLink** (handling reverse mirrors), the `sourceKafkaCluster` and `destinationKafkaCluster` are **swapped** relative to the cluster namespaces:

```yaml
# Source-side ClusterLink in namespace "source"
spec:
  sourceKafkaCluster:
    # Points to "destination" cluster (where the original topic exists)
  destinationKafkaCluster:
    # Points to "source" cluster (where the mirror is created)
```

This is because the **source** of the data being mirrored is the destination cluster.

### 3. cluster.link.id Must Be Consistent

When using private clusters with INBOUND mode, the `cluster.link.id` config must be the **same** on both sides and match the source cluster's ID:

```yaml
# Both ClusterLinks must have matching cluster.link.id
spec:
  configs:
    cluster.link.id: "<source-cluster-id>"
```

### 4. Private Cluster Link Creation Order

For **private cluster** bidirectional links (INBOUND/OUTBOUND mode):

**Critical**: Both ClusterLinks must be created before either can become fully healthy.

The INBOUND (destination) link cannot establish mirror topics until the OUTBOUND (source) link initiates the connection. If you create them sequentially and wait for the first to be healthy, you'll hit a timeout.

**Correct approach:**
1. Create BOTH ClusterLink CRs
2. Wait for the OUTBOUND link to become healthy (it initiates the connection)
3. Then verify the INBOUND link becomes healthy

### 5. Do NOT Set ClusterLinkId for Bidirectional INBOUND Links

For bidirectional cluster links with `connection.mode: INBOUND`, do **not** explicitly set `ClusterLinkId` in the request. The API will return an error:

```
Unexpected cluster link id. Should not be provided for bi-directional 
cluster link with inbound connections. (40002)
```

### 6. Password Encoder Secret Required

Kafka clusters participating in cluster linking require a password encoder secret:

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  passwordEncoder:
    secretRef: password-encoder-secret
```

### 7. KafkaRestClass Required for Both Clusters

Both source and destination clusters need a `KafkaRestClass` for the ClusterLink to communicate:

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: src-rest
  namespace: source
spec:
  kafkaClusterRef:
    name: kafka
    namespace: source
```

### 8. Inter-Broker Protocol Version for ZooKeeper Mode

For ZooKeeper-based clusters, bidirectional linking requires `inter.broker.protocol.version=3.1` or higher:

```yaml
spec:
  configOverrides:
    server:
      - inter.broker.protocol.version=3.1
```

### 9. Local Authentication for SASL-SSL Clusters

For **bidirectional cluster links** on SASL-SSL clusters, you **must** provide `destinationKafkaCluster.authentication` to generate `local.*` configs. According to the [Confluent documentation](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/configs.html#advanced-options-for-bidirectional-cluster-linking):

- **`sasl.jaas.config`** - Authenticates to the **remote** cluster (from `sourceKafkaCluster.authentication`)
- **`local.sasl.jaas.config`** - Authenticates to the **local** cluster (from `destinationKafkaCluster.authentication`)

```yaml
# For OUTBOUND mode bidirectional links (standard mode)
spec:
  sourceKafkaCluster:
    authentication: ...  # generates sasl.jaas.config for REMOTE cluster
  destinationKafkaCluster:
    authentication: ...  # generates local.sasl.jaas.config for LOCAL cluster (REQUIRED!)
```

**Exception**: For **INBOUND mode** links (private cluster), only `link.mode=BIDIRECTIONAL` and `connection.mode=INBOUND` are needed. The INBOUND link is passive and doesn't require authentication configs.

> **Note**: KRaft mode automatically uses metadata.version >= 3.3-IV0, so this is not required.

### 10. Consumer Offset Sync Considerations

When enabling consumer offset sync (`consumer.offset.sync.enable: true`):
- Consumer groups must exist on both clusters
- Offsets are synced periodically (not real-time)
- Consider the sync interval for your RPO requirements

### 11. ACL Sync with RBAC

When using ACL sync (`acl.sync.enable: true`) with RBAC:
- Ensure proper rolebindings exist on both clusters
- ACL sync only works with Kafka ACLs, not RBAC rolebindings

## Prerequisites

1. **CFK 3.2.0+** installed
2. **Confluent Platform 7.4+** (or 8.0+ for KRaft-only)
3. Two Kubernetes namespaces for source and destination clusters
4. Network connectivity between namespaces (or use private cluster mode)

## Troubleshooting

### ClusterLink Stuck in "Creating" State

1. Check if both clusters are healthy:
   ```bash
   kubectl get kafka -A
   ```

2. Check KafkaRestClass status:
   ```bash
   kubectl get kafkarestclass -A -o yaml
   ```

3. For private clusters, ensure OUTBOUND link is created first

### Mirror Topics Not Syncing

1. Verify the link is active:
   ```bash
   kubectl get clusterlink -A -o yaml | grep -A5 status
   ```

2. Check if source topic exists and has data

3. Verify network connectivity between clusters

### "Timed out waiting for node assignment" Error

This occurs when the INBOUND link cannot reach the source cluster. For private clusters:
- Ensure the OUTBOUND link is created and healthy
- Verify the source cluster's bootstrap endpoint is correct

## References

- [Confluent Documentation: Bidirectional Cluster Linking](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/configs.html#bidirectional-mode)
- [Advanced Options for Bidirectional Cluster Linking](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/configs.html#advanced-options-for-bidirectional-cluster-linking)
- [CFK ClusterLink API Reference](https://docs.confluent.io/operator/current/co-api.html#tag/ClusterLink)
