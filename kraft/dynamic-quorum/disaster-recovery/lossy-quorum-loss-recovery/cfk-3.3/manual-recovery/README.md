# DR: KRaft Quorum Loss Recovery — 2.5DC 2-2-1 (lossy) — CFK 3.3 manual

The **lossy** 2.5DC variant of the CFK 3.3 manual path. The recovery *steps are identical*
to the data-safe 2DC example — same maintenance-mode mechanism,
same `log-length` → seed → `force-standalone` → rejoin sequence. **The only difference is
data safety.** So the full walkthrough, the "what changed from CFK 3.2" table, and the
gotchas live once, in the canonical
[**data-safe CFK 3.3 manual README**](../../../quorum-loss-recovery/cfk-3.3/manual-recovery/README.md)
— read it for the steps, then come back here for the lossy-specific caveats. For the
automated version use the [kubectl-plugin path](../kubectl-plugin-recovery/README.md).

> ## ⚠ READ FIRST — this procedure can lose committed writes
>
> 2.5DC 2-2-1 = 5 voters, majority = 3. Losing dc1 + dc3 kills 3 of 5 — the dead set
> **equals** the majority, so a committed write could have lived entirely on the dead set.
> `force-standalone` rebuilds from the most up-to-date *survivor* (largest epoch, then
> offset), which by definition never saw those writes. **RPO is unbounded and undetectable
> after the fact.** Before starting Phase 1, confirm you accept unknown RPO; prefer
> waiting if dc1/dc3's disks are intact. The data-safety math is in
> [`FAULT_TOLERANCE.md`](../../../../FAULT_TOLERANCE.md). The data-safe sibling (2DC 3-3,
> dead set < majority) is [`quorum-loss-recovery/`](../../../quorum-loss-recovery/cfk-3.3/manual-recovery/README.md).

## Topology

- 5 voters: dc2 = {100,101}, dc1 = {200,201}, dc3 = {300}. Majority = 3.
- **Init (bad):** dc1 + dc3 down → only {100,101} alive < 3 → no leader.
- **Final:** dc2 running a 2-voter quorum, dc1 + dc3 rejoined → back to 5 voters, **unknown RPO**.
- **RPO: non-zero / unbounded** (committed writes can be lost — see the READ FIRST box). **RTO** = the time to run Phase 1 by hand (lower with the plugin) — the data loss, not the recovery time, is what differs from the data-safe path.

(The data-safe example grows dc2 back to 3 voters; here it's 2. That's the only step-count difference.)

## Prerequisites

- CFK **3.3+** operator + init image (maintenance mode; mounted
  `kafka-client.properties`).
- 2.5DC 2-2-1 cluster — deploy a dynamic-quorum cluster (adapt the greenfield MRC example, [`../../../../greenfield/mrc/`](../../../../greenfield/mrc/)).
- All KRaft + Kafka PVs `reclaimPolicy: Retain`. **Snapshot the KRaft PVs first** and clean
  up afterwards — [parent README](../../../README.md#before-you-start-snapshot-the-kraft-pvs).

## Overview

Before you start, set your contexts, namespaces, controller bootstrap endpoint, and
domain as environment variables. Then work through the phases by hand:

1. **Rehearse the outage (optional).** In a real disaster the regions are already down; to
   rehearse, scale `dc1`'s and `dc3`'s controllers to 0 or cordon/force-delete their pods
   to fake the dc1+dc3 outage (3 of 5 voters). Skip this in a real outage — there's nothing
   to cordon.
2. **Phase 1** — rebuild the quorum on the surviving region `dc2` (unknown RPO — see the
   READ FIRST box). Follow the canonical data-safe manual walkthrough.
3. **Phase 2** — bring `dc1` back, then `dc3` back (one region at a time).

The topology here is 2.5DC 2-2-1, with the client config mounted at
`/opt/confluentinc/etc/kafka/kafka-client.properties`.

## Run it (manual)

Identical to the [canonical data-safe walkthrough](../../../quorum-loss-recovery/cfk-3.3/manual-recovery/README.md#run-it-manual)
— just 2 surviving controllers in dc2 ({100,101}) instead of 3, and the data-loss caveat
above applies to the `force-standalone` step.

## Gotchas

All the gotchas from the [canonical README](../../../quorum-loss-recovery/cfk-3.3/manual-recovery/README.md#gotchas)
apply (CFK 3.3+ images, `force-standalone` irreversible, seed-by-epoch, PVC-race). One is
lossy-specific:

- **Split-brain hazard on dead-region return.** If a dead region's kraft pods come back
  with their old (superseded-timeline) metadata and reach each other but not the recovered
  leader, they can form a rogue quorum. Phase 2 defends against this by parking returning
  pods (maintenance annotation set *before* uncordon) and clearing their metadata before
  main starts. If the region is genuinely unreachable there's no in-cluster defense — wait
  it out or race to apply maintenance-mode as it returns. Document this in your runbook.

## References

- [Canonical data-safe CFK 3.3 manual (full steps + gotchas)](../../../quorum-loss-recovery/cfk-3.3/manual-recovery/README.md) · [CFK 3.2 path](../../cfk-3.2/README.md) · [kubectl-plugin path](../kubectl-plugin-recovery/README.md)
- [`FAULT_TOLERANCE.md`](../../../../FAULT_TOLERANCE.md) · [`ack-semantics.md`](../../../../ack-semantics.md) · [2.5DC topology guide](../../../../topology-guides/2-5dc.md)
- [KIP-853](https://cwiki.apache.org/confluence/display/KAFKA/KIP-853%3A+KRaft+Controller+Membership+Changes)
