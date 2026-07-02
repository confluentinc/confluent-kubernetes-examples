# DR: KRaft Quorum Loss Recovery — 2DC 3-3 (data-safe) — CFK 3.3 manual

**This is the canonical CFK 3.3 manual walkthrough** for quorum-loss recovery. The lossy
2.5DC sibling runs the *same steps* — it differs only in the
data-safety guarantee — so it links here rather than repeating them. For the fully
automated version use the [kubectl-plugin path](../kubectl-plugin-recovery/README.md).

> **Data-safe (RPO=0).** 2DC 3-3 = 6 voters, majority = 4. A full-DC
> loss kills 3 < 4, so every committed write (≥4 acks) reached at least one survivor.
> `force-standalone` rebuilds from the most up-to-date survivor (largest epoch, then
> offset) with zero metadata loss. The structural argument and the per-topology table
> are in [`FAULT_TOLERANCE.md`](../../../../FAULT_TOLERANCE.md). The lossy 2.5DC sibling
> ([`lossy-quorum-loss-recovery/cfk-3.3/manual-recovery/`](../../../lossy-quorum-loss-recovery/cfk-3.3/manual-recovery/README.md))
> runs these same steps on a layout where commits **can** be lost.

The recovery primitives (`log-length`, `force-standalone`, `add-controller`) and the seed-selection rule (largest epoch, then offset) are the same as CFK 3.2 — only the mechanism for parking a controller and authenticating the admin calls got simpler (maintenance-mode annotation instead of the pod-overlay sidecar; mounted `kafka-client.properties` instead of an in-pod `/tmp/admin.properties`). The step-by-step comparison is in the [DR README's CFK 3.2 vs 3.3 table](../../../README.md#cfk-32-vs-cfk-33).

## Topology

- 6 voters: dc2 = {100,101,102}, dc1 = {200,201,202}. Majority = 4.
- **Init (bad):** dc1 down → only {100,101,102} alive < 4 → no leader.
- **Final:** dc2 running a 3-voter quorum, dc1 rejoined → back to 6 voters, RPO = 0.
- **RPO = 0**; **RTO** = the time to run Phase 1 by hand (no rolls on CFK 3.3, so faster than 3.2; the plugin path is faster still — two commands).

## Prerequisites

- CFK **3.3+** operator + init image (main-container maintenance mode; mounted
  `kafka-client.properties`). On older images the controllers park in the
  *init* container and the `MAINTENANCE mode (main container)` marker never prints —
  Phase 1 parking times out; upgrade first.
- 2DC 3-3 cluster — deploy a dynamic-quorum cluster (adapt the greenfield MRC example, [`../../../../greenfield/mrc/`](../../../../greenfield/mrc/)).
- All KRaft + Kafka PVs `reclaimPolicy: Retain`.
- **Snapshot the KRaft PVs first** and clean up the in-disk backups afterwards — see
  [Before you start / After recovery](../../../README.md#before-you-start-snapshot-the-kraft-pvs)
  in the parent README.
- **The dead region (dc1) must stay down for the whole of Phase 1.** `force-standalone`
  starts a new metadata timeline; if dc1's controllers rejoin with their old metadata
  mid-recovery they can form a rogue quorum (split-brain). This is inherent to KRaft, not
  a CFK behavior — see the [DR README assumption](../../../README.md). Restore dc1 only via
  Phase 2.

## Overview

Before you start, set your contexts, namespaces, controller bootstrap endpoint, and
domain as environment variables. Then work through the three phases by hand:

1. **Rehearse the outage (optional).** In a real disaster the region is already down; to
   rehearse, scale that region's controllers to 0 or cordon/force-delete its pods to fake
   a full-DC loss (3 of 6 voters). Skip this in a real outage — there's nothing to cordon.
2. **Phase 1** — rebuild the quorum on the surviving region `dc2` (RPO = 0). Follow the
   step-by-step commands below.
3. **Phase 2** — bring `dc1` back.

Every command below uses the mounted `kafka-client.properties` at
`/opt/confluentinc/etc/kafka/kafka-client.properties`. The topology here is 2DC 3-3.

## Run it (manual)

**Step 0 — before anything else, snapshot each surviving controller's KRaft PV** (see [Before you start](../../../README.md#before-you-start-snapshot-the-kraft-pvs) in the parent README). That disk-level snapshot is your rollback if recovery goes wrong; take it once, up front.

Every command uses the mounted `kafka-client.properties` — no `/tmp/admin.properties`.

```bash
CFG=/opt/confluentinc/etc/kafka/kafka-client.properties
LOGDIR=/mnt/data/data0/logs          # parent of __cluster_metadata-0 (or read metadata.log.dir)
```

### Phase 1 — recover the surviving region (dc2)

```bash
# 1. Park every surviving controller. The operator renders the annotation into the
#    maintenance config; each pod must restart to read it and park (sleep before
#    kafka-server-start.sh). No pod overlay, no roll-precheck.
kubectl annotate kraftcontroller kraftcontroller -n dc2 \
  platform.confluent.io/maintenance-mode="kraftcontroller-0,kraftcontroller-1,kraftcontroller-2" --overwrite
kubectl delete pod kraftcontroller-0 kraftcontroller-1 kraftcontroller-2 -n dc2 --grace-period=0 --force
# Wait until each pod's main-container log shows: "MAINTENANCE mode (main container)"

# 2. Measure (epoch, log end offset) on each parked pod. kafka-metadata-recovery needs
#    the log dir .lock — the parked controller never created it, so pre-create it.
for p in kraftcontroller-0 kraftcontroller-1 kraftcontroller-2; do
  kubectl exec $p -n dc2 -c kraftcontroller -- bash -c \
    '[ -f '"$LOGDIR"'/.lock ] || : > '"$LOGDIR"'/.lock; \
     kafka-metadata-recovery reconfig log-length --metadata-log-dir '"$LOGDIR"
done
# 3. Pick the SEED = largest epoch, then (only on a tie) largest offset. NOT raw offset:
#    a longer-but-lower-epoch log can be a stale branch missing committed records.

# 4. (Secondary copy — your primary rollback is the Step 0 PV snapshot.) As defense in
#    depth you can also take an in-pod cp of __cluster_metadata-0 into backup/; if you
#    snapshotted the PVs you can skip this by hand:
for p in kraftcontroller-0 kraftcontroller-1 kraftcontroller-2; do
  kubectl exec $p -n dc2 -c kraftcontroller -- bash -c \
    'cp -r '"$LOGDIR"'/__cluster_metadata-0 '"$LOGDIR"'/backup/__cluster_metadata-0-$(date +%s) 2>/dev/null || true'
done

# 5. force-standalone on the SEED (assume kraftcontroller-1) — IRREVERSIBLE, run ONCE.
kubectl exec kraftcontroller-1 -n dc2 -c kraftcontroller -- bash -c \
  '[ -f '"$LOGDIR"'/.lock ] || : > '"$LOGDIR"'/.lock; \
   kafka-metadata-recovery reconfig force-standalone --config '"$CFG"

# 6. Release the seed: drop it from the annotation and restart it. It boots as the
#    sole-voter Leader. Verify with describe (FQDN bootstrap from the pod's config —
#    localhost:9074 fails TLS hostname verification).
kubectl annotate kraftcontroller kraftcontroller -n dc2 \
  platform.confluent.io/maintenance-mode="kraftcontroller-0,kraftcontroller-2" --overwrite
kubectl delete pod kraftcontroller-1 -n dc2 --grace-period=0 --force
kubectl exec kraftcontroller-1 -n dc2 -c kraftcontroller -- kafka-metadata-quorum \
  --command-config $CFG --bootstrap-controller <controller.quorum.bootstrap.servers> \
  describe --replication

# 7. For each OTHER survivor (0 and 2): clear stale metadata (snapshot already retained),
#    release it (boots empty → Observer), then add-controller (idempotent; from the pod).
for ord in 0 2; do
  kubectl exec kraftcontroller-$ord -n dc2 -c kraftcontroller -- bash -c \
    'rm -rf '"$LOGDIR"'/__cluster_metadata-0'
done
kubectl annotate kraftcontroller kraftcontroller -n dc2 platform.confluent.io/maintenance-mode-   # remove annotation
kubectl delete pod kraftcontroller-0 kraftcontroller-2 -n dc2 --grace-period=0 --force
for ord in 0 2; do
  kubectl exec kraftcontroller-$ord -n dc2 -- kafka-metadata-quorum \
    --command-config $CFG --bootstrap-controller <dc2-controller-lb-endpoint> add-controller
done
```

**Phase 1 is complete here** — the cluster is operational on dc2's 3-voter quorum. Phase
2 restores full 6-voter resilience and is not urgent.

### Phase 2 — restore the dead region (dc1)

Run these steps by hand, one per returning pod. Set the maintenance annotation **before**
uncordoning so returning pods come up parked, move their stale `__cluster_metadata-0`
aside (into `backup/`), release them (they boot empty, fetch from the recovered leader,
land as Observers), then `add-controller` each. With `3 dead < 4 majority` dc2 provably
holds every committed write, so the metadata moved aside on the returning pods is
throwaway (kept only so both procedures are identical). Kafka topic data on dc1 is
preserved — brokers reattach to their retained log PVs and rejoin ISR via Kafka's normal
mechanism.

## Gotchas

- **Operator/init must be CFK 3.3+.** Older images park in the init container, so the
  `MAINTENANCE mode (main container)` marker never prints and parking times out.
- **`force-standalone` is irreversible.** Run it exactly once; on failure, halt and leave
  the cluster parked. Don't blindly re-run — engage Confluent support to
  inspect the seed's voter state, then resume.
- **Seed selection ranks by epoch first, then offset.** Picking by raw offset can select
  a stale lower-epoch branch and drop committed metadata.
- **PVC-race + underlying-disk-deleted** edge cases are identical to 3.2 — see the
  [3.2 README gotchas](../../cfk-3.2/README.md#gotchas).

## References

- [CFK 3.2 path (pod-overlay sidecar)](../../cfk-3.2/README.md) · [kubectl-plugin path](../kubectl-plugin-recovery/README.md) · [lossy sibling](../../../lossy-quorum-loss-recovery/cfk-3.3/manual-recovery/README.md)
- [`FAULT_TOLERANCE.md`](../../../../FAULT_TOLERANCE.md) · [`ack-semantics.md`](../../../../ack-semantics.md) · [2DC topology guide](../../../../topology-guides/2dc.md)
- [KIP-853](https://cwiki.apache.org/confluence/display/KAFKA/KIP-853%3A+KRaft+Controller+Membership+Changes)
