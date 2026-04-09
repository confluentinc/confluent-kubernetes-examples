# CFK Cluster Linking Runbook

> **Comprehensive reference for all 4 modes of Kafka Cluster Linking in Confluent for Kubernetes (CFK)**

## Table of Contents

1. [Quick Decision Guide](#quick-decision-guide)
2. [Understanding the Field Names](#understanding-the-field-names)
3. [Setup & Prerequisites](#setup--prerequisites)
4. [The Four Modes](#the-four-modes)
    - [Case 1: Destination-Initiated Unidirectional](#case-1-destination-initiated-unidirectional)
    - [Case 2: Source-Initiated Unidirectional](#case-2-source-initiated-unidirectional)
    - [Case 3: Bidirectional (No Firewall)](#case-3-bidirectional-no-firewall)
    - [Case 4: Bidirectional (With Firewall)](#case-4-bidirectional-with-firewall)
5. [Quick Reference Tables](#quick-reference-tables)
6. [Common Issues & Troubleshooting](#common-issues--troubleshooting)

---

## Quick Decision Guide

Use this flowchart to determine which mode you need:

```
┌─────────────────────────────────────┐
│ Do you need bidirectional traffic?  │
└────────┬────────────────────┬───────┘
         │                    │
        NO                   YES
         │                    │
         ▼                    ▼
  ┌──────────────┐     ┌──────────────┐
  │ Is source    │     │ Can both     │
  │ firewalled?  │     │ clusters     │
  └──┬────────┬──┘     │ reach each   │
     │        │        │ other?       │
    YES      NO        └──┬────────┬──┘
     │        │           │        │
     │        │          YES      NO
     │        │           │        │
     ▼        ▼           ▼        ▼
  Case 2    Case 1     Case 3   Case 4
  Source-   Dest-      Bidir    Bidir
  Initiated Initiated  (Both    (Firewall)
            (Simple)   OUTBOUND)
```

**Quick Selection:**
- **Case 1**: Production → Analytics (simple pull, no firewall) _(Most common)_
- **Case 2**: OnPrem → Cloud (on-prem behind firewall, must push)
- **Case 3**: US-West ↔ US-East (bidirectional, both clusters open)
- **Case 4**: DataCenter ↔ Cloud (bidirectional, datacenter firewalled)

---

## Understanding the Field Names

### ⚠️ Critical Concept: sourceKafkaCluster vs destinationKafkaCluster

These names are **confusing** because they come from the unidirectional model. Here's what they actually mean:

| Field Name | What It Actually Means |
|------------|------------------------|
| `destinationKafkaCluster` | **Local cluster** where this CR is deployed and the link is created |
| `sourceKafkaCluster` | **Remote cluster** this link connects to |

**Exception:** In Source mode (Case 2), these fields are **FLIPPED**!

> 💡 **Think of them as:** `localKafkaCluster` and `remoteKafkaCluster` for clarity, especially in bidirectional setups.

### 🔑 The Golden Rule for Credentials

**You always provide credentials of the cluster you're connecting TO.**

- If A connects to B → use `creds-b`
- If C connects to D → use `creds-d`

---

## Setup & Prerequisites

### Example Clusters Across Different Scenarios

The examples use 4 clusters to demonstrate different real-world scenarios. Each runs on **separate Kubernetes clusters**:

| Use Case | Cluster Name | K8s Cluster | Bootstrap | KafkaRestClass | Cluster ID | SASL Creds | Network |
|----------|--------------|-------------|-----------|----------------|------------|------------|---------|
| **Case 1** | `prod-kafka` | k8s-prod | `prod:9092` | `rest-prod` | `prod-cluster-id` | `prod-creds` | Open |
| **Case 1** | `analytics-kafka` | k8s-analytics | `analytics:9092` | `rest-analytics` | `analytics-cluster-id` | `analytics-creds` | Open |
| **Case 2** | `onprem-kafka` | k8s-onprem | `onprem:9092` | `rest-onprem` | `onprem-cluster-id` | `onprem-creds` | 🔒 Firewalled |
| **Case 2** | `cloud-kafka` | k8s-cloud | `cloud:9092` | `rest-cloud` | `cloud-cluster-id` | `cloud-creds` | Open |
| **Case 3** | `west-kafka` | k8s-west | `west:9092` | `rest-west` | `west-cluster-id` | `west-creds` | Open |
| **Case 3** | `east-kafka` | k8s-east | `east:9092` | `rest-east` | `east-cluster-id` | `east-creds` | Open |
| **Case 4** | `datacenter-kafka` | k8s-dc | `datacenter:9092` | `rest-dc` | `dc-cluster-id` | `dc-creds` | 🔒 Firewalled (REST reachable) |
| **Case 4** | `cloud-kafka` | k8s-cloud | `cloud:9092` | `rest-cloud` | `cloud-cluster-id` | `cloud-creds` | Open |

**Network Constraints:**
- ✅ `prod-kafka` and `analytics-kafka` can freely communicate
- ✅ `west-kafka` and `east-kafka` can freely communicate
- ❌ `cloud-kafka` **cannot** reach `onprem-kafka` Kafka brokers (on-prem is firewalled)
- ✅ `cloud-kafka` **can** reach `datacenter-kafka` REST API (but not Kafka brokers)
- Each cluster runs on its own K8s cluster with its own CFK operator

### Understanding KafkaRestClass

A `KafkaRestClass` is a Kubernetes CR that tells CFK how to reach a Kafka cluster's REST API.

**Key Points:**
- Lives on the **local** K8s cluster
- You **cannot** reference a KafkaRestClass from another K8s cluster
- For the **local** cluster: points to local Kafka CR
- For **remote** clusters (bidirectional only): create a local KafkaRestClass with explicit endpoint

**Local KafkaRestClass (on k8s-west):**
```yaml
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: rest-west
spec:
  kafkaClusterRef:
    name: kafka  # Points to local Kafka CR
```

**Remote KafkaRestClass for bidirectional (on k8s-west, pointing to east):**
```yaml
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: rest-for-east
spec:
  kafkaRest:
    endpoint: https://east-rest.example.com:8090
    # Add authentication if east's REST API requires it
```

> ⚠️ **For unidirectional links**: You can skip remote KafkaRestClass by setting `clusterID` directly

---

## The Four Modes

### Case 1: Destination-Initiated Unidirectional

**Scenario:** Analytics cluster wants data from Production, no firewall, simple pull

```
┌────────────────────────────────────────────────────────────────────────┐
│                         CASE 1: SIMPLE PULL                            │
│                    (Destination-Initiated, No Firewall)                │
└────────────────────────────────────────────────────────────────────────┘

   ┌─────────────────────┐                    ┌─────────────────────┐
   │   prod-kafka        │                    │  analytics-kafka    │
   │   (k8s-prod)        │                    │  (k8s-analytics)    │
   │                     │                    │                     │
   │ • Has: user-events  │                    │ • Wants: user-events│
   │ • Bootstrap:        │                    │ • Bootstrap:        │
   │   prod:9092         │                    │   analytics:9092    │
   │ • Cluster ID:       │                    │ • Cluster ID:       │
   │   prod-cluster-id   │                    │   analytics-cluster-id│
   │ • Network: Open     │                    │ • Network: Open     │
   └──────────┬──────────┘                    └──────────┬──────────┘
              │                                          │
              │     ════════ DATA FLOW ═════════>        │
              │                                          │
              │     <─────── PULL REQUEST ──────         │
              │                                          │
              │                                  ┌───────▼──────────┐
              │                                  │ ClusterLink CR   │
              │                                  │ Name: link-...   │
              │                                  │ Deploy: HERE ✓   │
              │                                  │ Mode: DESTINATION│
              └──────────────────────────────────┤ Connection: OUT  │
                                                 └──────────────────┘

Key Points:
• analytics-kafka reaches out to prod-kafka (OUTBOUND connection)
• analytics-kafka pulls data using prod-kafka's credentials
• Only 1 CR deployed on analytics-kafka cluster
• Most common and simplest scenario
```

**Characteristics:**
- ✅ Simplest setup
- ✅ Only 1 CR (on destination cluster `analytics-kafka`)
- ✅ `analytics-kafka` pulls data from `prod-kafka`
- ✅ Most common scenario

<details>
<summary><b>📄 Full YAML Configuration</b></summary>

```yaml
# Deploy on: k8s-analytics
# Data flow: prod-kafka → analytics-kafka
# analytics-kafka reaches out to prod-kafka and pulls data
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-prod-to-analytics
spec:
  # --- Remote cluster (prod-kafka) ---
  sourceKafkaCluster:
    bootstrapEndpoint: prod:9092          # analytics connects here to pull data
    clusterID: prod-cluster-id            # prod's cluster ID (cross-K8s — can't discover via REST)
    authentication:
      type: plain
      jaasConfig:
        secretRef: prod-creds             # analytics authenticates TO prod, needs prod's creds
    tls:
      enabled: true
      secretRef: tls-prod                 # TLS to connect to prod

  # --- Local cluster (analytics-kafka) ---
  destinationKafkaCluster:
    kafkaRestClassRef:
      name: rest-analytics                # Manages the link on analytics via REST API

  mirrorTopics:
    - name: user-events                   # Topic to mirror from prod
```

</details>

**Field Breakdown:**

| Field | Value | Why |
|-------|-------|-----|
| `source.bootstrapEndpoint` | `prod:9092` | analytics connects to prod's brokers for data replication |
| `source.clusterID` | `prod-cluster-id` | prod's cluster ID — required since prod is on different K8s cluster |
| `source.authentication` | `prod-creds` | analytics is connecting TO prod — needs creds prod accepts |
| `source.tls` | `tls-prod` | TLS certs for connecting to prod |
| `dest.kafkaRestClassRef` | `rest-analytics` | Manages the link on analytics (create link, mirror topics, etc.) |
| `dest.authentication` | ❌ not needed | analytics doesn't authenticate to itself |
| `link.mode` | _(defaults to DESTINATION)_ | |
| `connection.mode` | _(defaults to OUTBOUND)_ | |

---

### Case 2: Source-Initiated Unidirectional

**Scenario:** OnPrem has data, Cloud wants it, but Cloud **cannot reach OnPrem** (firewall). OnPrem must push.

```
┌────────────────────────────────────────────────────────────────────────┐
│                     CASE 2: FIREWALL PUSH                              │
│              (Source-Initiated, OnPrem Behind Firewall)                │
└────────────────────────────────────────────────────────────────────────┘

   ┌─────────────────────┐                    ┌─────────────────────┐
   │   onprem-kafka      │                    │   cloud-kafka       │
   │   (k8s-onprem)      │                    │   (k8s-cloud)       │
   │                     │                    │                     │
   │ • Has: orders       │                    │ • Wants: orders     │
   │ • Bootstrap:        │                    │ • Bootstrap:        │
   │   onprem:9092       │                    │   cloud:9092        │
   │ • Cluster ID:       │                    │ • Cluster ID:       │
   │   onprem-cluster-id │                    │   cloud-cluster-id  │
   │ • Network: 🔒 PRIVATE│                   │ • Network: OPEN     │
   └──────────┬──────────┘                    └──────────┬──────────┘
              │                                          │
   ┌──────────▼──────────┐                              │
   │ ClusterLink CR      │                              │
   │ Name: link-o-to-c   │                              │
   │ Deploy: HERE ✓      │                              │
   │ Mode: SOURCE        │                              │
   │ Connection: OUTBOUND├──────────────────────────────┤
   │                     │                              │
   │ ⚠️ FLIPPED FIELDS!  │                              │
   │ source = LOCAL      │                              │
   │ dest = REMOTE       │                              │
   └─────────────────────┘                              │
              │                                          │
              │     ════════ DATA FLOW ═════════>        │
              │                                          │
              │     ──────── PUSH (OUTBOUND) ───────>    │
              │                                          │
              │                                  ┌───────▼──────────┐
              │                                  │ ClusterLink CR   │
              │                                  │ Name: link-o-to-c│
     🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥                           │ Deploy: HERE ✓   │
     🔥 FIREWALL  🔥                            │ Mode: DESTINATION│
     🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥                           │ Connection: IN   │
              ▲                                  │ ⚠️ PASSIVE!      │
              │                                  │ mirrorTopics: ✓  │
      Cloud cannot reach                        └──────────────────┘
      onprem's Kafka brokers

Key Points:
• onprem-kafka initiates connection (OUTBOUND) and pushes data
• cloud-kafka is passive (INBOUND), waits for connection
• 2 CRs required with matching spec.name
• Source CR has FLIPPED field semantics (source=local, dest=remote)
• mirrorTopics ONLY on Destination CR, NOT on Source CR
• spec.name MUST match between both CRs (metadata.name can differ)
```

**Characteristics:**
- ⚠️ Requires **2 CRs** (one on each cluster)
- ⚠️ Field names are **FLIPPED** on Source mode CR
- ⚠️ `mirrorTopics` go on Destination CR, **NOT** Source CR
- `onprem-kafka` initiates connection and pushes data to `cloud-kafka`

#### CR on OnPrem (Source Mode)

<details>
<summary><b>📄 Source Mode CR Configuration</b></summary>

```yaml
# Deploy on: k8s-onprem (behind firewall)
# onprem-kafka initiates connection to cloud-kafka and pushes data
#
# ⚠️ FLIPPED: In Source mode, source=local and destination=remote
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-onprem-source
spec:
  name: link-onprem-to-cloud          # ⚠️ MUST match on both CRs
  sourceInitiatedLink:
    linkMode: Source

  # --- Local cluster (onprem-kafka) — FLIPPED: source=local in Source mode ---
  sourceKafkaCluster:
    kafkaRestClassRef:
      name: rest-onprem                # Manages the link on onprem
    authentication:
      type: plain
      jaasConfig:
        secretRef: onprem-creds        # Becomes local.* configs — cloud reads from onprem using these
    tls:
      enabled: true
      secretRef: tls-onprem            # Becomes local.* TLS

  # --- Remote cluster (cloud-kafka) — FLIPPED: destination=remote in Source mode ---
  destinationKafkaCluster:
    bootstrapEndpoint: cloud:9092      # onprem connects here to push data
    clusterID: cloud-cluster-id        # cloud's cluster ID (cross-K8s)
    authentication:
      type: plain
      jaasConfig:
        secretRef: cloud-creds         # onprem authenticates TO cloud
    tls:
      enabled: true
      secretRef: tls-cloud             # TLS to connect to cloud

  # ⚠️ mirrorTopics NOT allowed on Source mode CR — define them on Destination CR
```

</details>

**Field Breakdown (Source CR):**

| Field | Value | Why |
|-------|-------|-----|
| `source.kafkaRestClassRef` | `rest-onprem` | **Source mode: source=local** — manages link on onprem |
| `source.authentication` | `onprem-creds` | Becomes `local.*` configs — cloud reads from onprem over reverse connection |
| `source.tls` | `tls-onprem` | Becomes `local.*` TLS |
| `dest.bootstrapEndpoint` | `cloud:9092` | **Source mode: dest=remote** — onprem connects to cloud |
| `dest.clusterID` | `cloud-cluster-id` | cloud's cluster ID (cross-K8s) |
| `dest.authentication` | `cloud-creds` | onprem authenticates TO cloud |
| `dest.tls` | `tls-cloud` | TLS for connecting to cloud |
| `link.mode` | `SOURCE` | |
| `connection.mode` | `OUTBOUND` | |
| `mirrorTopics` | ❌ not allowed here | Must be on Destination mode CR |

#### CR on Cloud (Destination Mode)

<details>
<summary><b>📄 Destination Mode CR Configuration</b></summary>

```yaml
# Deploy on: k8s-cloud (public)
# cloud-kafka is passive — waits for onprem-kafka to connect
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-cloud-dest
spec:
  name: link-onprem-to-cloud          # ⚠️ MUST match Source CR

  sourceInitiatedLink:
    linkMode: Destination

  # --- Remote cluster (onprem-kafka) — can't reach it ---
  sourceKafkaCluster:
    clusterID: onprem-cluster-id       # REQUIRED — cloud can't reach onprem to discover it

  # --- Local cluster (cloud-kafka) ---
  destinationKafkaCluster:
    kafkaRestClassRef:
      name: rest-cloud                 # Manages the link on cloud

  # ✅ mirrorTopics go HERE, not on Source CR
  mirrorTopics:
    - name: orders                     # Topic to mirror from onprem
```

</details>

**Field Breakdown (Destination CR):**

| Field | Value | Why |
|-------|-------|-----|
| `source.clusterID` | `onprem-cluster-id` | Required — cloud can't reach onprem to discover it |
| `source.bootstrapEndpoint` | ❌ not needed | cloud is passive (INBOUND), never dials out |
| `source.kafkaRestClassRef` | ❌ not needed | Can't reach onprem |
| `source.authentication` | ❌ not needed | cloud doesn't connect to onprem |
| `dest.kafkaRestClassRef` | `rest-cloud` | Manages the link on cloud |
| `dest.authentication` | ❌ not needed | cloud doesn't authenticate to itself |
| `link.mode` | `DESTINATION` | |
| `connection.mode` | `INBOUND` | |
| `mirrorTopics` | ✅ defined here | Source mode CR can't have mirror topics |

---

### Case 3: Bidirectional (No Firewall)

**Scenario:** US-West and US-East both want each other's data, both can reach each other

```
┌────────────────────────────────────────────────────────────────────────┐
│                   CASE 3: BIDIRECTIONAL (NO FIREWALL)                  │
│              (Both clusters open, independent connections)             │
└────────────────────────────────────────────────────────────────────────┘

   ┌─────────────────────┐                    ┌─────────────────────┐
   │   west-kafka        │                    │   east-kafka        │
   │   (k8s-west)        │                    │   (k8s-east)        │
   │                     │                    │                     │
   │ • Has: west-users   │                    │ • Has: east-users   │
   │ • Wants: east-users │                    │ • Wants: west-users │
   │ • Bootstrap:        │                    │ • Bootstrap:        │
   │   west:9092         │                    │   east:9092         │
   │ • Cluster ID:       │                    │ • Cluster ID:       │
   │   west-cluster-id   │                    │   east-cluster-id   │
   │ • Network: Open     │                    │ • Network: Open     │
   └──────────┬──────────┘                    └──────────┬──────────┘
              │                                          │
   ┌──────────▼──────────┐                    ┌──────────▼──────────┐
   │ ClusterLink CR      │                    │ ClusterLink CR      │
   │ Name: link-on-west  │                    │ Name: link-on-east  │
   │ spec.name: bidir-we │◄───┐       ┌──────►│ spec.name: bidir-we │
   │ Deploy: HERE ✓      │    │       │       │ Deploy: HERE ✓      │
   │ Mode: BIDIRECTIONAL │    │       │       │ Mode: BIDIRECTIONAL │
   │ Connection: OUTBOUND│    │       │       │ Connection: OUTBOUND│
   │ mirrorTopics:       │    │       │       │ mirrorTopics:       │
   │   - east-users      │    │       │       │   - west-users      │
   └─────────────────────┘    │       │       └─────────────────────┘
              │                │       │                  │
              │                │       │                  │
              │   Connection 1 │       │ Connection 2     │
              │   (west→east)  │       │ (east→west)      │
              │                │       │                  │
              └────────────────┴───────┴──────────────────┘
                     ════ west-users data ═══════>
                     <══════ east-users data ══════

Key Points:
• TWO independent connections (not a single bidirectional connection)
• Each cluster has its own CR with connection.mode = OUTBOUND
• west-kafka pulls east-users FROM east-kafka (using east-creds)
• east-kafka pulls west-users FROM west-kafka (using west-creds)
• spec.name MUST match on both CRs ("bidir-we" in this example)
• Each cluster needs a KafkaRestClass pointing to the OTHER cluster's REST API
```

**Characteristics:**
- ✅ 2 CRs with same `spec.name`
- ✅ Both connections are OUTBOUND (each pulls from the other)
- ✅ Each CR independently manages its own pull
- ⚠️ Requires KafkaRestClass for both remote clusters

#### Prerequisites

Create these KafkaRestClass CRs **first**:

```yaml
# On k8s-west: points to east's REST API
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: rest-for-east
spec:
  kafkaRest:
    endpoint: https://east-rest.example.com:8090
---
# On k8s-east: points to west's REST API
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: rest-for-west
spec:
  kafkaRest:
    endpoint: https://west-rest.example.com:8090
```

#### CR on West

<details>
<summary><b>📄 CR on West Configuration</b></summary>

```yaml
# Deploy on: k8s-west
# west-kafka reaches out to east-kafka and pulls data
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-on-west
spec:
  name: bidirectional-west-east        # ⚠️ MUST match on both CRs

  sourceInitiatedLink:
    linkMode: Bidirectional

  # --- Remote cluster (east-kafka) ---
  sourceKafkaCluster:
    bootstrapEndpoint: east:9092       # west connects here
    clusterID: east-cluster-id         # east's cluster ID
    kafkaRestClassRef:
      name: rest-for-east              # Local KafkaRestClass pointing to east's REST API
    authentication:
      type: plain
      jaasConfig:
        secretRef: east-creds          # west authenticates TO east

  # --- Local cluster (west-kafka) ---
  destinationKafkaCluster:
    kafkaRestClassRef:
      name: rest-west                  # Manages the link on west
    # ❌ NO authentication needed — east has its own CR to connect to west

  mirrorTopics:
    - name: east-users                 # Topics west wants from east
```

</details>

**Field Breakdown (West):**

| Field | Value | Why |
|-------|-------|-----|
| `source.bootstrapEndpoint` | `east:9092` | west connects to east for data replication |
| `source.clusterID` | `east-cluster-id` | east's cluster ID |
| `source.kafkaRestClassRef` | `rest-for-east` | Local KafkaRestClass with explicit endpoint to east's REST API |
| `source.authentication` | `east-creds` | west authenticates TO east — needs east's creds |
| `dest.kafkaRestClassRef` | `rest-west` | Manages the link on west |
| `dest.authentication` | ❌ not needed | east has its own CR with `west-creds` to connect to west |
| `link.mode` | `BIDIRECTIONAL` | |
| `connection.mode` | `OUTBOUND` (default) | |

#### CR on East

<details>
<summary><b>📄 CR on East Configuration</b></summary>

```yaml
# Deploy on: k8s-east
# east-kafka reaches out to west-kafka and pulls data
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-on-east
spec:
  name: bidirectional-west-east        # ⚠️ MUST match

  sourceInitiatedLink:
    linkMode: Bidirectional

  # --- Remote cluster (west-kafka) ---
  sourceKafkaCluster:
    bootstrapEndpoint: west:9092       # east connects here
    clusterID: west-cluster-id         # west's cluster ID
    kafkaRestClassRef:
      name: rest-for-west              # Local KafkaRestClass pointing to west's REST API
    authentication:
      type: plain
      jaasConfig:
        secretRef: west-creds          # east authenticates TO west

  # --- Local cluster (east-kafka) ---
  destinationKafkaCluster:
    kafkaRestClassRef:
      name: rest-east                  # Manages the link on east
    # ❌ NO authentication needed — west has its own CR to connect to east

  mirrorTopics:
    - name: west-users                 # Topics east wants from west
```

</details>

**Field Breakdown (East):**

| Field | Value | Why |
|-------|-------|-----|
| `source.bootstrapEndpoint` | `west:9092` | east connects to west |
| `source.clusterID` | `west-cluster-id` | west's cluster ID |
| `source.kafkaRestClassRef` | `rest-for-west` | Local KafkaRestClass with explicit endpoint to west's REST API |
| `source.authentication` | `west-creds` | east authenticates TO west |
| `dest.kafkaRestClassRef` | `rest-east` | Manages the link on east |
| `dest.authentication` | ❌ not needed | west has its own CR |
| `link.mode` | `BIDIRECTIONAL` | |
| `connection.mode` | `OUTBOUND` (default) | |

---

### Case 4: Bidirectional (With Firewall)

**Scenario:** DataCenter and Cloud both want each other's data, but only DataCenter can dial out (DataCenter is behind firewall)

```
┌────────────────────────────────────────────────────────────────────────┐
│              CASE 4: BIDIRECTIONAL WITH FIREWALL                       │
│        (Single connection carries traffic both directions)             │
└────────────────────────────────────────────────────────────────────────┘

   ┌─────────────────────┐                    ┌─────────────────────┐
   │ datacenter-kafka    │                    │   cloud-kafka       │
   │ (k8s-dc)            │                    │   (k8s-cloud)       │
   │                     │                    │                     │
   │ • Has: inventory    │                    │ • Has: orders       │
   │ • Wants: orders     │                    │ • Wants: inventory  │
   │ • Bootstrap:        │                    │ • Bootstrap:        │
   │   datacenter:9092   │                    │   cloud:9092        │
   │ • Cluster ID:       │                    │ • Cluster ID:       │
   │   dc-cluster-id     │                    │   cloud-cluster-id  │
   │ • Network: 🔒 PRIVATE│                   │ • Network: OPEN     │
   │   (REST reachable)  │                    │                     │
   └──────────┬──────────┘                    └──────────┬──────────┘
              │                                          │
   ┌──────────▼──────────┐                              │
   │ ClusterLink CR      │                              │
   │ Name: link-on-dc    │                              │
   │ spec.name: bidir-dc │◄─────┐              ┌───────►│
   │ Deploy: HERE ✓      │      │              │        │
   │ Mode: BIDIRECTIONAL │      │              │        │
   │ Connection: OUTBOUND├──────┼──────────────┼────────┤
   │                     │      │              │        │
   │ ⚠️ PROVIDES BOTH:   │      │              │        │
   │ • dest.auth =       │      │              │        │
   │   dc-creds (local.*)│      │   SINGLE     │        │
   │ • source.auth =     │      │ CONNECTION   │        │
   │   cloud-creds       │      │   CARRIES    │        │
   │                     │      │     BOTH     │        │
   │ mirrorTopics:       │      │  DIRECTIONS  │        │
   │   - orders          │      │              │        │
   └─────────────────────┘      │              │        │
              │                 │              │        │
              │                 │              │  ┌─────▼──────────┐
              │                 │              │  │ ClusterLink CR │
     🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥          │              │  │ Name: link-..  │
     🔥 FIREWALL  🔥             │              │  │ spec.name:     │
     🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥          │              │  │   bidir-dc     │
              ▲                 │              │  │ Deploy: HERE ✓ │
              │                 │              │  │ Mode: BIDIR    │
      Cloud cannot reach        │              │  │ Connection: IN │
      datacenter's Kafka        └──────────────┘  │ ⚠️ PASSIVE!    │
      (but CAN reach REST API)                    │ CREATE FIRST!  │
                                                  │                │
         ════════ inventory data ═════════>       │ dest.auth =    │
         <══════════ orders data ═══════          │   cloud-creds  │
                                                  │   (local.*)    │
                                                  │ mirrorTopics:  │
                                                  │   - inventory  │
                                                  └────────────────┘

Key Points:
• SINGLE connection initiated by datacenter, traffic flows BOTH ways
• INBOUND CR (on cloud) must be created FIRST
• OUTBOUND CR (on datacenter) created SECOND
• datacenter provides BOTH:
  - source.authentication (cloud-creds) to authenticate TO cloud
  - dest.authentication (dc-creds) becomes local.* for cloud to read FROM datacenter
• cloud provides dest.authentication (cloud-creds) becomes local.* for datacenter to read FROM cloud
• spec.name MUST match on both CRs
```

**Characteristics:**
- ⚠️ **Single connection carries traffic both ways**
- ⚠️ OUTBOUND side (datacenter) provides **both** remote creds **and** local.* creds
- ⚠️ INBOUND CR must be created **FIRST** (per Confluent docs)
- ⚠️ INBOUND side (cloud) is passive
- ⚠️ Requires cloud to reach datacenter's REST API (if datacenter's REST is also firewalled, use Case 2 instead)

#### Prerequisites

Create these KafkaRestClass CRs **first**:

```yaml
# On k8s-dc: points to cloud's REST API (datacenter can reach cloud)
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: rest-for-cloud
spec:
  kafkaRest:
    endpoint: https://cloud-rest.example.com:8090
---
# On k8s-cloud: points to datacenter's REST API
# ⚠️ NOTE: datacenter's REST API must be reachable from cloud for this to work.
# If datacenter is fully firewalled (REST API also blocked), use Case 2 instead.
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestClass
metadata:
  name: rest-for-datacenter
spec:
  kafkaRest:
    endpoint: https://datacenter-rest.example.com:8090
```

#### CR on Cloud (INBOUND — Created FIRST)

<details>
<summary><b>📄 INBOUND CR on Cloud Configuration</b></summary>

```yaml
# Deploy on: k8s-cloud (public)
# cloud-kafka is passive — accepts connection from datacenter-kafka
# ⚠️ MUST be created BEFORE the OUTBOUND CR on datacenter
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-on-cloud
spec:
  name: bidirectional-dc-cloud         # ⚠️ MUST match

  sourceInitiatedLink:
    linkMode: Bidirectional
    connectionMode: Inbound            # cloud accepts, doesn't dial

  # --- Remote cluster (datacenter-kafka) ---
  sourceKafkaCluster:
    bootstrapEndpoint: datacenter:9092 # Required by CFK for bidirectional
    clusterID: dc-cluster-id           # REQUIRED — cloud can't discover datacenter's ID via broker connection
    kafkaRestClassRef:
      name: rest-for-datacenter        # Local KafkaRestClass pointing to datacenter's REST API

  # --- Local cluster (cloud-kafka) ---
  destinationKafkaCluster:
    kafkaRestClassRef:
      name: rest-cloud                 # Manages the link on cloud
    authentication:
      type: plain
      jaasConfig:
        secretRef: cloud-creds         # CFK generates local.* configs from this

  mirrorTopics:
    - name: inventory                  # Topics cloud wants from datacenter
```

</details>

**Field Breakdown (Cloud - INBOUND):**

| Field | Value | Why |
|-------|-------|-----|
| `source.bootstrapEndpoint` | `datacenter:9092` | Required by CFK for bidirectional |
| `source.clusterID` | `dc-cluster-id` | Required — cloud can't discover datacenter's ID via broker connection |
| `source.kafkaRestClassRef` | `rest-for-datacenter` | Local KafkaRestClass pointing to datacenter's REST API |
| `source.authentication` | ❌ not needed | cloud doesn't initiate connection to datacenter |
| `dest.kafkaRestClassRef` | `rest-cloud` | Manages the link on cloud |
| `dest.authentication` | `cloud-creds` | CFK generates `local.*` configs from this for bidirectional |
| `link.mode` | `BIDIRECTIONAL` | |
| `connection.mode` | `INBOUND` | |

#### CR on DataCenter (OUTBOUND — Created SECOND)

<details>
<summary><b>📄 OUTBOUND CR on DataCenter Configuration</b></summary>

```yaml
# Deploy on: k8s-dc (behind firewall)
# datacenter-kafka initiates connection to cloud-kafka — single connection carries traffic both ways
# ⚠️ MUST be created AFTER the INBOUND CR on cloud
apiVersion: platform.confluent.io/v1beta1
kind: ClusterLink
metadata:
  name: link-on-datacenter
spec:
  name: bidirectional-dc-cloud         # ⚠️ MUST match

  sourceInitiatedLink:
    linkMode: Bidirectional
    connectionMode: Outbound           # datacenter dials out (default)

  # --- Remote cluster (cloud-kafka) ---
  sourceKafkaCluster:
    bootstrapEndpoint: cloud:9092      # datacenter connects here
    clusterID: cloud-cluster-id        # cloud's cluster ID
    kafkaRestClassRef:
      name: rest-for-cloud             # Local KafkaRestClass pointing to cloud's REST API
    authentication:
      type: plain
      jaasConfig:
        secretRef: cloud-creds         # datacenter authenticates TO cloud

  # --- Local cluster (datacenter-kafka) ---
  destinationKafkaCluster:
    kafkaRestClassRef:
      name: rest-dc                    # Manages the link on datacenter
    authentication:
      type: plain
      jaasConfig:
        secretRef: dc-creds            # Becomes local.* — cloud reads from datacenter over reverse connection

  mirrorTopics:
    - name: orders                     # Topics datacenter wants from cloud
```

</details>

**Field Breakdown (DataCenter - OUTBOUND):**

| Field | Value | Why |
|-------|-------|-----|
| `source.bootstrapEndpoint` | `cloud:9092` | datacenter dials out to cloud |
| `source.clusterID` | `cloud-cluster-id` | cloud's cluster ID |
| `source.kafkaRestClassRef` | `rest-for-cloud` | Local KafkaRestClass pointing to cloud's REST API |
| `source.authentication` | `cloud-creds` | datacenter authenticates TO cloud |
| `dest.kafkaRestClassRef` | `rest-dc` | Manages the link on datacenter |
| `dest.authentication` | `dc-creds` | Becomes `local.*` — single connection carries both ways, cloud reads from datacenter |
| `link.mode` | `BIDIRECTIONAL` | |
| `connection.mode` | `OUTBOUND` | |

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
| Case 1: Destination-initiated | ❌ No | Simple pull, one direction |
| Case 2: Source mode CR | ✅ Yes (`source.authentication`) | D reads from C over the reverse connection |
| Case 2: Destination mode CR | ❌ No | Passive, no connection |
| Case 3: Bidirectional (both OUTBOUND) | ⚠️ Yes for SASL-SSL (`dest.authentication` + `dest.tls`) | Each side has its own CR and connection; secured setups need local.* configs for bidirectional reads |
| Case 4: OUTBOUND CR | ✅ Yes (`dest.authentication` + `dest.tls`) | Single connection, D reads from C over it |
| Case 4: INBOUND CR | ✅ Yes (`dest.authentication` generated by CFK) | CFK generates local.* configs for bidirectional |

### clusterID vs kafkaRestClassRef

| Mode | Remote side needs | Notes |
|------|-------------------|-------|
| Unidirectional (Case 1) | `clusterID` (sufficient) | `kafkaRestClassRef` is an alternative but requires reachable REST API |
| Source CR (Case 2) | `clusterID` (sufficient) | Same as above |
| Destination CR (Case 2) | `clusterID` (required) | Remote is behind firewall, can't be reached |
| Bidirectional (Cases 3 & 4) | `clusterID` + `kafkaRestClassRef` (both) | CFK requires `kafkaRestClassRef` for bidirectional; use `clusterID` alongside it since REST-based discovery may not work cross-K8s |

---

## Common Issues & Troubleshooting

### Issue 1: Link creation fails with "cluster ID mismatch"

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

### Issue 2: "mirrorTopics not allowed" error in Source mode

**Symptoms:**
- Source mode CR fails validation
- Error: "mirrorTopics not allowed in Source mode"

**Root Cause:**
- `mirrorTopics` defined on Source mode CR

**Solution:**
- Move `mirrorTopics` to the Destination mode CR (the passive side)
- Source mode CR should not have `mirrorTopics` section

### Issue 3: Bidirectional link fails with "kafkaRestClassRef required"

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

### Issue 4: Case 4 INBOUND CR created after OUTBOUND

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

### Issue 5: Authentication failures in Source mode

**Symptoms:**
- Source-initiated link fails to authenticate
- "Authentication failed" errors

**Root Cause:**
- Wrong credentials used
- Confusion about which credentials go where in Source mode

**Solution:**
- Remember: Source mode is **FLIPPED**
- On Source CR:
    - `sourceKafkaCluster.authentication` → becomes `local.*` (for remote to read from local)
    - `destinationKafkaCluster.authentication` → for connecting TO remote
- On Destination CR:
    - No authentication needed (passive)

### Issue 6: Can't reach cluster's REST API

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

### Issue 7: Wrong link name between paired CRs

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

## Additional Resources

- [Confluent Cluster Linking Documentation](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/index.html)
- [CFK ClusterLink API Reference](https://docs.confluent.io/operator/current/co-api.html#tag/ClusterLink)
- GitHub PR: https://github.com/confluentinc/docs-operator/pull/1713#issuecomment-4011238173

---

