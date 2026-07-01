# KRaft Fault Tolerance for Dynamic-Quorum Clusters

This document is the **conceptual reference** for KRaft metadata-quorum fault tolerance: the majority-based fault-tolerance math, the two-thresholds rule, the asymmetric-durability problem, what dynamic quorum changes about the operations around the bound, and the scope of auto-join.

Internalize these and you can reason about any KRaft topology from first principles. Per-topology worked walkthroughs apply these concepts to specific deployment shapes — they live in sibling files so this one stays focused on the math.

**Related files:**

- [`ack-semantics.md`](ack-semantics.md) — Two layers of fault tolerance (KRaft metadata + Kafka topic data) and the difference between KRaft and Kafka write-acknowledgement rules. Read this if you're not already clear on how the KRaft layer relates to the Kafka layer.
- [`pod-and-replica-placement.md`](pod-and-replica-placement.md) — K8s + Kafka plumbing for spreading pods (`topologySpreadConstraints`) and partition replicas (`broker.rack`) across AZs / regions.
- [`topology-guides/`](topology-guides/) — per-topology references: [1DC](topology-guides/1dc.md), [2DC](topology-guides/2dc.md), [2.5DC](topology-guides/2-5dc.md), [3DC](topology-guides/3dc.md).
- [`choosing-a-topology.md`](choosing-a-topology.md) — head-to-head topology comparison table + when-to-choose decision guide.
- [`disaster-recovery/`](disaster-recovery/) — step-by-step DR procedures (exec commands, recovery sequence).

## How many voter failures can a KRaft quorum tolerate?

For any quorum of N voters:

- **Majority needed (acks per write)** = `floor(N/2) + 1`
- **Tolerated voter failures while still serving writes** = `N - majority` = `floor((N-1)/2)`

| Voters (N) | Majority needed | Tolerated voter failures |
|---|---|---|
| 1 | 1 | 0 |
| 2 | 2 | 0 |
| 3 | 2 | 1 |
| 4 | 3 | 1 |
| 5 | 3 | 2 |
| 6 | 4 | 2 |
| 7 | 4 | 3 |
| 8 | 5 | 3 |
| 9 | 5 | 4 |

Two things to notice. **(1) Adding one voter only buys an extra tolerated failure on every other step** — going N=2k+1 → N=2k+2 just raises the majority threshold by 1 without changing tolerated failures. That's why pure-Raft sizing often picks odd N: it's the efficient choice when the only constraint is voter count. **(2) Going from N → N+1 across the wrong boundary actually costs you operationally** — same tolerated failures, but every commit pays one more ack. N=4 vs N=3 is the worst case: both tolerate 1 failure, but N=4 needs 3 acks per write instead of 2.

Real KRaft topologies still use even N anyway because the failure unit is **a domain (DC / AZ), not a voter** — 2DC 3-3 (6 voters) packs 3 voters per DC because each DC must hold strictly less than a commit-majority to satisfy the [asymmetric-durability rule](#the-asymmetric-durability-problem) below. N=5 across 2 DCs would force an asymmetric 2-3 split, which is a worse trade than running N=6.

Concrete topologies this doc covers and where they sit in the table: **1DC 3AZ 1-1-1 → N=3**, **2.5DC 2-2-1 → N=5**, **2DC 3-3 → N=6**, **3DC 2-2-2 → N=6**, **3DC 3-3-3 → N=9**.

> **Voter count vs write latency.** Every KRaft metadata write blocks until majority acks, so more voters = more replication overhead per write. Larger voter counts also mean each commit has more "tail latency exposure" — the slowest of the majority-of-N voters gates the ack. **Above ~5 voters, measure commit latency on your workload before committing to the topology** (e.g. produce-rate at the throughput you actually need, with realistic cross-region / cross-AZ network latencies). 3DC 3-3-3 (9 voters, majority=5) is where this typically shows up — prefer 3DC **2-2-2** (6 voters, majority=4) unless you specifically need the within-DC headroom.

## Two thresholds: availability and no-data-loss recovery

Two distinct thresholds matter when reasoning about voter loss:

1. **Availability** — how many voters you can lose while the cluster stays up on its own.
2. **No-data-loss recovery** — how many simultaneous voter losses still let `force-standalone` recover the cluster *without dropping any committed write*.

These thresholds are different. Crossing the first means "do DR." Crossing the second means "DR works, but you may lose data."

### N=6 (e.g. 2DC 3-3)

- **Availability**: maintained while ≤ 2 pods are down. Lose a 3rd pod → quorum lost, cluster unavailable until you run `force-standalone`.
- **No-data-loss recovery**: holds while ≤ 3 pods are down together. If 4+ pods go down together, recovery on the remaining pods can't guarantee no data loss — the 4 dead pods could have been the majority that ack'd recent commits, and no survivor has those writes.

### N=5 (e.g. 2.5DC 2-2-1)

- **Availability**: maintained while ≤ 2 pods are down. Lose a 3rd pod → quorum lost, recovery required.
- **No-data-loss recovery**: holds while ≤ 2 pods are down together. If 3+ pods go down together, recovery on the remaining 2 pods can't guarantee no data loss.

### Why these specific numbers

A commit needs **majority** acks (`floor(N/2) + 1`). If the *dead* set has more than half of N, then the dead set is itself a majority — a commit could have been ack'd entirely within those now-dead voters, and no survivor ever saw it. `force-standalone` on the most up-to-date survivor (largest epoch, then offset) can't recover writes that aren't on any survivor. Standard Raft majority-intersection argument.

So the no-data-loss recovery threshold = **"lose at most half"**:
- For **even N** (like 6): you can lose exactly N/2 (= 3) safely.
- For **odd N** (like 5): you can lose strictly less than N/2 (= 2 max), which happens to equal the availability threshold — no gap between them.

## The asymmetric-durability problem

The two-thresholds rule says "lose more than half → DR can lose data." A subtler variant of the same idea bites *before* you ever cross the threshold: when the **voter layout** is asymmetric across failure domains, a commit-majority can sit entirely inside one domain. Losing that domain means the survivors never saw the writes — same data-loss mechanism, just triggered by topology choice rather than by failure count.

### The 2-3 walkthrough (2DC asymmetric example)

Take a 2DC cluster with an asymmetric **2-3** split: 5 voters total, majority=3. The 3-voter DC is by itself a majority. The leader can ack a write after 3 voters confirm — and those 3 can all be in the bigger DC. The smaller DC's 2 voters never had to acknowledge that write.

If a network partition cuts the DCs apart, the bigger DC keeps writing (it still has its self-sufficient majority); the smaller DC is cut off and lagging. If the bigger DC then fails entirely, the smaller DC is the only surviving quorum but it's missing committed writes that were ack'd before the partition. Two sub-cases follow:

- **Bigger DC's data is unrecoverable** (datacenter physically destroyed, disks deleted, prolonged outage with no recovery, etc.) — the writes that were ack'd only in the bigger DC are gone for good. Permanent **data loss**, regardless of what you do next.
- **Bigger DC's disks are intact, just unreachable** — you have a choice: (a) wait for it to come back, which preserves the writes but leaves the cluster unavailable until it does; or (b) run DR (`force-standalone`) on the smaller DC to make the cluster available now — but the new leader, elected from the smaller DC, doesn't have the writes that were committed inside the bigger DC. When the bigger DC eventually returns, its old metadata log gets wiped as part of split-brain protection. Net: you trade those committed writes for availability — data loss is the price of recovering fast.

### The general principle

A commit needs to be ack'd by a *majority* of the configured voter set. **If any single failure domain contains a commit-majority on its own, that domain can ack writes intra-domain.** When that domain fails, the writes can be lost.

The fix is to size voter layouts so that **no single failure domain holds a commit-majority** — i.e. for every failure domain `D`, `voters_in_D < majority`. This forces every commit to span ≥2 failure domains.

Where this principle shows up across topologies:

- **[2DC](topology-guides/2dc.md)**: the **3-3 split** (6 voters, majority=4) satisfies the rule (per-DC voters=3 < majority=4). Asymmetric splits (2-3, etc.) violate it. This is *the* reason 3-3 is the recommended 2DC layout. (Avoid 2-2 — too thin for rolling restarts; see the 2DC guide.)
- **[2.5DC](topology-guides/2-5dc.md) post-shrink**: after losing the 2-voter main region and shrinking 5→3, the layout is 2-1 across surviving DCs. Majority=2 fits inside the 2-voter DC — same hole. See the rebalance discussion in the 2.5DC topology guide.
- **[3DC](topology-guides/3dc.md) 2-2-2** (the recommended layout, 6 voters, majority=4): satisfies the rule — per-DC voters=2 < majority=4, so every commit must span at least 2 DCs. **3DC 3-3-3 does NOT** — majority=5 can sit entirely inside any 2 of the 3 DCs (3+2=5), so the third DC may lag steady-state and a 2-DC simultaneous loss triggers the asymmetric-durability hole.

### RTO / RPO comparison for 2DC splits

| Split | RPO on full-DC loss | RTO on full-DC loss |
|---|---|---|
| 3-3 (symmetric, satisfies the rule) | **0** — every committed write was already on both DCs (per-DC voters=3 < majority=4) | **non-zero** — manual `force-standalone` + observer rejoin. Actual time depends on your runbook readiness; rehearse the procedure to measure your environment. |
| 2-3 (asymmetric, bigger DC fails) | **> 0, unbounded** — equal to whatever the smaller DC was lagging by | non-zero, plus a hard call: accept the data loss or wait for the bigger DC to return. |
| 2-3 (asymmetric, smaller DC fails) | 0 — bigger DC has all writes | near-zero — bigger DC is a self-sufficient majority, no DR needed. But you can't choose which DC fails. |

The per-topology guides reference this principle when relevant — they don't re-derive it.

## What dynamic quorum changes

The fault-tolerance bound is *the same* for static and dynamic KRaft. What dynamic adds:

1. **Shrink during normal ops.** If a voter is permanently lost, you can `remove-controller` it and shrink the quorum (5 → 3) without restarting any other controller. Static would require editing `controller.quorum.voters` on every controller and rolling restart.
2. **Smoother DR rebuild.** When `f` is exceeded and you do `force-standalone`, the rewritten voter set propagates as a `VotersRecord` on the metadata log. Surviving controllers fetch and replay; no `controller.quorum.voters` config edit, no rolling restart of healthy controllers.
3. **Continue post-DR with reduced capacity.** `force-standalone` always produces a 1-voter quorum; from there you `add-controller` back up to whatever reduced count the surviving region supports (e.g. 2 in 2.5DC, 3 in 2DC 3-3) at operational pace. No rolling restart of survivors.
4. **Rebalance the voter set live during a failure.** When a region dies, you can change the voter layout (add voters in surviving regions, remove dead voters) without rolling restart of survivors — restoring availability headroom and (optionally) preserving cross-DC durability against a *second* region loss. See the [2.5DC topology guide](topology-guides/2-5dc.md) for the worked example and the difference between shrink-first and grow-first ordering.

The bound is the same; the *operations around the bound* are smoother in dynamic.

## Auto-join (CP 8.2+): what it does and doesn't do

`controller.quorum.auto.join.enable=true` (CP 8.2+ default) automates one specific step: when a controller pod is in **Observer** state and a healthy quorum exists, the controller requests promotion to **Voter** automatically — no manual `add-controller` needed. Useful, but commonly oversold. Two misconceptions worth flagging:

**Misconception 1: "Auto-join rescues us during DR."** No. Auto-join requires an existing **healthy quorum** to process the promotion request — there has to be a leader to accept the AlterRaftVoter RPC. If you've lost more than half of N and quorum is gone, there's no one to ask. You still need `force-standalone` to rebuild a 1-voter quorum the hard way. Auto-join only helps **after** quorum is restored, when new observers are joining a working cluster.

**Misconception 2: "Restarting a voter pod relies on auto-join to make it a voter again."** No. A pod that was a voter before restart is **still a voter** when it comes back, because:
- Its `directory.id` (in `meta.properties` on the data volume) is preserved across restarts.
- The voter set lives in the `VotersRecord` on the metadata log, not in pod state.
- A voter's identity in the quorum is the `(node.id, directory.id)` tuple, which doesn't change.

The returning pod resumes its previous Voter role directly. Auto-join doesn't do anything here because there's no Observer-to-Voter promotion to perform.

**Where auto-join actually helps:**
- A fresh KRaftController pod is added (scale-up — supported via CFK when `dynamicQuorumConfig.enabled: true`). The new pod starts as an Observer with a new `directory.id` (different from any current voter), and auto-join handles the Observer → Voter promotion.
- A pod whose data was wiped during DR (e.g. the Phase 2 region-restore clearing `__cluster_metadata-0` for split-brain protection) rejoins as Observer fetching from the recovered leader, then auto-joins back to Voter.

Note: ZK→KRaft migration is **out of scope for auto-join** because ZK was removed in CP 8.0; the migration only runs on CP 7.x (7.9.x for dynamic quorum), where auto-join doesn't exist. ZK→KRaft observer promotion always requires manual `add-controller`.

**When auto-join is NOT enabled (CP < 8.2):**
- The Observer → Voter scenarios above require **manual `add-controller`** from the rejoining pod (see [`disaster-recovery/`](disaster-recovery/)).
- The DR sketches in the per-topology guides assume the manual path for portability across CP versions.

## External references

- [KIP-853](https://cwiki.apache.org/confluence/display/KAFKA/KIP-853%3A+KRaft+Controller+Membership+Changes) — dynamic KRaft membership (the upstream design this doc applies to CFK)

For the in-repo sibling files, see the **Related files** list at the top of this doc.
