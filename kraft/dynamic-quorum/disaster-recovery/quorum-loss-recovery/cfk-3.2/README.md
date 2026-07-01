# DR: KRaft Quorum Loss Recovery — 2DC 3-3 (data-safe)

A full DC fails in a **2DC even-symmetric (3-3)** deployment: 3 of 6 voters die, KRaft loses quorum (majority=4 can't form), but **no committed write is lost**. This is the data-safe quorum-loss example. The sibling [`lossy-quorum-loss-recovery/`](../../lossy-quorum-loss-recovery/cfk-3.2/) runs the *same mechanics* on a 2.5DC layout where commits **can** be lost.

> **Why this is data-safe (RPO=0):** 6 voters, majority=4, full-DC loss kills 3. **3 < 4**, so by Raft's majority-intersection argument every committed write (≥4 acks) reached at least one survivor — the 3-voter dead set can't hold a commit-majority on its own. Recovery rebuilds from the **most up-to-date survivor, selected by largest epoch and then (only on a tie) largest log-end offset** — KRaft's own up-to-date ordering (`kafka-metadata-recovery reconfig log-length` prints both `epoch:` and `log end offset:`; rank on the pair). Selecting by raw offset alone is **wrong**: a longer-but-lower-epoch survivor can be a stale divergent branch that is missing committed records a shorter higher-epoch survivor holds. With epoch-first selection and `dead ≤ floor(N/2)`, the chosen survivor's log is a superset of every committed entry, so `force-standalone` recovers with zero metadata loss. The general rule (`no-data-loss DR holds while the dead set ≤ floor(N/2)`) and the per-topology table are in [`FAULT_TOLERANCE.md`](../../../FAULT_TOLERANCE.md#two-thresholds-availability-and-no-data-loss-recovery). The canonical 2-DC recovery procedure defines "longest log" as **largest epoch, then largest offset**.

## Topology

- 6 voters: dc2 = {100,101,102}, dc1 = {200,201,202}. Majority = 4.
- **Init state (bad):** dc1 down. Only {100,101,102} alive < 4 → no leader, metadata writes block.
- **Final state (recovered):** dc2 running a healthy 3-voter quorum, then dc1 rejoined → back to 6 voters, all Lag ≤ 2, **RPO = 0**.
- **RPO = 0** (no committed write is lost — see the verdict above). **RTO** = the time to run Phase 1 on the survivor (a handful of manual steps; minutes once rehearsed). The CFK 3.3 plugin path cuts RTO further (two commands).

Concepts live elsewhere — read them first if unfamiliar: fault-tolerance math in [`FAULT_TOLERANCE.md`](../../../FAULT_TOLERANCE.md), KRaft vs Kafka ack semantics in [`ack-semantics.md`](../../../ack-semantics.md), the 2DC walkthrough (voter counts, RTO/RPO) in [`topology-guides/2dc.md`](../../../topology-guides/2dc.md). Dynamic quorum (KIP-853) makes this smoother than static KRaft — the rewritten voter set propagates via `VotersRecord` on the metadata log, with no rolling restart of survivors and no `controller.quorum.voters` edit.

## Prerequisites

- KRaft-based CP cluster across 2 regions, 3-3 voter layout, a full DC down, all KRaft + Kafka PVs `reclaimPolicy: Retain`.
- CFK operator running with `--podoverlay-enabled=true`, able to roll dc2's `KRaftController` CR (no global reconcile-block annotations).
- A dynamic-quorum cluster deployed in a 2DC 3-3 layout — adapt the greenfield MRC example ([`../../../greenfield/mrc/`](../../../greenfield/mrc/)) to give you the 6-voter cluster this targets.
- **The dead region must stay down for all of Phase 1** — `force-standalone` starts a new metadata timeline, and a dead-region controller rejoining mid-recovery with its old metadata can form a rogue quorum (split-brain). This is how KRaft works, not a CFK behavior; see the [DR README assumption](../../README.md). Restore the dead region only via Phase 2.

## Simulating the failure (test rehearsal only)

In a real disaster the region is already down; to rehearse, scale that region's controllers to 0 or cordon/force-delete its pods (its 3 kraft + 2 kafka pods) so the StatefulSets can't reschedule. In a real outage there is nothing to cordon and nothing to uncordon — skip it, and skip the uncordon in Phase 2.

## Run it (manual)

Run each command with care, treating every mutation as a decision point. The mechanism: `kafka-metadata-recovery` needs an exclusive lock on the metadata log dir, so the main controller must be DOWN. We inject a **sidecar container via a pod overlay** (cp-server image, so the tool is on PATH; the example overlay names it `saviour`) into each surviving kraft pod; init containers block main, and the sidecar waits on a sentinel file (`/tmp/saviour-done`) — touch it to release main. `resources/extra-init-container.yaml` already carries the element-ordering fix CFK's strategic-merge needs (see [Gotchas](#gotchas)).

Every `kafka-metadata-quorum` call below needs an admin client config. Build `/tmp/admin.properties` inside the target pod by appending SASL/TLS to the rendered `kafka.properties` (set `$KAFKA_USER`/`$KAFKA_PASS`/`$TRUSTSTORE_PASS` as environment variables from your credentials):

```bash
cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
cat >> /tmp/admin.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="$KAFKA_USER" password="$KAFKA_PASS";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=$TRUSTSTORE_PASS
ssl.truststore.type=PKCS12
EOF
```

### Phase 1 — recover the surviving region (dc2)

dc2 has 3 voters, so this grows back to 3 (vs 2 in the 2.5DC example); otherwise the steps are identical.

```bash
# 1. Disable CFK's roll precheck (its inter-pod health checks never pass while quorum is
#    lost, so the roll would stall), then apply the pod-overlay sidecar. The operator rolls
#    one pod at a time, blocked by Ready.
kubectl annotate kraftcontroller kraftcontroller -n dc2 \
  platform.confluent.io/roll-precheck=disable --overwrite
kubectl create configmap dc2-pod-overlay \
  --from-file=pod-template.yaml=resources/extra-init-container.yaml -n dc2
kubectl annotate kraftcontroller kraftcontroller -n dc2 \
  platform.confluent.io/pod-overlay-configmap-name=dc2-pod-overlay --overwrite
# As each pod enters the sidecar (operator rolls highest ordinal first), release it so the
# roll advances to the next:
kubectl exec kraftcontroller-0 -n dc2 -c saviour -- touch /tmp/saviour-done
kubectl exec kraftcontroller-1 -n dc2 -c saviour -- touch /tmp/saviour-done
kubectl exec kraftcontroller-2 -n dc2 -c saviour -- touch /tmp/saviour-done

# 2. Kill all surviving pods at once so they re-enter the sidecar simultaneously.
kubectl delete pod -n dc2 -l app=kraftcontroller --grace-period=0 --force

# 3. Measure log length on each parked pod.
for ord in 0 1 2; do
  kubectl exec kraftcontroller-$ord -n dc2 -c saviour -- \
    kafka-metadata-recovery reconfig log-length --metadata-log-dir /mnt/data/data0/logs
done
# 4. Pick the survivor with the LARGEST epoch (ties broken by largest `log end offset`)
#    — that is LONGEST_POD, the source of truth. NOT the largest offset alone: a
#    longer-but-lower-epoch log can be a stale branch missing committed records.
#    Touch NO sentinels yet.

# 5. force-standalone on the selected pod's existing sidecar (assume kraftcontroller-1 here).
#    Appends a new VotersRecord naming it sole voter at a higher epoch.
kubectl exec kraftcontroller-1 -n dc2 -c saviour -- \
  kafka-metadata-recovery reconfig force-standalone \
  --config /opt/confluentinc/etc/kafka/kafka.properties

# 6. Release the longest pod; main starts as the sole-voter Leader. Verify exactly one
#    voter row, Status=Leader:
kubectl exec kraftcontroller-1 -n dc2 -c saviour -- touch /tmp/saviour-done
kubectl exec kraftcontroller-1 -n dc2 -- kafka-metadata-quorum \
  --command-config /tmp/admin.properties --bootstrap-controller localhost:9074 \
  describe --replication

# 7. For each OTHER surviving pod (0 and 2): move its stale metadata to backup, release it
#    (boots empty, fetches from the new leader, lands as Observer), then add-controller.
for ord in 0 2; do
  kubectl exec kraftcontroller-$ord -n dc2 -c saviour -- bash -c '
    if [[ -d /mnt/data/data0/logs/__cluster_metadata-0 ]]; then
      mkdir -p /mnt/data/data0/logs/backup
      mv /mnt/data/data0/logs/__cluster_metadata-0 \
         /mnt/data/data0/logs/backup/__cluster_metadata-0-$(date +%s)
    fi'
  kubectl exec kraftcontroller-$ord -n dc2 -c saviour -- touch /tmp/saviour-done
  # add-controller's --bootstrap-controller must reach a current voter; use the surviving
  # region's LB endpoint so the same command works from a local OR a remote-cluster pod.
  # The client discovers the real leader from it.
  kubectl exec kraftcontroller-$ord -n dc2 -- kafka-metadata-quorum \
    --command-config /tmp/admin.properties \
    --bootstrap-controller <dc2-controller-lb-endpoint>:9074 add-controller
done

# 8. Drop the overlay for a final clean roll without the sidecar. dc2 is back to 3 voters.
#    (Leave roll-precheck=disable in place until the full 6-voter quorum is restored in
#    Phase 2 — the cluster is still below N voters here.)
kubectl annotate kraftcontroller kraftcontroller -n dc2 \
  platform.confluent.io/pod-overlay-configmap-name-
```

**Phase 1 is complete here — the cluster is operational** on dc2's 3-voter quorum. Phase 2 restores the full 6-voter resilience and is **not urgent**.

### Phase 2 — restore the dead region (dc1)

> **The pod-overlay sidecar used in the lossy example is overkill here.** With `3 dead < 4 majority`, dc2 provably holds every committed write, so dc1's old `__cluster_metadata-0` contains nothing dc2 doesn't. We use the simpler scale-STS-to-zero path and **move the metadata to `backup/` exactly as the lossy example does** — the backup is throwaway here (kept only so both procedures are identical; `rm` would be equally correct). Kafka topic data on dc1 is preserved — only KRaft metadata is touched; brokers reattach to their retained log PVs and rejoin ISR via Kafka's normal mechanism, avoiding a full re-replication from dc2.

```bash
# Set contexts as environment variables: DC2_CONTEXT is the surviving region, DC1_CONTEXT the dead one.
CTX_DC1=$DC1_CONTEXT; CTX_DC2=$DC2_CONTEXT
CTX=$CTX_DC1

# (test rehearsal only) undo the simulated failure:
for n in $(kubectl --context $CTX get nodes -o name); do kubectl --context $CTX uncordon ${n#node/}; done

# 1. No pod should demand the kraft PVCs.
kubectl --context $CTX scale statefulset kraftcontroller -n dc1 --replicas=0

# 2. Move __cluster_metadata-0 to backup/<ts> on each kraft PVC.
for ord in 0 1 2; do
  kubectl --context $CTX run wipe-kraft-$ord -n dc1 --rm -i --restart=Never --image=busybox \
    --overrides="{\"spec\":{\"volumes\":[{\"name\":\"d\",\"persistentVolumeClaim\":{\"claimName\":\"data0-kraftcontroller-$ord\"}}],\"containers\":[{\"name\":\"mv\",\"image\":\"busybox\",\"volumeMounts\":[{\"mountPath\":\"/data\",\"name\":\"d\"}],\"command\":[\"sh\",\"-c\",\"ts=\$(date +%s); if [ -d /data/logs/__cluster_metadata-0 ]; then mkdir -p /data/logs/backup; mv /data/logs/__cluster_metadata-0 /data/logs/backup/__cluster_metadata-0-\$ts; echo moved; else echo no-metadata; fi\"]}]}}"
done

# 3. Scale back up; pods boot empty, fetch from dc2's leader, land as Observers.
kubectl --context $CTX scale statefulset kraftcontroller -n dc1 --replicas=3

# 4. Promote each returning controller back to voter — run FROM the pod (the tool reads
#    node.id + directory.id locally). Use dc2's external LB endpoint (cross-region pod DNS
#    won't resolve). Lag need not be 0 first.
for pod in kraftcontroller-0 kraftcontroller-1 kraftcontroller-2; do
  kubectl --context $CTX exec -n dc1 $pod -- kafka-metadata-quorum \
    --command-config /tmp/admin.properties \
    --bootstrap-controller <dc2-controller-lb-endpoint>:9074 add-controller
done

# 5. Full 6-voter quorum is back — re-enable the roll-precheck safety net on dc2
#    (Phase 1 left it disabled).
kubectl --context $CTX_DC2 annotate kraftcontroller kraftcontroller -n dc2 \
  platform.confluent.io/roll-precheck-
```

Kafka brokers in dc1 rejoin automatically once Running. Final state: 6-voter quorum across dc1 + dc2, all Leader/Follower, Lag ≤ 2, **zero data loss** on both KRaft metadata and Kafka topic data.

For the data-safe case the scale-to-zero path above is recommended — fewer moving parts, no overlay annotation to leak across test cycles. (The lossy example instead reuses the pod-overlay-sidecar flow for Phase 2.)

## Gotchas

- **Saviour overlay only works on a reachable region** — it needs `kubectl` access to that region's `KRaftController` CR. Phase 1 runs on the survivor; dead-region cleanup uses the reachable-region path.
- **Pod overlay needs `--podoverlay-enabled=true`** on the operator. If the annotation is set but no roll happens, check operator logs for "podoverlay disabled".
- **Element-ordering fix** — CFK's strategic-merge places the sidecar *before* `config-init-container` and strips its `pod-shared-workdir` volumeMount by default; `resources/extra-init-container.yaml` includes the init-container element-ordering directive + a name-only `config-init-container` anchor to fix both (CP 7.9.6). If you run a pre-fix overlay, `force-standalone` fails with `Insufficient permissions to read .../kafka.properties` — build a minimal `recovery.properties` in `/tmp` from on-disk `meta.properties` and pass `--config /tmp/recovery.properties`. **Cleaner alternative on CFK 3.3:** `platform.confluent.io/maintenance-mode` parks pods in main, so you `kubectl exec` and run the tool directly — see [`../cfk-3.3/manual-recovery/`](../cfk-3.3/manual-recovery/README.md).
- **`kafka-metadata-recovery` requires the controller DOWN** (exclusive lock); the sidecar pattern guarantees that.
- **Move scope is narrow** — only `__cluster_metadata-0`; `meta.properties` (DirectoryId) and Kafka log data are preserved. Backups are never auto-deleted (clean them up post-recovery — see [parent README](../../README.md#after-recovery-clean-up-the-in-disk-backups)).
- **CP 8.1 or older has no auto-join** — a returning Observer stays an Observer until `add-controller`. CP 8.2+ auto-promotes; verify against your version.
- **Stale overlay annotation** — if you previously ran the lossy 2.5DC DR on this cluster, strip any leftover `platform.confluent.io/pod-overlay-configmap-name` from dc1's CR before scale-up, or CFK re-parks fresh pods with the sidecar: `kubectl --context $CTX_DC1 annotate kraftcontroller kraftcontroller -n dc1 platform.confluent.io/pod-overlay-configmap-name-`.
- **⚠ PVC-race deadlock** — if a Kafka PVC is deleted while its StatefulSet is alive, K8s' STS controller races CFK to recreate it and wins, making a `storageClassName: dummy, 1Gi` PVC from the volumeClaimTemplate; CFK then can't patch it (PVC spec is immutable) and the reconcile loop spins. Same scale-STS-to-zero workaround:
  ```bash
  kubectl --context $CTX_DC1 scale statefulset kafka -n dc1 --replicas=0
  kubectl --context $CTX_DC1 delete pvc data0-kafka-0 data0-kafka-1 -n dc1
  for p in data0-kafka-0 data0-kafka-1; do
    kubectl --context $CTX_DC1 patch pvc $p -n dc1 -p '{"metadata":{"finalizers":null}}' --type=merge
  done
  kubectl --context $CTX_DC1 scale statefulset kafka -n dc1 --replicas=2
  ```
  CFK then creates the real PVCs before the STS controller can race. The `dummy` placeholder is a known CFK volumeClaimTemplate placeholder — only ever an issue if you delete a PVC out from under a live STS, which is why the scale-to-zero ordering above avoids it.

## References

- **Adapt, don't run as-is.** These commands are tied to specific region names, contexts, and voter IDs; set your own contexts, namespaces, and credentials as environment variables. See the DR README's [procedural-reference note](../../README.md#this-is-a-procedural-reference-not-a-copy-paste-runbook) for how to adapt them, and keep an adapted copy ready before an incident. The conceptual flow (sidecar → log-length → force-standalone on the most up-to-date survivor — **largest epoch, then offset** — → observer rejoin → `add-controller`) is topology-independent.
- **Underlying-disk-deleted** edge case during restore → [Troubleshooting item 12](../../../README.md#47-troubleshooting-tips) in the main dynamic-quorum README.
- **Public references:** [KIP-853](https://cwiki.apache.org/confluence/display/KAFKA/KIP-853%3A+KRaft+Controller+Membership+Changes).
- **In-repo concepts:** [`FAULT_TOLERANCE.md`](../../../FAULT_TOLERANCE.md) · [`ack-semantics.md`](../../../ack-semantics.md) · [`topology-guides/2dc.md`](../../../topology-guides/2dc.md) · [`choosing-a-topology.md`](../../../choosing-a-topology.md) · [`pod-and-replica-placement.md`](../../../pod-and-replica-placement.md).
