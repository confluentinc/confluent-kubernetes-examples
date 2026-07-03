# KRaft Topology Deployment Guides

Per-topology references for KRaft fault tolerance across all the supported deployment shapes — single-region (with optional AZ-level HA) and multi-region. Each file is a worked walkthrough: voter math, `alive/needed/configured` state trajectories, RTO/RPO on failures, and DR sketches that point to the procedures in [`disaster-recovery/`](../disaster-recovery/).

If you are not yet familiar with the underlying math (majority-based fault tolerance, the two thresholds, the asymmetric-durability problem), read [`FAULT_TOLERANCE.md`](../FAULT_TOLERANCE.md) first — these per-topology files apply those concepts and don't re-derive them.

## Topologies

| Topology | File | When to use |
|---|---|---|
| **1DC (single region, optionally multi-AZ)** | [`1dc.md`](1dc.md) | One K8s cluster in one cloud region. Survives at most an AZ failure (with 3AZ HA pattern). Operationally simplest — one kubeconfig, one operator. Does NOT survive a full regional cloud outage. |
| **2DC 3-3** | [`2dc.md`](2dc.md) | Two regions only; need bounded RPO under full-DC loss. Any full-region failure is a DR event. 3-3 is the recommended layout — avoid 2-2 (too thin) and don't go bigger (no benefit). |
| **2.5DC 2-2-1** | [`2-5dc.md`](2-5dc.md) | Two Kafka-bearing regions plus a small "tiebreaker" region holding only a KRaft voter. Survives 1-region KRaft failure without DR; Kafka data durability is the same as 2DC. |
| **3DC 2-2-2** | [`3dc.md`](3dc.md) | Three full Kafka-bearing regions. Survives 1-region failure end-to-end (KRaft + Kafka). 2-2-2 is the recommended layout — avoid 1-1-1 (too thin) and prefer 2-2-2 over 3-3-3 (extra voter doesn't add tolerated failures, just slows writes). |

For a head-to-head comparison table and a "when to choose what" decision guide across all topologies, see [`choosing-a-topology.md`](../choosing-a-topology.md).

## Notation used in these files

Each topology file uses an `alive/needed/configured` shorthand for the quorum state:

- **alive**: voters currently up and reachable.
- **needed**: minimum voters required to commit a write — majority of `configured`, i.e. `floor(configured/2) + 1`.
- **configured**: total voters in the `VotersRecord`. This is what `remove-controller` / `add-controller` modifies.

**Headroom** = `alive − needed`. Once headroom hits 0, the next voter failure tips the cluster below quorum. **Failures change `alive`. Membership changes (shrink/grow) change `configured`** (and possibly `needed`).

A healthy cluster always has `alive = configured`, but during a failure the two diverge — that's the state these walkthroughs are reasoning about.

## DR procedures

The step-by-step DR procedure (scripts, exec commands, recovery sequence) lives in [`disaster-recovery/`](../disaster-recovery/). Each topology file's "DR sketch" section summarizes which procedure applies for which failure mode.
