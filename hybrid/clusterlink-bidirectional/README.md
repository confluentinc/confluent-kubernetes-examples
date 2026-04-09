# Bidirectional Cluster Linking

This directory contains examples for setting up **Bidirectional Cluster Linking** using Confluent for Kubernetes (CFK).

## Version Compatibility

| Feature | CP Version | CFK Version |
|---------|-----------|-------------|
| Unidirectional (destination-initiated + source-initiated) | All active versions | All active versions |
| Bidirectional (outbound-outbound + outbound-inbound) | CP 7.5+ | CFK 3.2+ |

## Overview

Bidirectional Cluster Linking allows data to flow in **both directions** between two Kafka clusters:
- Topics from onprem-1 are mirrored to onprem-2
- Topics from onprem-2 are mirrored to onprem-1

This is achieved by creating **two ClusterLink CRs** that share the same logical link name (`spec.name`).

## Architecture

```
+-----------------------------------------------------------------------------+
|                      BIDIRECTIONAL CLUSTER LINKING                          |
+-----------------------------------------------------------------------------+
|                                                                             |
|   +---------------------+                    +---------------------+        |
|   |    ONPREM-1         |                    |    ONPREM-2         |        |
|   +---------------------+                    +---------------------+        |
|   |                     |                    |                     |        |
|   |  topic-a  ---------------------------------->  topic-a (mirror)|        |
|   |  (original)         |   data flows       |                     |        |
|   |                     |   BOTH ways        |  topic-b            |        |
|   |  topic-b (mirror) <----------------------------------  (original)       |
|   |                     |                    |                     |        |
|   +---------------------+                    +---------------------+        |
|   |                     |                    |                     |        |
|   |  ClusterLink CR     |<=================>|  ClusterLink CR      |        |
|   |  (cluster-link-a)   |  Same link name    |  (cluster-link-b)   |        |
|   |                     |                    |                     |        |
|   +---------------------+                    +---------------------+        |
|                                                                             |
|   CR needed on BOTH clusters. Mirror topics can use toDestination (pull)    |
|   or toSource (push) on either side.                                        |
+-----------------------------------------------------------------------------+
```

---

## Cluster Setup

All examples in this guide use a consistent set of 3 clusters:

| Cluster | K8s Cluster | Bootstrap | KafkaRestClass | Network |
|---------|-------------|-----------|----------------|---------|
| onprem-1 | k8s-onprem-1 | `onprem-1:9092` | `rest-onprem-1` | Behind firewall — only onprem-2 can reach in. Cloud cannot. |
| onprem-2 | k8s-onprem-2 | `onprem-2:9092` | `rest-onprem-2` | Behind firewall — only onprem-1 can reach in. Cloud cannot. |
| cloud | k8s-cloud | `cloud:9092` | `rest-cloud` | Open — reachable by onprem-1 and onprem-2. |

**Network constraints:**
- onprem-1 <-> onprem-2: both reachable
- onprem-1 -> cloud: reachable
- onprem-2 -> cloud: reachable
- cloud -> onprem-1: BLOCKED (firewall)
- cloud -> onprem-2: BLOCKED (firewall)

---

## Quick Decision Guide

Use this flowchart to determine which mode you need:

```
+-------------------------------------+
| Do you need bidirectional traffic?  |
+--------+--------------------+-------+
         |                    |
        NO                   YES
         |                    |
         v                    v
  +--------------+     +--------------+
  | Is source    |     | Can both     |
  | firewalled?  |     | clusters     |
  +--+--------+--+     | reach each   |
     |        |        | other?       |
    YES      NO        +--+--------+--+
     |        |           |        |
     |        |          YES      NO
     |        |           |        |
     v        v           v        v
  Case 2    Case 1     Case 3        Case 4
  Source-   Dest-      Bidir         Bidir
  Initiated Initiated  (Outbound-   (Outbound-
            (Simple)    Outbound)     Inbound)
```

**Quick Selection:**
- **Case 1**: Unidirectional, data source cluster reachable — onprem-1 pulls from cloud
- **Case 2**: Unidirectional, one cluster firewalled — firewalled cluster pushes out
- **Case 3**: Bidirectional, both clusters reachable — each initiates its own connection (outbound-outbound)
- **Case 4**: Bidirectional, one cluster firewalled — reachable cluster starts listening, firewalled cluster sends connection (outbound-inbound)

---

## Understanding the Field Names

### Critical Concept: sourceKafkaCluster vs destinationKafkaCluster

These names are **confusing** because they come from the unidirectional model. Here's what they actually mean:

| Field Name | What It Actually Means |
|------------|------------------------|
| `destinationKafkaCluster` | **Local cluster** where this CR is deployed and the link is created |
| `sourceKafkaCluster` | **Remote cluster** this link connects to |

**Exception:** In Source mode (Case 2), these fields are **FLIPPED**!

> Think of them as: `destinationKafkaCluster` as `localKafkaCluster` and `sourceKafkaCluster` as `remoteKafkaCluster` for clarity, especially in bidirectional setups.

### The Golden Rule for Credentials

**You always provide credentials of the cluster you're connecting TO.**

- If A connects to B -> use `creds-b`

---

## Understanding KafkaRestClass

A `KafkaRestClass` is a Kubernetes CR that tells CFK how to reach a Kafka cluster's REST API.

**Key Points:**
- Lives on the **local** K8s cluster
- You **cannot** reference a KafkaRestClass from another K8s cluster
- For the **local** cluster: points to local Kafka CR
- For **remote** clusters (bidirectional only): create a local KafkaRestClass with the remote cluster's REST endpoint and REST credentials

**Local KafkaRestClass (on k8s-onprem-1):**
```yaml
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: rest-onprem-1
spec:
  kafkaClusterRef:
    name: kafka  # Points to local Kafka CR
```

**Remote KafkaRestClass for bidirectional (on k8s-onprem-1, pointing to onprem-2):**
```yaml
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: rest-for-onprem-2
spec:
  kafkaRest:
    endpoint: https://onprem-2-rest.example.com:8090
    # Add authentication if onprem-2's REST API requires it
```

> For unidirectional links: You can skip remote KafkaRestClass by setting `clusterID` directly

---

## Examples

### Single-Cluster (cross-namespace)

| Example | Mode | Security | Use Case |
|---------|------|----------|----------|
| [kraft/basic](kraft/basic/) | KRaft | Plaintext | Quick start, learning, dev/test |
| [kraft/sasl-ssl](kraft/sasl-ssl/) | KRaft | SASL-SSL | Production deployment (same K8s cluster) |
| [kraft/private-sasl-ssl](kraft/private-sasl-ssl/) | KRaft | SASL-SSL | Private cluster behind firewall (same K8s cluster) |
| [zookeeper/basic](zookeeper/basic/) | ZooKeeper | Plaintext | Quick start for CP 7.x |
| [zookeeper/sasl-ssl](zookeeper/sasl-ssl/) | ZooKeeper | SASL-SSL | Production for CP 7.x |
| [zookeeper/private-sasl-ssl](zookeeper/private-sasl-ssl/) | ZooKeeper | SASL-SSL | Private cluster for CP 7.x |

### Multi-Cluster (true cross-cluster, tested on 2 GKE clusters)

| Example | Mode | Security | Use Case |
|---------|------|----------|----------|
| [kraft/multi-cluster-sasl-ssl](kraft/multi-cluster-sasl-ssl/) (outbound-outbound) | KRaft, both OUTBOUND | SASL-SSL + REST HTTPS | Both clusters reachable, different creds per cluster |
| [kraft/multi-cluster-sasl-ssl](kraft/multi-cluster-sasl-ssl/) (outbound-inbound) | KRaft, OUTBOUND+INBOUND | SASL-SSL + REST HTTPS | One cluster behind firewall |

The multi-cluster example uses shared infra (KRaft + Kafka) with case-specific ClusterLink configs. Run `./setup.sh outbound-outbound` or `./setup.sh outbound-inbound` to deploy either case.

---

## The Four Modes

### Case 1: Destination-Initiated Unidirectional

**Scenario:** onprem-1 wants data from cloud. Both clusters reachable. onprem-1 pulls from cloud.

```
+------------------------------------------------------------------------+
|                         CASE 1: SIMPLE PULL                            |
|                    (Destination-Initiated, Both Reachable)             |
+------------------------------------------------------------------------+

   +---------------------+                    +----------------------+
   |   cloud             |                    |  onprem-1            |
   |   (k8s-cloud)       |                    |  (k8s-onprem-1)      |
   |                     |                    |                      |
   | - Has: cloud-events |                    | - Wants: cloud-events|
   | - Bootstrap:        |                    | - Bootstrap:         |
   |   cloud:9092        |                    |   onprem-1:9092      |
   | - Network: Open     |                    | - Network: Open      |
   +----------+----------+                    +----------+-----------+
              |                                          |
              |     ======== DATA FLOW =========>        |
              |                                          |
              |     <------- PULL REQUEST ------         |
              |                                          |
              |                                  +-------v----------+
              |                                  | ClusterLink CR   |
              |                                  | Name: link-...   |
              |                                  | Deploy: HERE     |
              |                                  | Mode: DESTINATION|
              +----------------------------------+ Connection: OUT  |
                                                 +------------------+

Key Points:
- onprem-1 reaches out to cloud (OUTBOUND connection)
- onprem-1 pulls data using cloud's credentials
- Only 1 CR deployed on onprem-1
- Most common and simplest scenario
```

**Characteristics:**
- Simplest setup
- Only 1 CR (on onprem-1, the destination)
- onprem-1 pulls data from cloud
- Most common scenario

<details>
<summary><b>Full YAML Configuration</b></summary>

```yaml
# Deploy on: k8s-onprem-1
# Data flow: cloud -> onprem-1
# onprem-1 reaches out to cloud and pulls data
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-cloud-to-onprem-1
spec:
  # --- Remote cluster (cloud) ---
  sourceKafkaCluster:
    bootstrapEndpoint: cloud:9092        # onprem-1 connects here to pull data
    clusterID: cloud-cluster-id          # cloud's cluster ID
    authentication:
      type: plain
      jaasConfig:
        secretRef: cloud-creds           # onprem-1 authenticates TO cloud, needs cloud's creds
    tls:
      enabled: true
      secretRef: tls-cloud              # TLS to connect to cloud

  # --- Local cluster (onprem-1) ---
  destinationKafkaCluster:
    kafkaRestClassRef:
      name: rest-onprem-1               # Manages the link on onprem-1 via REST API

  mirrorTopics:
    - name: cloud-events                 # Topic to mirror from cloud
```

</details>

**Field Breakdown:**

| Field | Value | Why |
|-------|-------|-----|
| `source.bootstrapEndpoint` | `cloud:9092` | onprem-1 connects to cloud's brokers for data replication |
| `source.clusterID` | `cloud-cluster-id` | cloud's cluster ID — required since cloud is on different K8s cluster |
| `source.authentication` | `cloud-creds` | onprem-1 is connecting TO cloud — needs creds cloud accepts |
| `source.tls` | `tls-onprem-1` | TLS certs for connecting to onprem-1 |
| `dest.kafkaRestClassRef` | `rest-onprem-1` | Manages the link on onprem-1 (create link, mirror topics, etc.) |
| `dest.authentication` | not needed | onprem-1 doesn't authenticate to itself |
| `link.mode` | _(defaults to DESTINATION)_ | |
| `connection.mode` | _(defaults to OUTBOUND)_ | |

---

### Case 2: Source-Initiated Unidirectional

**Scenario:** onprem-1 has data, cloud wants it, but cloud **cannot reach onprem-1** (firewall). onprem-1 must push.

```
+------------------------------------------------------------------------+
|                     CASE 2: FIREWALL PUSH                              |
|              (Source-Initiated, Cloud Cannot Reach OnPrem)             |
+------------------------------------------------------------------------+

   +---------------------+                    +---------------------+
   |   onprem-1          |                    |   cloud             |
   |   (k8s-onprem-1)    |                    |   (k8s-cloud)       |
   |                     |                    |                     |
   | - Has: orders       |                    | - Wants: orders     |
   | - Network: PRIVATE  |                    | - Network: OPEN     |
   +----------+----------+                    +----------+----------+
              |                                          |
              |                                  +-------v----------+
              |                                  | STEP 1: Create   |
              |                                  | ClusterLink CR   |
              |                                  | Mode: DESTINATION|
              |                                  | Connection: IN   |
              |                                  | PASSIVE!         |
              |                                  | mirrorTopics: Y  |
              |                                  +------------------+
              |                                          |
   +----------v----------+                              |
   | STEP 2: Create      |                              |
   | ClusterLink CR      |                              |
   | Mode: SOURCE        |                              |
   | Connection: OUTBOUND+------------------------------+
   |                     |                              |
   | FLIPPED FIELDS!     |                              |
   | source = LOCAL      |                              |
   | dest = REMOTE       |                              |
   +---------------------+                              |
              |                                          |
              |     ======== DATA FLOW =========>        |
              |     -------- PUSH (OUTBOUND) ------->    |
              |                                          |
      FIREWALL BLOCKS
      INBOUND TRAFFIC
              ^
              |
      Cloud cannot reach
      onprem-1's Kafka brokers

Key Points:
- 2 CRs required with matching spec.name
- Creation order matters:
  1. Destination CR (INBOUND, on cloud) — created FIRST, passive
  2. Source CR (OUTBOUND, on onprem-1) — created SECOND, initiates connection
- onprem-1 initiates connection outbound to cloud and pushes data
- Source CR has FLIPPED field semantics (source=local, dest=remote)
- mirrorTopics ONLY on Destination CR, NOT on Source CR
- spec.name MUST match between both CRs (metadata.name can differ)
```

**Characteristics:**
- Requires **2 CRs** (one on each cluster)
- Field names are **FLIPPED** on Source mode CR
- `mirrorTopics` go on Destination CR, **NOT** Source CR
- `onprem-1` initiates connection and pushes data to `cloud`

#### CR on OnPrem-1 (Source Mode)

<details>
<summary><b>Source Mode CR Configuration</b></summary>

```yaml
# Deploy on: k8s-onprem-1 (behind firewall)
# onprem-1 initiates connection to cloud and pushes data
#
# FLIPPED: In Source mode, source=local and destination=remote
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-onprem-1-source
spec:
  name: link-onprem-1-to-cloud           # MUST match on both CRs
  sourceInitiatedLink:
    linkMode: Source

  # --- Local cluster (onprem-1) -- FLIPPED: source=local in Source mode ---
  sourceKafkaCluster:
    kafkaRestClassRef:
      name: rest-onprem-1                # Manages the link on onprem-1
    authentication:
      type: plain
      jaasConfig:
        secretRef: onprem-1-creds        # Becomes local.* configs -- cloud reads from onprem-1 using these
    tls:
      enabled: true
      secretRef: tls-onprem-1            # Becomes local.* TLS

  # --- Remote cluster (cloud) -- FLIPPED: destination=remote in Source mode ---
  destinationKafkaCluster:
    bootstrapEndpoint: cloud:9092        # onprem-1 connects here to push data
    clusterID: cloud-cluster-id          # cloud's cluster ID (cross-K8s)
    authentication:
      type: plain
      jaasConfig:
        secretRef: cloud-creds           # onprem-1 authenticates TO cloud
    tls:
      enabled: true
      secretRef: tls-cloud               # TLS to connect to cloud

  # mirrorTopics NOT allowed on Source mode CR -- define them on Destination CR
```

</details>

**Field Breakdown (Source CR):**

| Field | Value | Why |
|-------|-------|-----|
| `source.kafkaRestClassRef` | `rest-onprem-1` | **Source mode: source=local** -- manages link on onprem-1 |
| `source.authentication` | `onprem-1-creds` | Becomes `local.*` configs -- cloud reads from onprem-1 over reverse connection |
| `source.tls` | `tls-onprem-1` | Becomes `local.*` TLS |
| `dest.bootstrapEndpoint` | `cloud:9092` | **Source mode: dest=remote** -- onprem-1 connects to cloud |
| `dest.clusterID` | `cloud-cluster-id` | cloud's cluster ID (cross-K8s) |
| `dest.authentication` | `cloud-creds` | onprem-1 authenticates TO cloud |
| `dest.tls` | `tls-cloud` | TLS for connecting to cloud |
| `link.mode` | `SOURCE` | |
| `connection.mode` | `OUTBOUND` | |
| `mirrorTopics` | not allowed here | Must be on Destination mode CR |

#### CR on Cloud (Destination Mode)

<details>
<summary><b>Destination Mode CR Configuration</b></summary>

```yaml
# Deploy on: k8s-cloud (public)
# cloud is passive -- waits for onprem-1 to connect
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-cloud-dest
spec:
  name: link-onprem-1-to-cloud           # MUST match Source CR

  sourceInitiatedLink:
    linkMode: Destination

  # --- Remote cluster (onprem-1) -- can't reach it ---
  sourceKafkaCluster:
    clusterID: onprem-1-cluster-id       # REQUIRED -- cloud can't reach onprem-1 to discover it

  # --- Local cluster (cloud) ---
  destinationKafkaCluster:
    kafkaRestClassRef:
      name: rest-cloud                   # Manages the link on cloud

  # mirrorTopics go HERE, not on Source CR
  mirrorTopics:
    - name: orders                       # Topic to mirror from onprem-1
```

</details>

**Field Breakdown (Destination CR):**

| Field | Value | Why |
|-------|-------|-----|
| `source.clusterID` | `onprem-1-cluster-id` | Required -- cloud can't reach onprem-1 to discover it |
| `source.bootstrapEndpoint` | not needed | cloud is passive (INBOUND), never dials out |
| `source.kafkaRestClassRef` | not needed | Can't reach onprem-1 |
| `source.authentication` | not needed | cloud doesn't connect to onprem-1 |
| `dest.kafkaRestClassRef` | `rest-cloud` | Manages the link on cloud |
| `dest.authentication` | not needed | cloud doesn't authenticate to itself |
| `link.mode` | `DESTINATION` | |
| `connection.mode` | `INBOUND` | |
| `mirrorTopics` | defined here | Source mode CR can't have mirror topics |

---

### Case 3: Bidirectional (Outbound-Outbound)

**Scenario:** onprem-1 and onprem-2 both want each other's data, both reachable

```
+------------------------------------------------------------------------+
|                   CASE 3: BIDIRECTIONAL (OUTBOUND-OUTBOUND)            |
|              (Both clusters reachable, each initiates own connection)  |
+------------------------------------------------------------------------+

   +------------------------+                    +------------------------+
   |   onprem-1             |                    |   onprem-2             |
   |   (k8s-onprem-1)       |                    |   (k8s-onprem-2)       |
   |                        |                    |                        |
   | - Has: onprem-1-topic  |                    | - Has: onprem-2-topic  |
   | - Wants: onprem-2-topic|                    | - Wants: onprem-1-topic|
   | - Bootstrap:           |                    | - Bootstrap:           |
   |   onprem-1:9092        |                    |   onprem-2:9092        |
   | - Cluster ID:          |                    | - Cluster ID:          |
   |   onprem-1-cluster-id  |                    |   onprem-2-cluster-id  |
   | - Network: Open        |                    | - Network: Open        |
   +----------+-------------+                    +-------+----------------+
              |                                          |
   +----------v----------+                     +---------v-------------+
   | ClusterLink CR      |                     | ClusterLink CR        |
   | Name: link-on-onprem-1|                   | Name: link-on-onprem-2|
   | spec.name: bidir-link|<---+       +-----> | spec.name: bidir-link |
   | Deploy: HERE        |     |       |       | Deploy: HERE          |
   | Mode: BIDIRECTIONAL |     |       |       | Mode: BIDIRECTIONAL   |
   | Connection: OUTBOUND|     |       |       | Connection: OUTBOUND  |
   | mirrorTopics:       |     |       |       | mirrorTopics:         |
   |   - onprem-2-topic  |     |       |       |   - onprem-1-topic    |
   +---------------------+     |       |       +-----------------------+
              |                |       |                  |
              |   Connection 1 |       | Connection 2     |
              |   (onprem-1->2)|       | (onprem-2->1)    |
              |                |       |                  |
              +----------------+-------+------------------+
                     ==== onprem-1-topic data ========>
                     <======= onprem-2-topic data =====

Key Points:
- Each cluster has its own CR with connection.mode = OUTBOUND
- onprem-1 pulls onprem-2-topic FROM onprem-2 (using onprem-2-creds)
- onprem-2 pulls onprem-1-topic FROM onprem-1 (using onprem-1-creds)
- spec.name MUST match on both CRs ("bidir-link" in this example)
- Each cluster needs a KafkaRestClass pointing to the OTHER cluster's REST API
```

**Characteristics:**
- 2 CRs with same `spec.name`
- Both connections are OUTBOUND (each pulls from the other)
- Each CR independently manages its own pull
- Requires KafkaRestClass for both remote clusters

#### Prerequisites

Create these KafkaRestClass CRs **first**:

```yaml
# On k8s-onprem-1: points to onprem-2's REST API
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: rest-for-onprem-2
spec:
  kafkaRest:
    endpoint: https://onprem-2-rest.example.com:8090
---
# On k8s-onprem-2: points to onprem-1's REST API
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: rest-for-onprem-1
spec:
  kafkaRest:
    endpoint: https://onprem-1-rest.example.com:8090
```

#### CR on onprem-1

<details>
<summary><b>CR on onprem-1 Configuration</b></summary>

```yaml
# Deploy on: k8s-onprem-1
# onprem-1 reaches out to onprem-2 and pulls data
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-on-onprem-1
spec:
  name: bidirectional-link               # MUST match on both CRs

  sourceInitiatedLink:
    linkMode: Bidirectional

  # --- Remote cluster (onprem-2) ---
  sourceKafkaCluster:
    bootstrapEndpoint: onprem-2:9092     # onprem-1 connects here
    clusterID: onprem-2-cluster-id       # onprem-2's cluster ID
    kafkaRestClassRef:
      name: rest-for-onprem-2            # Local KafkaRestClass pointing to onprem-2's REST API
    authentication:
      type: plain
      jaasConfig:
        secretRef: onprem-2-creds        # onprem-1 authenticates TO onprem-2

  # --- Local cluster (onprem-1) ---
  destinationKafkaCluster:
    kafkaRestClassRef:
      name: rest-onprem-1                # Manages the link on onprem-1
    # NO authentication needed -- onprem-2 has its own CR to connect to onprem-1

  mirrorTopics:
    - name: onprem-2-topic               # Topics onprem-1 wants from onprem-2
```

</details>

**Field Breakdown (onprem-1):**

| Field | Value | Why |
|-------|-------|-----|
| `source.bootstrapEndpoint` | `onprem-2:9092` | onprem-1 connects to onprem-2 for data replication |
| `source.clusterID` | `onprem-2-cluster-id` | onprem-2's cluster ID |
| `source.kafkaRestClassRef` | `rest-for-onprem-2` | Local KafkaRestClass with explicit endpoint to onprem-2's REST API |
| `source.authentication` | `onprem-2-creds` | onprem-1 authenticates TO onprem-2 -- needs onprem-2's creds |
| `dest.kafkaRestClassRef` | `rest-onprem-1` | Manages the link on onprem-1 |
| `dest.authentication` | not needed | onprem-2 has its own CR with `onprem-1-creds` to connect to onprem-1 |
| `link.mode` | `BIDIRECTIONAL` | |
| `connection.mode` | `OUTBOUND` (default) | |

#### CR on onprem-2

<details>
<summary><b>CR on onprem-2 Configuration</b></summary>

```yaml
# Deploy on: k8s-onprem-2
# onprem-2 reaches out to onprem-1 and pulls data
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-on-onprem-2
spec:
  name: bidirectional-link               # MUST match

  sourceInitiatedLink:
    linkMode: Bidirectional

  # --- Remote cluster (onprem-1) ---
  sourceKafkaCluster:
    bootstrapEndpoint: onprem-1:9092     # onprem-2 connects here
    clusterID: onprem-1-cluster-id       # onprem-1's cluster ID
    kafkaRestClassRef:
      name: rest-for-onprem-1            # Local KafkaRestClass pointing to onprem-1's REST API
    authentication:
      type: plain
      jaasConfig:
        secretRef: onprem-1-creds        # onprem-2 authenticates TO onprem-1

  # --- Local cluster (onprem-2) ---
  destinationKafkaCluster:
    kafkaRestClassRef:
      name: rest-onprem-2                # Manages the link on onprem-2
    # NO authentication needed -- onprem-1 has its own CR

  mirrorTopics:
    - name: onprem-1-topic               # Topics onprem-2 wants from onprem-1
```

</details>

**Field Breakdown (onprem-2):**

| Field | Value | Why |
|-------|-------|-----|
| `source.bootstrapEndpoint` | `onprem-1:9092` | onprem-2 connects to onprem-1 |
| `source.clusterID` | `onprem-1-cluster-id` | onprem-1's cluster ID |
| `source.kafkaRestClassRef` | `rest-for-onprem-1` | Local KafkaRestClass with explicit endpoint to onprem-1's REST API |
| `source.authentication` | `onprem-1-creds` | onprem-2 authenticates TO onprem-1 |
| `dest.kafkaRestClassRef` | `rest-onprem-2` | Manages the link on onprem-2 |
| `dest.authentication` | not needed | onprem-1 has its own CR |
| `link.mode` | `BIDIRECTIONAL` | |
| `connection.mode` | `OUTBOUND` (default) | |

---

### Case 4: Bidirectional (Outbound-Inbound)

**Scenario:** onprem-1 and cloud both want each other's data, cloud can't reach onprem-1

```
+------------------------------------------------------------------------+
|              CASE 4: BIDIRECTIONAL (OUTBOUND-INBOUND)                  |
|        (One cluster firewalled, single shared connection)              |
+------------------------------------------------------------------------+

   +---------------------+                    +---------------------+
   | onprem-1            |                    |   cloud             |
   | (k8s-onprem-1)      |                    |   (k8s-cloud)       |
   |                     |                    |                     |
   | - Has: onprem-1-topic|                   | - Has: cloud-topic  |
   | - Wants: cloud-topic|                    | - Wants: onprem-1-topic|
   | - Network: PRIVATE  |                    | - Network: OPEN     |
   +----------+----------+                    +----------+----------+
              |                                          |
              |                                  +-------v-----------+
              |                                  | STEP 1: Create    |
              |                                  | ClusterLink CR    |
              |                                  | Mode: BIDIRECTIONAL|
              |                                  | Connection: INBOUND|
              |                                  | PASSIVE!          |
              |                                  | mirrorTopics:     |
              |                                  |   - onprem-1-topic|
              |                                  +-------------------+
              |                                          |
   +----------v----------+                              |
   | STEP 2: Create      |                              |
   | ClusterLink CR      |      SINGLE CONNECTION       |
   | Mode: BIDIRECTIONAL |      CARRIES BOTH DIRECTIONS |
   | Connection: OUTBOUND+------------------------------+
   |                     |                              |
   | PROVIDES BOTH:      |                              |
   | - source.auth =     |                              |
   |   cloud-creds       |                              |
   | - dest.auth =       |                              |
   |   onprem-1-creds    |                              |
   |   (local.*)         |                              |
   | mirrorTopics:       |                              |
   |   - cloud-topic     |                              |
   +---------------------+                              |
              |                                          |
         <===== data flows BOTH ways =====>
         (single connection, initiated by onprem-1)

      FIREWALL BLOCKS INBOUND TRAFFIC
      Cloud cannot reach onprem-1's Kafka

Key Points:
- SINGLE connection initiated by onprem-1, traffic flows BOTH ways
- INBOUND CR (on cloud) must be created FIRST
- OUTBOUND CR (on onprem-1) created SECOND
- onprem-1 (OUTBOUND) provides BOTH:
  - source.authentication (cloud-creds) to authenticate TO cloud
  - dest.authentication (onprem-1-creds) becomes local.* for cloud to read FROM onprem-1 over the shared connection
- cloud (INBOUND) is passive -- no dest.authentication needed, no bootstrapEndpoint used
  - bootstrapEndpoint is a placeholder (CFK validation only, not functionally used)
  - kafkaRestClassRef CR must exist but endpoint not used when clusterID is provided
- spec.name MUST match on both CRs
```

**Characteristics:**
- **Single connection carries traffic both ways**
- OUTBOUND side (onprem-1) provides **both** remote creds **and** local.* creds
- INBOUND CR must be created **FIRST** (per Confluent docs)
- INBOUND side (cloud) is passive
- Requires cloud to reach onprem-1's REST API (if onprem-1's REST is also firewalled, use Case 2 instead)

#### Prerequisites

Create these KafkaRestClass CRs **first**:

```yaml
# On k8s-onprem-1: points to cloud's REST API (onprem-1 can reach cloud)
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: rest-for-cloud
spec:
  kafkaRest:
    endpoint: https://cloud-rest.example.com:8090
---
# On k8s-cloud: points to onprem-1's REST API
# NOTE: onprem-1's REST API must be reachable from cloud for this to work.
# If onprem-1 is fully firewalled (REST API also blocked), use Case 2 instead.
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: rest-for-onprem-1
spec:
  kafkaRest:
    endpoint: https://onprem-1-rest.example.com:8090
```

#### CR on Cloud (INBOUND -- Created FIRST)

<details>
<summary><b>INBOUND CR on Cloud Configuration</b></summary>

```yaml
# Deploy on: k8s-cloud (public)
# cloud is passive -- accepts connection from onprem-1
# MUST be created BEFORE the OUTBOUND CR on onprem-1
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-on-cloud
spec:
  name: bidirectional-link               # MUST match

  sourceInitiatedLink:
    linkMode: Bidirectional
    connectionMode: Inbound              # cloud accepts, doesn't dial

  # --- Remote cluster (onprem-1) ---
  # INBOUND is passive -- doesn't connect out. bootstrapEndpoint is a CFK validation
  # requirement only, not functionally used. Can be a placeholder.
  sourceKafkaCluster:
    bootstrapEndpoint: placeholder-not-used-for-inbound:9092
    clusterID: onprem-1-cluster-id       # REQUIRED -- cloud can't discover onprem-1's ID via broker connection
    kafkaRestClassRef:
      name: rest-for-onprem-1            # CFK validation requirement -- CR must exist but endpoint not used

  # --- Local cluster (cloud) ---
  destinationKafkaCluster:
    kafkaRestClassRef:
      name: rest-cloud                   # Manages the link on cloud
    authentication:
      type: plain
      jaasConfig:
        secretRef: cloud-creds           # CFK generates local.* configs from this

  mirrorTopics:
    - name: onprem-1-topic               # Topics cloud wants from onprem-1
```

</details>

**Field Breakdown (Cloud - INBOUND):**

| Field | Value | Why |
|-------|-------|-----|
| `source.bootstrapEndpoint` | placeholder | CFK validation only -- INBOUND doesn't connect out. Can be any value. |
| `source.clusterID` | `onprem-1-cluster-id` | Required -- INBOUND can't discover remote ID via broker connection |
| `source.kafkaRestClassRef` | `rest-for-onprem-1` | CFK validation -- CR must exist but endpoint not functionally used |
| `source.authentication` | not needed | INBOUND is passive -- TLS/auth on source are ignored |
| `dest.kafkaRestClassRef` | `rest-cloud` | Manages the link on cloud |
| `dest.authentication` | `cloud-creds` | CFK generates `local.*` configs from this for bidirectional |
| `link.mode` | `BIDIRECTIONAL` | |
| `connection.mode` | `INBOUND` | |

#### CR on onprem-1 (OUTBOUND -- Created SECOND)

<details>
<summary><b>OUTBOUND CR on onprem-1 Configuration</b></summary>

```yaml
# Deploy on: k8s-onprem-1 (behind firewall)
# onprem-1 initiates connection to cloud -- single connection carries traffic both ways
# MUST be created AFTER the INBOUND CR on cloud
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-on-onprem-1
spec:
  name: bidirectional-link               # MUST match

  sourceInitiatedLink:
    linkMode: Bidirectional
    connectionMode: Outbound             # onprem-1 dials out (default)

  # --- Remote cluster (cloud) ---
  sourceKafkaCluster:
    bootstrapEndpoint: cloud:9092        # onprem-1 connects here
    clusterID: cloud-cluster-id          # cloud's cluster ID
    kafkaRestClassRef:
      name: rest-for-cloud               # Local KafkaRestClass pointing to cloud's REST API
    authentication:
      type: plain
      jaasConfig:
        secretRef: cloud-creds           # onprem-1 authenticates TO cloud

  # --- Local cluster (onprem-1) ---
  destinationKafkaCluster:
    kafkaRestClassRef:
      name: rest-onprem-1                # Manages the link on onprem-1
    authentication:
      type: plain
      jaasConfig:
        secretRef: onprem-1-creds        # Becomes local.* -- cloud reads from onprem-1 over reverse connection

  mirrorTopics:
    - name: cloud-topic                  # Topics onprem-1 wants from cloud
```

</details>

**Field Breakdown (onprem-1 - OUTBOUND):**

| Field | Value | Why |
|-------|-------|-----|
| `source.bootstrapEndpoint` | `cloud:9092` | onprem-1 dials out to cloud |
| `source.clusterID` | `cloud-cluster-id` | cloud's cluster ID |
| `source.kafkaRestClassRef` | `rest-for-cloud` | Local KafkaRestClass pointing to cloud's REST API |
| `source.authentication` | `cloud-creds` | onprem-1 authenticates TO cloud |
| `dest.kafkaRestClassRef` | `rest-onprem-1` | Manages the link on onprem-1 |
| `dest.authentication` | `onprem-1-creds` | Becomes `local.*` -- single connection carries both ways, cloud reads from onprem-1 |
| `link.mode` | `BIDIRECTIONAL` | |
| `connection.mode` | `OUTBOUND` | |

---

## Key Concepts

### Mirror Topic Directions

A ClusterLink CR is needed on **both** clusters. Mirror topics can be defined on **either** side using two directions:

| Direction | Behavior | Example |
|-----------|----------|---------|
| `toDestination` | **PULL** from remote (source) to local (destination) | onprem-2 CL: `name: central-topic, direction: toDestination` -- pulls central-topic from central to onprem-2 |
| `toSource` | **PUSH** from local (destination) to remote (source) | onprem-2 CL: `name: onprem-2-orders, direction: toSource` -- pushes onprem-2-orders from onprem-2 to central |

Both directions can be mixed in a single CR. This means you can handle all mirroring from one side if preferred:

```yaml
# onprem-2 CL -- both pulls AND pushes in one CR
mirrorTopics:
  - name: central-topic        # pull from central
    direction: toDestination
  - name: onprem-2-orders      # push to central
    direction: toSource
```

Or you can split: each CR pulls from the other using `toDestination` only (the pattern shown in Case 3/4 examples).

---

## Important Gotchas & Best Practices

### 1. Link Name Must Match

Both ClusterLink CRs **must** have the same `spec.name`. This is what associates them as a bidirectional pair:

```yaml
# Correct - same spec.name
dest-cluster-link:
  spec.name: "my-bidirectional-link"
src-cluster-link:
  spec.name: "my-bidirectional-link"

# Wrong - different names won't work
dest-cluster-link:
  spec.name: "link-1"
src-cluster-link:
  spec.name: "link-2"
```

### 2. sourceKafkaCluster = Remote, destinationKafkaCluster = Local

In each ClusterLink CR, the field names mean:
- `sourceKafkaCluster` = the **remote** cluster this CR connects to
- `destinationKafkaCluster` = the **local** cluster where this CR is deployed

This holds for all modes. On onprem-1's CR, `sourceKafkaCluster` points to onprem-2. On onprem-2's CR, `sourceKafkaCluster` points to onprem-1. The names `source`/`destination` refer to the data flow direction for `toDestination` mirrors (pull from remote to local), not the cluster identity.

### 3. cluster.link.id Is Auto-Populated

For INBOUND mode, CFK automatically sets `cluster.link.id` from `sourceKafkaCluster.clusterID`. You do NOT need to manually configure it in `spec.configs`. Just provide `clusterID` in the CR and CFK handles the rest.

### 4. INBOUND Link Must Be Created First

Applies to any setup with an INBOUND connection mode — both **Case 2** (source-initiated unidirectional) and **Case 4** (outbound-inbound bidirectional).

The INBOUND CR (passive side) must be created **before** the OUTBOUND CR (initiating side). The INBOUND link gets a link ID assigned, and the OUTBOUND link references it.

**Correct approach:**
1. Create the INBOUND CR first (Destination mode for Case 2, INBOUND bidirectional for Case 4)
2. Create the OUTBOUND CR second
3. Wait for the OUTBOUND link to become healthy (it initiates the connection)
4. Then verify the INBOUND link becomes healthy

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

### 8. Local Authentication (`local.*` configs) for SASL-SSL Clusters

`local.*` configs (`local.sasl.jaas.config`, `local.ssl.*`) are needed when the remote cluster reads back from the local cluster **over the same connection**. This only applies when there's a single shared connection:

- **Case 4 OUTBOUND** (bidirectional with firewall): The OUTBOUND side must provide `destinationKafkaCluster.authentication` so the INBOUND side can authenticate back to read local topics over the single connection.
- **Case 2 Source mode**: The Source CR must provide `sourceKafkaCluster.authentication` (flipped) for the same reason.

`local.*` configs are **NOT needed** for:
- **Case 3** (bidirectional, both OUTBOUND): Each side has its own independent connection with the remote's creds. No reading back over shared connection needed.
- **Case 4 INBOUND**: Passive — does not initiate connections.
- **Case 1**: Simple unidirectional pull.

```yaml
# Case 4 OUTBOUND -- needs local.* for reading back over shared connection
spec:
  sourceKafkaCluster:
    authentication: ...  # -> generates sasl.jaas.config (authenticates TO remote)
  destinationKafkaCluster:
    authentication: ...  # -> generates local.sasl.jaas.config (remote reads FROM local)
```

> **Note**: CFK code (`setup.go`) calls `localKafkaClusterAuth` for all BIDIRECTIONAL mode CRs. If `dest.authentication` is nil, it generates empty local.* configs which is fine — it doesn't fail.

> **Note**: KRaft mode automatically uses metadata.version >= 3.3-IV0, so the inter-broker protocol version is not required.

### 9. Consumer Offset Sync Considerations

When enabling consumer offset sync (`consumer.offset.sync.enable: true`):
- Consumer groups must exist on both clusters
- Offsets are synced periodically (not real-time)
- Consider the sync interval for your RPO requirements

### 10. ACL Sync with RBAC

When using ACL sync (`acl.sync.enable: true`) with RBAC:
- Ensure proper rolebindings exist on both clusters
- ACL sync only works with Kafka ACLs, not RBAC rolebindings

---

## Quick Reference Tables

### What Each Sub-field Does

| Sub-field | Becomes | Purpose |
|-----------|---------|---------|
| `bootstrapEndpoint` | `bootstrap.servers` config | Kafka broker address to connect to for replication |
| `kafkaRestClassRef` | REST API client | Manage link, mirror topics, discover cluster ID |
| `clusterID` | Direct cluster ID | Skip REST API discovery. **Required** for cross-K8s or when you can't reach the cluster |
| `authentication` (remote side) | `sasl.*` configs | Authenticate when connecting TO the remote cluster |
| `authentication` (local side) | `local.sasl.*` configs | Authenticate when remote side connects back to local (Source mode & Case 4 OUTBOUND only) |
| `tls` (remote side) | `ssl.*` configs | TLS for connecting to remote |
| `tls` (local side) | `local.ssl.*` configs | TLS for reverse connection (Source mode & Case 4 OUTBOUND only) |

### When local.* Auth Is Needed

`local.*` configs are needed when the remote cluster needs to authenticate back to the local cluster over a connection.

| Mode | local.* needed? | Why |
|------|-----------------|-----|
| Case 1: Destination-initiated | No | Simple pull, one direction |
| Case 2: Source mode CR | Yes (`source.authentication`) | D reads from C over the reverse connection |
| Case 2: Destination mode CR | No | Passive, no connection |
| Case 3: Bidirectional (both OUTBOUND) | No | Two independent connections — each side authenticates to the other with remote creds. No reading back over shared connection needed. |
| Case 4: OUTBOUND CR | Yes (`dest.authentication` + `dest.tls`) | Single connection carries traffic both ways — INBOUND side reads from OUTBOUND side over the same connection, needs local.* to authenticate |
| Case 4: INBOUND CR | No | Passive — does not initiate any connection |

### clusterID vs kafkaRestClassRef

| Mode | Remote side needs | Notes |
|------|-------------------|-------|
| Unidirectional (Case 1) | `clusterID` OR `kafkaRestClassRef` | `clusterID` is sufficient. `kafkaRestClassRef` can discover ID but needs reachable REST API |
| Source CR (Case 2) | `clusterID` OR `kafkaRestClassRef` | Same as above |
| Destination CR (Case 2) | `clusterID` (required) | Remote is behind firewall, can't be reached |
| Bidirectional (Cases 3 & 4) | `kafkaRestClassRef` (required) + `clusterID` (optional) | CFK requires `kafkaRestClassRef` for bidirectional. If the remote REST is reachable, CFK auto-discovers the cluster ID — `clusterID` is not mandatory. If provided, `clusterID` is used directly without REST discovery. |

> **Note**: The remote KafkaRestClass must point to a reachable endpoint for bidirectional links — even when `clusterID` is provided, CFK's reconciler still checks the KafkaRestClass health.
>
> **Tested**: Bidirectional SASL-SSL ClusterLink on 2 separate GKE clusters confirmed working without `clusterID` — CFK discovered the remote cluster ID via the REST API configured on the remote KafkaRestClass with HTTPS + basic auth.

---

---

## Prerequisites

1. **CFK 3.2.0+** installed
2. **Confluent Platform 7.4+** (or 8.0+ for KRaft-only)

## Quick Start

```bash
# Choose an example
cd kraft/sasl-ssl

# Deploy everything
./setup.sh

# Validate bidirectional mirroring
./validate.sh

# Cleanup
./teardown.sh
```

---

## Troubleshooting

### First Step: Describe the Link

Always start by describing the link from inside a Kafka broker pod:

```bash
kafka-cluster-links --bootstrap-server <broker>:9071 \
  --describe --link <link-name> \
  --command-config /tmp/client.properties
```

This shows: link state (ACTIVE/UNAVAILABLE), remote link state, connection mode, mirrored topics, and all link configs. If the link doesn't exist yet, check the CFK operator logs.

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

### Link creation fails with "cluster ID mismatch"

**Symptoms:**
- Link creation fails
- Error mentions cluster ID doesn't match

**Root Cause:**
- Incorrect `clusterID` specified in CR
- Cluster ID changed after cluster recreation

**Solution:**
```bash
# Get actual cluster ID from the cluster
kafka-cluster cluster-id --bootstrap-server <bootstrap>

# Update CR with correct cluster ID
```

### "mirrorTopics not allowed" error in Source mode

**Symptoms:**
- Source mode CR fails validation
- Error: "mirrorTopics not allowed in Source mode"

**Root Cause:**
- `mirrorTopics` defined on Source mode CR

**Solution:**
- Move `mirrorTopics` to the Destination mode CR (the passive side)
- Source mode CR should not have `mirrorTopics` section

### Bidirectional link fails with "kafkaRestClassRef required"

**Symptoms:**
- Bidirectional link creation fails
- Error about missing `kafkaRestClassRef`

**Root Cause:**
- CFK requires `sourceKafkaCluster.kafkaRestClassRef` for bidirectional links
- Cross-K8s setup means you can't reference remote KafkaRestClass

**Solution:**
1. Create a local KafkaRestClass pointing to remote REST API:
```yaml
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: rest-for-remote
spec:
  kafkaRest:
    endpoint: https://remote-rest.example.com:8090
```
2. Reference it in your ClusterLink CR:
```yaml
sourceKafkaCluster:
  kafkaRestClassRef:
    name: rest-for-remote
  clusterID: id-remote  # Also include clusterID
```

### Case 4 INBOUND CR created after OUTBOUND

**Symptoms:**
- Bidirectional link with firewall doesn't work
- Connection errors

**Root Cause:**
- OUTBOUND CR created before INBOUND CR
- Confluent docs require INBOUND CR to be created first

**Solution:**
1. Delete both CRs
2. Create INBOUND CR first (on the public/reachable cluster)
3. Wait for it to be ready
4. Create OUTBOUND CR (on the firewalled cluster)

### Authentication failures in Source mode

**Symptoms:**
- Source-initiated link fails to authenticate
- "Authentication failed" errors

**Root Cause:**
- Wrong credentials used
- Confusion about which credentials go where in Source mode

**Solution:**
- Remember: Source mode is **FLIPPED**
- On Source CR:
    - `sourceKafkaCluster.authentication` -> becomes `local.*` (for remote to read from local)
    - `destinationKafkaCluster.authentication` -> for connecting TO remote
- On Destination CR:
    - No authentication needed (passive)

### Can't reach cluster's REST API

**Symptoms:**
- KafkaRestClass connection failures
- "Unable to reach REST API" errors

**Root Cause:**
- Network policies blocking REST API access
- Firewall rules
- REST API not exposed externally

**Solution:**
- For fully firewalled clusters (REST API also blocked):
    - Use Case 2 (source-initiated unidirectional) instead of Case 4
    - Case 4 requires REST API to be reachable from both sides
- Check network policies and firewall rules
- Ensure REST API is exposed via LoadBalancer or NodePort if accessing from external K8s

### Wrong link name between paired CRs

**Symptoms:**
- Paired CRs don't connect
- Links appear as separate, unrelated links

**Root Cause:**
- `spec.name` field doesn't match between paired CRs
- Case 2, 3, and 4 require matching link names

**Solution:**
```yaml
# Both CRs must have identical spec.name
spec:
  name: my-cluster-link  # MUST be identical on both CRs
```

### Debugging Checklist

When troubleshooting cluster links:

- [ ] Verify `clusterID` matches actual cluster ID
- [ ] Check credentials are for the **target** cluster (the one you're connecting TO)
- [ ] Confirm network connectivity between clusters
- [ ] Verify KafkaRestClass endpoints are reachable
- [ ] For bidirectional: ensure both KafkaRestClass CRs exist
- [ ] For Case 4: INBOUND CR created before OUTBOUND CR
- [ ] For Source mode: `mirrorTopics` only on Destination CR
- [ ] Verify `spec.name` matches across paired CRs
- [ ] Check TLS certificates are valid and trusted

---

## References

- [Confluent Documentation: Bidirectional Cluster Linking](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/configs.html#bidirectional-mode)
- [Advanced Options for Bidirectional Cluster Linking](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/configs.html#advanced-options-for-bidirectional-cluster-linking)
- [CFK ClusterLink API Reference](https://docs.confluent.io/operator/current/co-api.html#tag/ClusterLink)
- [Confluent Cluster Linking Documentation](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/index.html)
