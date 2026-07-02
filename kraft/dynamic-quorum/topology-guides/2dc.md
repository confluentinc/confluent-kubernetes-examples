# 2DC (even-symmetric split across 2 regions)

> See [`README.md`](README.md) for the `alive/needed/configured` notation, and [`FAULT_TOLERANCE.md`](../FAULT_TOLERANCE.md) for the underlying KRaft fault-tolerance concepts this guide applies.

**Recommended: 3-3 (6 voters).** Use this for production. Tolerates 2 voter failures, headroom 2 in steady state, every commit forced to span both DCs by majority math (so RPO=0 on full-DC loss is structural).

**Avoid 2-2 (4 voters).** With majority=3 you tolerate exactly 1 voter failure, so a concurrent rolling restart that takes 1 pod down in each DC simultaneously (e.g. during a CFK upgrade) leaves you with 2 of 4 alive — quorum lost mid-roll. Too little headroom for a production cluster. If you must use 2-2, ensure rolling restarts are serialized across DCs.

**Don't go beyond 3-3.** 4-4 (8 voters, majority=5) and above don't add tolerated failures meaningfully — N=6→8 still tolerates only 2 voter losses (you can lose more pods within a single DC, but a full-DC failure remains the binding constraint). The extra voters just make every commit pay more acks. Stick with 3-3.

- **Fault tolerance**: with 3-3 (6 voters, majority=4), tolerates 2 voter failures. Losing a full region (3 voters) immediately exceeds the bound.
- **Availability**: any full-region failure = quorum lost. Manual `force-standalone` on the surviving region required. Single-pod failures within a region are absorbed without intervention.
- **Why even-symmetric?** Bounded RPO under full-DC loss. Asymmetric splits (2-3, 4-3, etc.) trigger the asymmetric-durability problem — the bigger DC alone is a majority and can ack writes intra-DC, so a bigger-DC failure causes unbounded RPO. The 3-3 split forces every commit to span both DCs (per-DC voters=3 < majority=4). See [The asymmetric-durability problem](../FAULT_TOLERANCE.md#the-asymmetric-durability-problem) for the full walkthrough and the RTO/RPO comparison.
- **`alive/needed/configured` walkthrough — 3-3 (rb-east, rb-west):**

  | Event | Layout | `alive/needed/configured` | Headroom | What to do |
  |---|---|---|---|---|
  | Healthy | 3-3 | 6/4/6 | 2 | — |
  | Lose 1 pod in 1 DC | 3-2 or 2-3 | 5/4/6 | 1 | No intervention needed; pod will come back. Don't shrink. |
  | Lose 2 pods in 1 DC | 3-1 or 1-3 | 4/4/6 | 0 | Fix the underlying issue and bring the pods back — that's the only safe action. Don't shrink: any shrink in 2DC turns the layout asymmetric (same hole as 2DC 2-3) |
  | Lose full DC (3 of 6 = **exactly N/2**) | 3-0 or 0-3 | 3/4/6 | -1 (quorum lost) | DR required, but **data-safe** (lost exactly N/2 — per the [Two thresholds](../FAULT_TOLERANCE.md#two-thresholds-availability-and-no-data-loss-recovery) rule). Sequence: `3/4/6 → force-standalone on surviving DC's most up-to-date voter (largest epoch, then offset) → 1/1/1 → add-controller on other survivors → 3/2/3` (cluster operational on surviving DC). When dead DC returns: pre-emptive `mv __cluster_metadata-0` on each returning controller → `add-controller` per returning pod → eventually back to `6/4/6`. See the DR sketch below. |
  | Lose 1 full DC + ≥1 more pod in surviving DC (4+ of 6 = **more than N/2**) | varies | quorum lost | quorum lost | DR required and **data-loss risk is real** (more than half the voter set is gone; commits could have been ack'd entirely within the dead set). Same `force-standalone` mechanics as the row above, but RPO > 0 is on the table. |

- **DR sketch** (3-3). Any full-DC loss triggers DR because the surviving DC alone is < majority.
  1. Identify the most up-to-date surviving voter with `kafka-metadata-recovery reconfig log-length` (it prints `epoch: E, log end offset: O`). Pick the **largest epoch, breaking ties by largest offset** — KRaft's up-to-date ordering. Not raw offset: a longer-but-lower-epoch log can be a stale branch missing committed records.
  2. Run `kafka-metadata-recovery reconfig force-standalone` on it → rewrites the voter set to a 1-voter quorum (`1/1/1`), propagated as a `VotersRecord` on the metadata log.
  3. The other surviving DC voters fetch, replay the `VotersRecord`, land as Observers.
  4. `add-controller` from each Observer to grow back to the surviving DC's voter count → final state `3/2/3`.
  5. When the dead DC returns: pre-emptively `mv __cluster_metadata-0` to a backup on each returning controller before main starts (split-brain protection), then let them fetch fresh from the recovered leader, then `add-controller` → eventual return to `6/4/6`.

  Full procedure: [`disaster-recovery/quorum-loss-recovery/`](../disaster-recovery/quorum-loss-recovery/).
