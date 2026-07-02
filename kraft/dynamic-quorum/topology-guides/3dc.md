# 3DC (symmetric split across 3 regions)

> See [`README.md`](README.md) for the `alive/needed/configured` notation, and [`FAULT_TOLERANCE.md`](../FAULT_TOLERANCE.md) for the underlying KRaft fault-tolerance concepts this guide applies.

**Recommended: 2-2-2 (6 voters, majority=4).** Use this for production 3DC. Tolerates 2 voter failures, every commit forced to span ≥2 DCs (per-DC voters=2 < majority=4), and commit latency stays low (only 4 acks per write). The walkthrough below uses 2-2-2 as the primary example.

**Avoid 1-1-1 (3 voters).** Same problem as 2DC 2-2 at a smaller scale: majority=2, tolerates only 1 voter failure. A concurrent rolling restart that takes 1 pod down in two different DCs = quorum lost mid-roll. Operational headroom is zero.

**3-3-3 (9 voters) is overkill.** It tolerates 4 voter failures vs 2 for 2-2-2, but most failure modes you care about are *DC-level*, not voter-level — and **2-2-2 already tolerates 1-DC loss with quorum intact**. The cost of 3-3-3: every commit needs 5 acks instead of 4, so every metadata write pays an extra cross-region hop in the slowest case. It also breaks the cross-DC-commit-forced guarantee — in 3-3-3, majority=5 can sit entirely inside any 2 of the 3 DCs (3+2=5), so the third DC may legitimately lag steady-state (see the [asymmetric-durability problem](../FAULT_TOLERANCE.md#the-asymmetric-durability-problem)). Use 3-3-3 only if you specifically need the within-DC headroom (e.g. you can't tolerate any single voter loss + a concurrent rolling restart).

The rest of this guide uses **2-2-2** unless explicitly noted.

- **Fault tolerance** (2-2-2): 6 voters, majority=4, tolerates 2 voter failures. Lose 1 region (2 voters) → 4 alive → quorum maintained (exactly at majority, headroom 0). Lose 2 regions (4 voters) → 2 alive → quorum lost, DR required.
- **Kafka data durability**: with brokers in all 3 regions and `RF=3, min.isr=2` and region-named `broker.rack`, partition assigner spreads replicas across all 3 regions. Lose 1 region: 2 of 3 replicas alive, ISR=2, writes succeed. Lose 2 regions: 1 of 3 replicas alive, writes block on min.isr=2 (until you lower min.isr or regions return).
- **RTO**: zero for any 1-region loss — cluster stays available end-to-end (KRaft + Kafka). Non-zero once you cross into 2-region loss — KRaft DR plus bringing brokers back. Same depends-on-readiness caveat as the smaller topologies.
- **RPO**: zero on 1-region loss for KRaft metadata (4 alive ≥ majority=4, no DR needed). For Kafka data: zero on 1-region loss with proper rack awareness (RF=3 spreads replicas across all 3 regions, surviving 2 DCs hold every partition). **2-region simultaneous loss is data-loss-risky** for KRaft metadata: 4 dead voters can themselves form a commit-majority (per-DC voters=2 across 2 DCs = 4 voters = majority), so a commit could have been ack'd entirely inside the dead set with the surviving DC's 2 voters never seeing it. Kafka topic data survives once any region returns. Same story for 3-3-3, just with different numbers (6 dead > majority=5).
- **Latency**: every write blocks until majority acks. **2-2-2 needs 4 of 6 acks, 3-3-3 needs 5 of 9**, 2DC 3-3 needs 4 of 6, 2.5DC 2-2-1 needs 3 of 5. Larger quorums add a metadata-write tax, particularly when one of the must-ack voters is in a distant region. Prefer 2-2-2 for 3DC unless you have a specific reason to size up.
- **`alive/needed/configured` walkthrough — 2-2-2 (rb-east, rb-central, rb-west):**

  | Event | Layout | `alive/needed/configured` | Headroom | What to do |
  |---|---|---|---|---|
  | Healthy | 2-2-2 | 6/4/6 | 2 | — |
  | Lose 1 region (e.g. rb-east) | 0-2-2 | 4/4/6 | 0 | Cluster keeps serving — quorum is exactly at majority, no further voter loss tolerated. Bring rb-east back as soon as possible. **Recommended interim**: leave the voter set at `4/4/6` and wait — a `remove-controller`+`add-controller` rebalance would have headroom=1 transiently but the asymmetric layout caveat applies (2-DC even-symmetric durability rule). |
  | Lose 2 regions | 0-0-2 (or similar) | 2/4/6 | quorum lost | DR required and **data-loss-risky**: 4 dead voters can themselves form a commit-majority (per-DC voters=2 across 2 DCs = 4 = majority), so commits could have been ack'd entirely inside the dead set. Use [`disaster-recovery/lossy-quorum-loss-recovery/`](../disaster-recovery/lossy-quorum-loss-recovery/). |

  For **3-3-3** the walkthrough is the same shape with `9/5/9 → 6/5/9 → 3/5/9`. Lose 1 region → 6 alive, headroom 1 (looser than 2-2-2 here). Lose 2 regions → 3 alive < majority 5 → **DR is also data-loss-risky** (`3/5/9` = 6 dead > majority 5). 3-3-3 buys you 1 extra unit of headroom on a 1-DC loss at the cost of an extra ack per write — both 2-2-2 and 3-3-3 hit lossy DR on 2-DC simultaneous loss; 3-3-3 doesn't improve the 2-DC story.

- **DR sketch** (2-2-2):
  - **1-DC loss** — quorum maintained (4 alive ≥ majority=4). No DR. Brokers in surviving DCs continue serving with reduced ISR; partitions whose RF=3 replicas span all 3 DCs drop to RF-1 in ISR but stay above `min.isr=2` and writes continue. Returning DC's brokers rejoin ISR automatically; KRaft voters rejoin as Observers and (CP 8.2+) auto-promote.
  - **2-DC simultaneous loss** — quorum lost; only 2 voters alive. `force-standalone` on the most up-to-date survivor (largest epoch, then offset) + `add-controller` to grow back to 2 voters works mechanically, but RPO > 0 — committed writes can be missing if they were ack'd entirely inside the 4-voter dead set. See [`disaster-recovery/lossy-quorum-loss-recovery/`](../disaster-recovery/lossy-quorum-loss-recovery/) for the lossy-DR procedure.

  Same story for 3-3-3: 2-DC loss is also data-loss-risky (6 dead > majority=5). 3-3-3 doesn't buy data-safety here, only an extra ack per commit.

  Full procedure: same primitives as 2.5DC lossy DR, in [`disaster-recovery/lossy-quorum-loss-recovery/`](../disaster-recovery/lossy-quorum-loss-recovery/) — adapt the topology mapping to a 3DC layout.
