# DR: KRaft Quorum Loss Recovery — 2.5DC 2-2-1 (LOSSY) — CFK 3.2

The **lossy** 2.5DC variant of the CFK 3.2 pod-overlay-sidecar path. The recovery *steps are
identical* to the data-safe 2DC example — same pod-overlay-sidecar mechanism, same
`log-length` → seed → `force-standalone` → rejoin sequence. **The only difference is data
safety.** The full manual walkthrough and gotchas live once,
in the canonical [**data-safe CFK 3.2 README**](../../quorum-loss-recovery/cfk-3.2/README.md)
— read it for the steps, then come back here for the lossy-specific caveats.

> ## ⚠ READ FIRST — this procedure can lose committed writes
>
> N=5, majority=3, and the dead set in this scenario (dc1's 2 voters + dc3's tiebreaker =
> **3 voters**) **equals** majority. A commit can have been ack'd entirely inside that dead
> set, so no survivor is guaranteed to hold it — recovery rebuilds from dc2's most
> up-to-date survivor (largest epoch, then offset), which by definition never saw those
> writes. **RPO is unbounded and undetectable after the fact.** The structural argument and
> the general rule (`no-data-loss DR holds only while the dead set ≤ floor(N/2)`) are in
> [`FAULT_TOLERANCE.md`](../../../FAULT_TOLERANCE.md#two-thresholds-availability-and-no-data-loss-recovery).
>
> **Before starting Phase 1, confirm you accept unknown RPO.** Prefer waiting if
> dc1/dc3's disks are intact (waiting preserves all data); reconcile from an external
> source of truth if you have one; tell downstream consumers the metadata timeline is being
> rewritten. Kafka topic data on dc2's brokers is untouched throughout; dc1's broker data
> survives on retained PVs but may be inconsistent with the post-DR metadata view.
>
> The data-safe sibling (full-DC loss in 2DC even-symmetric, dead set < majority) is
> [`quorum-loss-recovery/`](../../quorum-loss-recovery/cfk-3.2/README.md). If quorum is
> **still healthy** (only a minority of voters lost), use
> [`no-quorum-loss-recovery/`](../../no-quorum-loss-recovery/) instead.

## Topology

- 5 voters: dc2 = {100,101}, dc1 = {200,201}, dc3 = {300}. Majority = 3.
- **Init (bad):** dc1 + dc3 down → only {100,101} alive < 3 → no leader.
- **Final:** dc2 running a 2-voter quorum, dc1 + dc3 rejoined → back to 5 voters, **unknown RPO**.
- **RPO: non-zero / unbounded** (committed writes can be lost — see the READ FIRST box). **RTO** = the time to run Phase 1 by hand (lower with the plugin) — the data loss, not the recovery time, is what differs from the data-safe path.

(The data-safe example grows dc2 back to 3 voters; here it's 2. That's the only step-count difference.)

## Prerequisites

- KRaft cluster across the 2.5DC regions, a majority of voters down, all KRaft + Kafka PVs `reclaimPolicy: Retain`.
- CFK operator running with `--podoverlay-enabled=true`, able to roll the surviving region's `KRaftController` CR.
- A dynamic-quorum cluster deployed in a 2.5DC 2-2-1 layout — adapt the greenfield MRC example ([`../../../greenfield/mrc/`](../../../greenfield/mrc/)).
- **Snapshot the KRaft PVs first** and clean up afterwards — [parent README](../../README.md#before-you-start-snapshot-the-kraft-pvs).

## Simulating the failure (test rehearsal only)

In a real disaster the regions are already down; to rehearse, scale dc1 + dc3's controllers to 0 or cordon/force-delete their pods to *fake* the outage. In a real outage there is nothing to cordon and nothing to uncordon — skip it, and skip the uncordon in Phase 2.

## Run it (manual)

Identical to the [canonical data-safe walkthrough](../../quorum-loss-recovery/cfk-3.2/README.md#run-it-manual)
— just 2 surviving controllers in dc2 ({100,101}) instead of 3, and the data-loss caveat
above applies to the `force-standalone` step (here it doesn't change the outcome: the dead
set was a commit-majority, so no survivor holds the lost writes regardless of which seed
you pick). Bring the dead regions back one at a time (Phase 2), following the manual Phase 2
steps in [`../cfk-3.3/manual-recovery/README.md`](../cfk-3.3/manual-recovery/README.md) to
restore each dead region.

**Phase 1 is complete** once the surviving region's 2-voter quorum is healthy —
producers/consumers and new-topic creation work (verified on CP 8.1.2 and 7.9.6).
Phase 2 restores N-voter resilience and is **not urgent**.

## Gotchas

All the gotchas from the [canonical README](../../quorum-loss-recovery/cfk-3.2/README.md#gotchas)
apply (sidecar-only-on-reachable-region, `--podoverlay-enabled`, element-ordering fix,
controller-must-be-down, narrow move scope, CP<8.2 no auto-join, stale overlay annotation,
PVC-race), as does the underlying-disk-deleted edge case ([deleted-disk recovery](../../../TROUBLESHOOTING.md#disk-deleted)).
One is lossy-specific:

- **Split-brain hazard on dead-region return.** If a dead region's kraft pods come back with
  their old (superseded-timeline) metadata and reach each other but not the recovered leader,
  they can form a rogue quorum. The defense is to clear their metadata before main starts —
  Phase 2 does this on the *returning* region via the pod-overlay sidecar. The
  pod-overlay sidecar can only act on a *reachable* region; if a region is genuinely unreachable
  there is no in-cluster defense — wait it out or race to apply maintenance-mode as it
  returns. Document this in your runbook. **Run Phase 2 one region at a time** (parallel runs
  race the overlay annotation).

## References

- [Canonical data-safe CFK 3.2 README (full steps, gotchas, appendix)](../../quorum-loss-recovery/cfk-3.2/README.md) · [CFK 3.3 manual](../cfk-3.3/manual-recovery/README.md) · [CFK 3.3 plugin](../cfk-3.3/kubectl-plugin-recovery/README.md)
- [`FAULT_TOLERANCE.md`](../../../FAULT_TOLERANCE.md) · [`ack-semantics.md`](../../../ack-semantics.md) · [2.5DC topology guide](../../../topology-guides/2-5dc.md)
- [KIP-853](https://cwiki.apache.org/confluence/display/KAFKA/KIP-853%3A+KRaft+Controller+Membership+Changes)
