# Choosing a Topology

Side-by-side comparison of the supported KRaft topologies and a "when to choose what" guide. This doc does **not** rank the topologies — each has a different trade profile; pick what fits the regions you actually have and the operational mode you want.

For the per-topology worked walkthroughs:
- [1DC (single region, optionally multi-AZ)](topology-guides/1dc.md)
- [2DC](topology-guides/2dc.md), [2.5DC](topology-guides/2-5dc.md), [3DC](topology-guides/3dc.md) — under [`topology-guides/`](topology-guides/)

For the underlying KRaft fault-tolerance concepts (majority math, two thresholds, asymmetric durability, dynamic quorum, auto-join), see [`FAULT_TOLERANCE.md`](FAULT_TOLERANCE.md).

## Summary table

The table compares topologies at the level of their natural **failure unit** — AZ for 1DC 3AZ, region for multi-DC. Each column's "Lose 1 unit" rows apply that unit.

| | 1DC 3AZ (1-1-1) | 2DC 3-3 | 2.5DC 2-2-1 | 3DC 2-2-2 |
|---|---|---|---|---|
| **Voters (N)** | 3 | 6 | 5 | 6 |
| **Majority (acks needed)** | 2 | 4 | 3 | 4 |
| **Tolerated voter failures (f)** | 1 | 2 | 2 | 2 |
| **Failure unit** | AZ | region | region | region |
| **Number of failure units** | 3 (AZs within 1 region) | 2 | 3 | 3 |
| **Kafka brokers in** | all 3 AZs | both regions | 2 of 3 regions (none in tiebreaker) | all 3 regions |
| **Lose 1 unit → KRaft** | quorum maintained | quorum lost — DR required (data-safe, see [Two thresholds](FAULT_TOLERANCE.md#two-thresholds-availability-and-no-data-loss-recovery)) | quorum maintained | quorum maintained (4 alive = majority, headroom 0) |
| **Lose 1 unit → Kafka data** | writes continue (RF=3 spread across 3 AZs) | writes may block — RF=3 across 2 regions splits 2-1, the 2-replica region loss drops some partitions' ISR below `min.isr=2` | if broker region lost: same as 2DC. If tiebreaker lost: no impact (no brokers there) | writes continue (RF=3 spread across 3 regions) |
| **Lose 2+ units (beyond design ceiling)** | DR-risky — data loss possible. See [Two thresholds](FAULT_TOLERANCE.md#two-thresholds-availability-and-no-data-loss-recovery) | (n/a — only 2 regions; the row above is already full-loss) | DR-risky — data loss possible. **1.5DC loss** (1 broker DC + tiebreaker): KRaft DR on surviving broker DC, RPO>0; Kafka data on the surviving broker DC stays alive. **2-DC loss** (both broker DCs): **Kafka data and service gone** — brokers only lived in those 2 DCs. | DR-risky — data loss possible. Lose 2 of 3 regions = 4 dead > `floor(N/2)=3`; a commit-majority can sit entirely inside the 4-voter dead set. Kafka data survives once any region's brokers return (RF=3 across all 3 regions). |
| **Survives full regional cloud outage?** | **no** (single region) | yes after DR (`force-standalone` on surviving region) | yes for KRaft; partial for Kafka data (only 2 broker regions) | yes (1-region loss absorbed end-to-end) |
| **Commits forced to span ALL units?** | no — span 2 of 3 AZs (third may lag) | yes — every commit spans both regions | no — span 2 of 3 regions (third may lag) | yes — every commit spans ≥2 of 3 DCs (per-DC voters=2 < majority=4) |
| **Commit latency (acks of N)** | 2 of 3 | 4 of 6 | 3 of 5 | 4 of 6 |

The voter counts above are concrete examples. Two sizing rules this doc takes positions on:

- **Avoid 2-2 for 2DC** — f=1 is too thin for rolling restarts (concurrent 1-pod-per-DC roll = quorum lost). See [`topology-guides/2dc.md`](topology-guides/2dc.md).
- **Avoid 1-1-1 for 3DC** — same problem at a smaller scale. See [`topology-guides/3dc.md`](topology-guides/3dc.md).

For other sizing trade-offs (more voters = more acks per commit), see the voter-count-vs-write-latency callout in [`FAULT_TOLERANCE.md`](FAULT_TOLERANCE.md).

Larger 1DC/3AZ layouts (2-2-2, 3-3-3 within one region's AZs) inherit the equivalent multi-DC row's math at the KRaft layer; the difference is the failure-domain unit (AZ vs region) and the regional-outage column.

## When to choose what

Confluent's metadata-team recovery runbook is written against the **2DC even-symmetric** topology, so that's the shape with the canonical, tested DR procedure — useful context but not a recommendation.

- **[1DC (single region, optionally multi-AZ for HA)](topology-guides/1dc.md)**: one K8s cluster in one cloud region. Nodes can sit in a single AZ (no within-region fault tolerance) or spread across 3 AZs for AZ-level HA (3AZ pattern; 1-1-1 voter layout is the minimal sensible version). Operationally simplest of all the options — one kubeconfig, one operator, one namespace, one Kafka CR, one KRaft CR; cloud provider handles in-region networking. **Does not survive a full regional cloud outage** regardless of AZ spread — that's what multi-DC exists for. Choose when AZ-level fault tolerance is enough and you want to skip the operational complexity of multi-cluster.
- **[2DC 3-3](topology-guides/2dc.md)**: every commit is forced to span both DCs by majority math, so RPO=0 on full-DC loss is structural. Any full-region failure is a DR event (`force-standalone`). This is the topology the kafka-metadata team has a runbook for. Avoid 2-2 (too thin for rolling restarts).
- **[2.5DC 2-2-1](topology-guides/2-5dc.md)**: a "cheap third region" variant that adds a small tiebreaker region holding 1 KRaft voter. KRaft survives a 1-region failure without DR; Kafka data still lives in only 2 regions, so data durability story is unchanged from 2DC. After 1-region loss, shrink to `3/2/3` is a healthy end state; growing the tiebreaker region to symmetric 2-2 (Path B in the 2.5DC section) is a theoretical refinement that closes a beyond-design-ceiling data-loss window but isn't currently CFK-supported.
- **[3DC 2-2-2](topology-guides/3dc.md)**: KRaft tolerates 1 full region loss with quorum intact (4 alive = majority); Kafka data survives 1 region loss with `RF=3` + region-named rack. Every commit forced to span ≥2 DCs (per-DC voters=2 < majority=4). 2-region simultaneous loss exceeds the `floor(N/2)=3` safe-recovery threshold (4 dead) so DR is lossy at that point. Avoid 1-1-1 (too thin for rolling restarts).
