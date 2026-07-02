# 1DC Deployment Guide (single region — can be single-AZ or multi-AZ)

> See [`FAULT_TOLERANCE.md`](../FAULT_TOLERANCE.md) for the underlying KRaft fault-tolerance concepts this guide applies (majority math, two thresholds, asymmetric durability), and [`pod-and-replica-placement.md`](../pod-and-replica-placement.md) for the K8s + Kafka plumbing that spreads pods and replicas across AZs.

A 1DC deployment is **one K8s cluster in one cloud region**. Within that region, the cluster's worker nodes can live in **a single AZ** (no within-region fault tolerance) or **spread across multiple AZs** (typically 3, for AZ-level HA). The shape of the deployment from CFK's perspective is the same either way — one K8s cluster, one operator, one namespace, one Kafka CR, one KRaft CR. Multi-AZ vs single-AZ is a node-placement / scheduling decision, not a different topology.

**Operational simplicity is the main reason to choose 1DC.** One K8s cluster means:
- One kubeconfig context to drive everything (`kubectl exec`, DR scripts).
- One operator deployment, one set of CRs, one CFK reconcile loop.
- One DNS namespace — no cross-cluster service discovery, no advertised-listeners juggling for cross-region traffic.
- Cloud-provider-managed networking inside the region — no manual cross-cluster networking, no LoadBalancers needed for inter-region controller traffic, no public-DNS-only listener constraints.

The cost: 1DC **does not survive a full regional cloud outage**, regardless of how many AZs you span within the region. AZ-level fault tolerance is the ceiling. If you need to survive regional outages, regulatory data-residency requirements across regions, or low latency to far users, multi-DC ([2DC](2dc.md), [2.5DC](2-5dc.md), [3DC](3dc.md)) is required.

## Within-region HA: the 3AZ pattern

If you want AZ-level fault tolerance within 1DC, the standard pattern is **3AZ**: spread KRaft and Kafka pods across 3 availability zones so a single-AZ failure doesn't take the cluster down. Cloud providers (GKE multi-zone, EKS multi-AZ, AKS zonal) make multi-AZ node groups a one-command setup. The deployment plumbing (how to spread pods across AZs + tell Kafka each broker's rack) is covered in [`pod-and-replica-placement.md`](../pod-and-replica-placement.md); the rest of this section focuses on **voter layout** within the 3AZ pattern.

Voter-layout options inside the 3AZ pattern:

- **1-1-1 (3 voters, one per AZ).** Minimum sensible KRaft inside a 3AZ. Majority=2, tolerates 1 AZ failure. Cross-AZ commits *forced* (per-AZ max = 1 < majority = 2), so every commit spans 2 of 3 AZs. Lowest commit latency of any 3AZ layout (only 2 acks needed). **Trade-off**: zero within-AZ redundancy — a single pod failure or restart in any AZ = that AZ is effectively down for KRaft, headroom=0 the moment you lose any one pod, rolling restarts are tight. Same operational risk as the 2DC 2-2 / 3DC 1-1-1 problem: a concurrent rolling restart that takes 1 pod down in two different AZs simultaneously tips you below quorum. Use 1-1-1 only when operational discipline keeps voter loss to one-at-a-time.
- **2-2-2 (6 voters)** — the safer default for 3AZ if you can afford the voter count: majority=4, cross-AZ commit forced (per-AZ voters=2 < majority=4), tolerates 2 voter failures so rolling restarts have real headroom. 4 acks per commit vs 2 in 1-1-1.

**`alive/needed/configured` walkthrough — 1-1-1 across 3 AZs (rb-zone-a, rb-zone-b, rb-zone-c):** (notation defined in [`README.md`](README.md#notation-used-in-these-files))

| Event | Layout | `alive/needed/configured` | Headroom | What to do |
|---|---|---|---|---|
| Healthy | 1-1-1 | 3/2/3 | 1 | — |
| Lose 1 AZ (e.g. rb-zone-a) | 0-1-1 | 2/2/3 | 0 | No DR needed; bring the AZ back as soon as possible. Don't shrink — `2/2/2` needs the same 2 acks and just makes you regrow when the AZ returns. |
| Lose 2 AZs | varies | 1/2/3 | -1 (quorum lost) | **Out of scope** — see DR sketch below; 3AZ-within-1DC is designed for 1-AZ failure only. |

## Caveats and DR

- **Shared K8s control plane.** Single K8s cluster = single failure domain for the operator. If the K8s control plane goes down (rare for managed K8s — providers run it across AZs themselves), all AZs lose operator-driven reconciliation simultaneously, even though the data plane (KRaft + Kafka pods) keeps running.
- **DR sketch** (3AZ case): single-AZ loss is absorbed without DR (quorum maintained). **2-AZ simultaneous loss and full-region loss are both out of scope for this topology** — 3AZ within 1DC is designed to survive at most 1 AZ failure, and anything beyond that crosses the topology's design ceiling. If you need to survive multiple-AZ or regional failures, use multi-DC instead; that's the use case multi-DC exists for, and the DR procedures in [`disaster-recovery/quorum-loss-recovery/`](../disaster-recovery/quorum-loss-recovery/) target that.
- **Single-AZ 1DC**: no DR option for AZ loss. The AZ going down takes the cluster with it. Acceptable only when the cluster's availability requirements tolerate that, or when you have a separate cross-region replication story (cluster linking, MirrorMaker) outside the scope of this doc.
