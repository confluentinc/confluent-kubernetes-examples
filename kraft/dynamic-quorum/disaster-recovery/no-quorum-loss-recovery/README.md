# DR: One Region Down, No Quorum Loss — 2.5DC 2-2-1

One region fails but the survivors still hold a **majority of KRaft voters** — quorum is intact, the controller still elects a leader and accepts metadata writes. Recovery is a simple `remove-controller` → (region returns) → `add-controller`; **no `kafka-metadata-recovery`, no pod overlay, no data-loss risk.** If quorum is actually *lost*, use [`quorum-loss-recovery/`](../quorum-loss-recovery/) (data-safe 2DC) or [`lossy-quorum-loss-recovery/`](../lossy-quorum-loss-recovery/) (lossy 2.5DC) instead.

> **⚠ This example targets 2.5DC 2-2-1.** Shrink-to-3 only makes sense for the tiebreaker-augmented layout, where dropping `5 → 3 voters` cuts `needed` from 3 to 2 and restores headroom. In 2DC 3-3 there's no shrink scenario: losing 1 pod is still healthy, losing 2 leaves quorum but shrinking opens the asymmetric-durability hole, and losing 3 (a full DC) is already quorum-lost. To run this, **deploy a dynamic-quorum cluster in the 2.5DC 2-2-1 layout** (adapt the greenfield MRC example, [`../../greenfield/mrc/`](../../greenfield/mrc/)).

## Topology

- 5 voters: dc2 = {100,101}, dc1 = {200,201}, dc3 = {300}. Majority = 3.
- **Init state (degraded):** dc1 (2 voters) down. 3/5 alive = majority → quorum holds, but 0 further failures tolerated. In [`FAULT_TOLERANCE.md`](../../FAULT_TOLERANCE.md)'s `alive/needed/configured` notation: **`3/3/5`**.
- **Final state (recovered):** shrink to a 3-voter quorum → `3/2/3`, 1 further failure tolerated; then dc1 returns and is promoted back → original `5/3/5`.
- **RPO = 0, RTO = 0** — quorum never drops below majority, so the cluster keeps serving the whole time. There's no `force-standalone`, no timeline rewrite, no downtime; the `remove-controller` / `add-controller` admin RPCs don't interrupt the cluster (they just restore failure headroom). The reduced fault tolerance during the outage is the cost — not any service-impact time.

This is the realistic 1-region-loss recovery for 2.5DC and is fully supported by stock CFK. The per-topology math (when 1-region/1-AZ loss needs intervention, when shrink helps) is in [`FAULT_TOLERANCE.md`](../../FAULT_TOLERANCE.md) and [`topology-guides/2-5dc.md`](../../topology-guides/2-5dc.md) — the latter also covers the Path B refinement (grow dc3 1→2 to reach symmetric 2-2), which protects only against compounded region loss already beyond 2.5DC's design ceiling. CFK now supports the underlying KRaftController scale-up (increase `spec.replicas` with `dynamicQuorumConfig.enabled`; the new controller auto-joins on CP 8.2+).

## Prerequisites

- KRaft-based CP cluster, quorum still healthy after the failure, all KRaft + Kafka PVs `reclaimPolicy: Retain` (this is what makes restore safe *without* a metadata wipe — returning pods reattach to their old logs and replay forward).
- The healthy region is reachable from wherever you run the tooling (a kraft pod, a kafka pod, or a workstation with the right TLS/SASL config).

## Run it

There are two phases: shrink the voter set while `dc1` is down (regain failure tolerance), then promote the rejoining controllers back to voters when the region returns. Both phases are the by-hand `kafka-metadata-quorum` walkthrough below — follow the remove-controller / add-controller steps in order. `dc1` is the 2-voter region and `dc3` is the 1-voter tiebreaker.

The commands below need an admin client config. Build `/tmp/admin.properties` inside the target pod by appending SASL/TLS to the rendered `kafka.properties` (set your Kafka user/password and truststore password as environment variables — `$KAFKA_USER`/`$KAFKA_PASS`/`$TRUSTSTORE_PASS`):

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

> **Running on CFK 3.3.** This scenario is the same on CFK 3.2 and 3.3 — quorum stays
> healthy, so there is no maintenance mode, no `kafka-metadata-recovery`, and the
> `kubectl confluent kraft log-length` / `recover-region` plugin (which targets quorum
> *loss*) does **not** apply here. The one convenience CFK 3.3 adds is the mounted admin
> client config: skip the `/tmp/admin.properties` build above and pass the
> mounted file straight to every `kafka-metadata-quorum` call —
> `--command-config /opt/confluentinc/etc/kafka/kafka-client.properties`. That's why this
> directory has **no `cfk-3.2/` / `cfk-3.3/` split**, unlike the quorum-loss examples.

### Phase 1 — shrink

```bash
# 1.1 Describe the current quorum from any healthy kraft pod.
kafka-metadata-quorum --command-config /tmp/admin.properties \
  --bootstrap-controller localhost:9074 describe --replication
```

Read it: voters are `Status=Leader|Follower`; the dead voters are still listed (KRaft doesn't auto-remove them) but with non-zero `Lag` and a **frozen `LastFetchTimestamp`** — that's the unreachable signature. Below, 200 and 201 are dead; grab their `DirectoryId`:

> **Lag alone does not mean a voter is gone.** A non-zero `Lag` / stale `LastFetchTimestamp` can just be a *transient* hiccup (brief network blip, a pod restarting, GC pause) — `kafka-metadata-quorum` can't tell "permanently down" from "catching up." **Confirm the region/pod is actually down by other means** (cloud console, `kubectl get pods`, node status) before you shrink. These steps assume you've already established the voters are durably gone; shrinking out a voter that was only briefly behind needlessly drops your voter count.

```
NodeId  DirectoryId             LogEndOffset  Lag   LastFetchTimestamp  Status
101     lQ92sYMTnYHE2pVWw7bJ9w  33940         0     1777643877128       Leader
100     jknA-u7XR86Vkxnc2RGWgw  33940         0     1777643876933       Follower
200     kNxsHyUj3x0pKeAdMowmbQ  33808         132   1777643849923       Follower   ← dead
201     ezDCta58rqhUD_Fpr3UHJQ  33884         56    1777643850412       Follower   ← dead
300     yRXWy70qdjW4yh_qzePwzg  33940         0     1777643876933       Follower
```

```bash
# 1.2 Remove each dead voter by (NodeId, DirectoryId).
kafka-metadata-quorum --command-config /tmp/admin.properties \
  --bootstrap-controller localhost:9074 remove-controller \
  --controller-id 200 --controller-directory-id kNxsHyUj3x0pKeAdMowmbQ
# repeat for 201 / ezDCta58rqhUD_Fpr3UHJQ

# 1.3 Re-describe — only the 3 surviving voters remain, all Lag=0. Quorum now tolerates
#     1 more failure. (Idempotent: re-running after a successful shrink finds the targets
#     already gone and skips them.)
```

### Phase 2 — restore

**No PVC/PV wipe needed.** The returning pods are *behind* on a single linear log (there was no `force-standalone`, so no divergent timeline). They fetch from the leader, replay forward, see their own `RemoveControllerRecord`, and naturally land as Observers; the Raft epoch handshake corrects any "I think I'm a voter" residue.

```bash
# 2.1 Bring the region back. In a real outage this is whatever heals it. (Test harness:
#     uncordon — see the box below.) Then wait for pods Ready:
kubectl --context <dc1-context> wait --for=condition=Ready \
  pod/kafka-0 pod/kafka-1 pod/kraftcontroller-0 pod/kraftcontroller-1 -n dc1 --timeout=10m

# 2.2 Confirm the returning controllers came back as Observers (describe --replication):
#     200, 201 reappear as Observer with their ORIGINAL DirectoryIds (proof the retained PV's
#     meta.properties was reused, no wipe), Lag small and shrinking.

# 2.3 Promote each returning controller — run FROM the pod (the tool reads node.id +
#     directory.id locally; --controller-id flags are not accepted). Lag need not be 0 first.
kubectl exec -n dc1 kraftcontroller-0 -- kafka-metadata-quorum --command-config /tmp/admin.properties \
  --bootstrap-controller <dc2-controller-lb-endpoint> add-controller   # a healthy voter's LB endpoint
kubectl exec -n dc1 kraftcontroller-1 -- kafka-metadata-quorum --command-config /tmp/admin.properties \
  --bootstrap-controller <dc2-controller-lb-endpoint> add-controller
# Already-a-voter → "duplicate voter" error = safe re-run signal.

# 2.4 Final describe --replication: 5 voters, all Followers/Leader, Lag=0, DirectoryIds
#     unchanged. Quorum fully restored.
```

> **Cordon-uncordon is test-harness only — not part of recovery.** In a real disaster the region is already down; to rehearse, scale that region's controllers to 0 or cordon/force-delete its pods. `cordon` every node in the target region (so the STS can't reschedule elsewhere) and force-delete its pods. Recovery's "bring the region back" (2.1) is then just `uncordon`. In a real outage there's nothing to cordon or uncordon.
> ```bash
> for n in $(kubectl --context <dc1-context> get nodes -o name); do kubectl --context <dc1-context> cordon ${n#node/}; done
> kubectl --context <dc1-context> delete pod -n dc1 --grace-period=0 --force kafka-0 kafka-1 kraftcontroller-0 kraftcontroller-1
> ```

## Verification

```bash
# Watch the quorum during/after:
kubectl exec <pod> -- kafka-metadata-quorum --bootstrap-controller <endpoint> \
  --command-config /tmp/admin.properties describe --status
# After Phase 2, topic-level state recovers too — all partitions back to RF, no Offline brokers:
kubectl exec kafka-0 -n dc2 -- kafka-topics --bootstrap-server localhost:9092 \
  --command-config /tmp/admin.properties --describe --topic dr-stream
```

## Notes & adapting

- **CP 8.1 or older has no auto-join** — a controller that lost voter status returns as an Observer until `add-controller`. CP 8.2+ may auto-promote; verify against your version.
- **Kafka brokers in the failed region need no manual step** — they reattach to retained log PVs, replicate from current leaders, and rejoin ISR on their own. This procedure only touches the KRaft side.
- **This procedure is tied to the 2.5DC topology — adapt, don't copy IDs as-is.** The two-phase flow, the `kafka-metadata-quorum` commands, the "no wipe needed" insight (conditional on `Retain`), and the `add-controller`-from-the-pod rule are all topology-independent; only the per-region voter IDs and the majority-of-N math change. Set your contexts, namespaces, and credentials (Kafka user/password, truststore password, per-region voter IDs, healthy-voter LB endpoint) as environment variables for your own cluster. Voter IDs come from each `KRaftController`'s `platform.confluent.io/broker-id-offset` annotation (offset, offset+1, …).
- **References:** [`FAULT_TOLERANCE.md`](../../FAULT_TOLERANCE.md) · [`topology-guides/2-5dc.md`](../../topology-guides/2-5dc.md) · [`topology-guides/1dc.md`](../../topology-guides/1dc.md) · [KIP-853](https://cwiki.apache.org/confluence/display/KAFKA/KIP-853%3A+KRaft+Controller+Membership+Changes).
