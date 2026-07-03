# Dynamic-Quorum KRaft Disaster Recovery

End-to-end DR procedure for a multi-region CFK cluster running dynamic-quorum KRaft.

**The goal (quorum-loss recovery):** a region went down, taking enough KRaft voters with it that the quorum is lost — no leader, metadata writes blocked — even though the *surviving* region's controllers and brokers are still running. These procedures rebuild a working quorum out of the surviving controllers so the cluster is available again, accepting that it now runs with lower fault tolerance until the dead region is restored. (The `no-quorum-loss-recovery/` case is milder — quorum never actually drops, so it's just restoring failure headroom.)

> **⚠ Core assumption — the failed region must stay down while you recover.** Rebuilding the surviving region runs `force-standalone`, which rewrites the voter set on a *new* metadata timeline. If the failed region's controllers come back **during** recovery with their old metadata and can still reach each other, they can form a second, rogue quorum on the old timeline → **split-brain**. Keep the failed region down (cordoned / scaled to zero / genuinely unreachable) until Phase 1 is complete and the surviving quorum is healthy; restore it only via the Phase 2 procedure, which clears its stale metadata first. **This is how KRaft works — not a CFK limitation.**

Three recovery subdirectories — two of them are paired quorum-loss examples that differ in whether the recovery is data-safe or lossy. All three run against a dynamic-quorum multi-region cluster you deploy yourself (adapt the [greenfield MRC example](../greenfield/mrc/) — 2DC 3-3 for `quorum-loss-recovery/`, 2.5DC 2-2-1 for the others):

| Subdirectory | What |
|---|---|
| [`no-quorum-loss-recovery/`](no-quorum-loss-recovery/) | A minority of voters is down — KRaft quorum is still healthy. `remove-controller` the dead voters, scale the dead pods, `add-controller` when they return. Doesn't need `kafka-metadata-recovery`. **RPO=0, RTO=0** (quorum stays healthy throughout). **Version-agnostic** — no `cfk-3.2/`/`cfk-3.3/` split (see its README's CFK 3.3 note). Illustrated with the 2.5DC layout (where shrinking the voter set buys back failure headroom); the example README explains the topology framing. |
| [`quorum-loss-recovery/`](quorum-loss-recovery/) | **Data-safe** quorum-loss DR: **2DC 3-3** with a full-DC failure (3 of 6 voters dead). Dead set < majority → `force-standalone` recovers with **RPO=0**; RTO is the manual procedure (lower with the plugin). Two CFK versions: [`cfk-3.2/`](quorum-loss-recovery/cfk-3.2/README.md) (pod-overlay sidecar) and `cfk-3.3/` — a [manual](quorum-loss-recovery/cfk-3.3/manual-recovery/README.md) path and a 2-click [kubectl-plugin](quorum-loss-recovery/cfk-3.3/kubectl-plugin-recovery/README.md) path. |
| [`lossy-quorum-loss-recovery/`](lossy-quorum-loss-recovery/) | **Lossy** quorum-loss DR: **2.5DC 2-2-1** losing 1.5 regions (3 of 5 voters gone). Dead set = majority → `force-standalone` may lose committed writes (**RPO non-zero / unbounded**; RTO is the manual procedure (lower with the plugin)). Same procedure as `quorum-loss-recovery/`; only the topology and data-safety differ. Same CFK versions: [`cfk-3.2/`](lossy-quorum-loss-recovery/cfk-3.2/README.md), [`cfk-3.3/manual-recovery/`](lossy-quorum-loss-recovery/cfk-3.3/manual-recovery/README.md), [`cfk-3.3/kubectl-plugin-recovery/`](lossy-quorum-loss-recovery/cfk-3.3/kubectl-plugin-recovery/README.md). Deploy in the 2.5DC 2-2-1 layout. |

## CFK 3.2 vs CFK 3.3

The two quorum-loss examples ship both versions side by side, because CFK 3.3 made the recovery materially simpler. Pick the version that matches your operator + init image:

- **`cfk-3.2/`** — the original flow. Parks each surviving controller with a **sidecar container injected via a pod overlay** (so `kafka-metadata-recovery` gets the metadata-log lock; the example overlay names this container `saviour`), which costs **2 KRaft pod rolls** (one to apply the overlay, one to remove it at the end) plus a manual pod kill to enter the sidecar and a `roll-precheck=disable` dance, and builds a `/tmp/admin.properties` in-pod for every admin call — around 20 commands end to end.
- **`cfk-3.3/`** — uses three CFK 3.3 improvements to drop all of that:
  1. **Maintenance mode in the main container**: park a controller by setting the `platform.confluent.io/maintenance-mode` annotation — no pod overlay, no extra rolls. The main container sleeps before `kafka-server-start.sh`, so the log-dir lock is free and the CP tools are on PATH.
  2. **Mounted admin client config**: `kafka-client.properties` is mounted on the kraft pods (a superset of `kafka.properties` carrying SASL/TLS), so there's no in-pod `admin.properties` build — and no need to supply the SASL/truststore passwords yourself.
  3. **The `kubectl-confluent` plugin**: `kraft log-length` + `kraft recover-region` rebuild the surviving region's quorum in **two commands**.

  `cfk-3.3/` offers two paths: **`manual-recovery/`** (a by-hand command walkthrough) and **`kubectl-plugin-recovery/`** (the 2-click plugin). **On CFK 3.3, prefer the plugin.** Both cover Phase 1 (rebuild the surviving region); Phase 2 (restore a dead region) uses the manual procedure in either case.

At a glance — Phase 1 (rebuild the surviving region) step by step, with the actual commands each path needs. The point: CFK 3.2 is ~20 commands with 2 pod rolls + a manual kill; the plugin is **2 commands, no rolls**.

| Phase 1 step | CFK 3.2 (`cfk-3.2/`) | CFK 3.3 manual (`cfk-3.3/manual-recovery/`) | CFK 3.3 plugin |
|---|---|---|---|
| **1. Park the controllers** (free the metadata-log lock) | `kubectl annotate … roll-precheck=disable`<br>`kubectl create configmap <overlay> --from-file=…`<br>`kubectl annotate … pod-overlay-configmap-name=<overlay>` → **1 roll** (pods come up with the sidecar)<br>`kubectl delete pod -l app=kraftcontroller` (re-enter together). Needs `--podoverlay-enabled`. | `kubectl annotate … maintenance-mode="<pods>"`<br>`kubectl delete pod <pods>` → **no roll** (pods restart into maintenance). | `kubectl confluent kraft log-length …` parks them for you → **no roll**. |
| **2. Authenticate the admin calls** | Build `/tmp/admin.properties` in-pod from `kafka.properties` — needs the SASL password and TLS truststore password supplied to the recovery commands. | Mounted `kafka-client.properties` (no passwords needed). | Mounted `kafka-client.properties`. |
| **3. Measure (epoch, offset) per pod** | `kubectl exec <pod> -c saviour -- kafka-metadata-recovery … log-length` — once per surviving pod. | `kubectl exec <pod> -- kafka-metadata-recovery … log-length` — once per pod. | included in `kraft log-length`. |
| **4. `force-standalone` the seed** | `kubectl exec <seed> -c saviour -- kafka-metadata-recovery … force-standalone`. | `kubectl exec <seed> -- kafka-metadata-recovery … force-standalone`. | done by `kraft recover-region --seed-pod`. |
| **5. Release seed + rejoin the others** | per other pod: `kubectl exec … mv __cluster_metadata-0 …`<br>`kubectl exec … touch /tmp/saviour-done`<br>`kubectl exec … add-controller`. | per other pod: `kubectl exec … rm __cluster_metadata-0`<br>`kubectl delete pod …`<br>`kubectl exec … add-controller`. | done by `kraft recover-region`. |
| **6. Remove the sidecar overlay** | `kubectl annotate … pod-overlay-configmap-name-` → **2nd roll** (clean pods, no sidecar). | — (annotation already cleared in step 5). | — |
| **KRaft pod rolls** | **2 rolls + 1 manual kill** (roll to apply the overlay, kill to enter the sidecar, roll to remove the overlay) | **1 manual kill** (enter maintenance; no roll) | **none** — the plugin restarts pods for you |
| **Total commands** (each `kubectl exec` counts) | **~20** | **~18** | **2** |

Phase 2 (restore a dead region) is the same manual procedure in all three.

## Background reading first

Before running anything in this directory:

1. Read [`FAULT_TOLERANCE.md`](../FAULT_TOLERANCE.md) for the KRaft fault-tolerance bound and the two-thresholds / asymmetric-durability concepts that determine which DR procedure applies to your failure mode. For KRaft vs Kafka write semantics specifically, see [`ack-semantics.md`](../ack-semantics.md). For per-topology DR sketches (which scenario maps to which procedure), see [`topology-guides/1dc.md`](../topology-guides/1dc.md) and [`topology-guides/`](../topology-guides/).

## Before you start: snapshot the KRaft PVs

Every quorum-loss procedure here runs `force-standalone`, which **rewrites the metadata voter set and is irreversible**. Before you start Phase 1, take a volume-level snapshot of each surviving controller's KRaft PV — that is your only true rollback if recovery goes wrong (e.g. you force-standalone the wrong seed). On GKE:

```bash
# For each surviving kraft pod's PV (repeat per controller):
PV=$(kubectl --context <surviving-ctx> -n <ns> get pvc data0-kraftcontroller-0 -o jsonpath='{.spec.volumeName}')
DISK=$(kubectl --context <surviving-ctx> get pv "$PV" -o jsonpath='{.spec.csi.volumeHandle}' | awk -F/ '{print $NF}')
gcloud compute snapshots create dr-presnap-kraftcontroller-0-$(date +%s) --source-disk "$DISK" --source-disk-zone <zone>
```

The procedures *also* take an in-pod `cp` snapshot of `__cluster_metadata-0` (Step 4 / the plugin's pre-recovery backup) — that protects the metadata partition specifically, but a PV snapshot is the disk-level safety net and protects against a wider class of mistakes.

## After recovery: clean up the in-disk backups

The procedures move/copy stale `__cluster_metadata-0` aside into `backup/__cluster_metadata-0-<ts>` directories on the KRaft PVs (Phase 1 snapshots; Phase 2's metadata-move-aside). They are **never auto-deleted** — they exist so you can forensically inspect what was discarded (on a lossy recovery, a backup may hold the only copy of a lost write). Once the full quorum is confirmed healthy and you've verified RPO to your satisfaction, reclaim the space:

```bash
# On each kraft pod, after the quorum is verified healthy:
kubectl exec kraftcontroller-0 -n <ns> -c kraftcontroller -- bash -c 'rm -rf /mnt/data/data0/logs/backup'
```

Also delete the PV snapshots taken above, and (CFK 3.3 plugin) the `<controller>-dr-checkpoint` ConfigMap the plugin tells you to remove. **Don't clean up until the recovery is fully verified** — these are your rollback artifacts.

## This is a procedural reference, not a copy-paste runbook

The example commands in this directory use placeholder namespaces (`dc1`/`dc2`, plus `dc3` for 2.5DC), contexts, and voter IDs. They will not work as-is on your cluster.

Use them as a **reference implementation**: read each README to understand the *sequence* of operations (park the controllers, measure log lengths, force-standalone, release the seed, observer rejoin, etc.). The sequence is the same regardless of topology. Adapt to your own setup:

- Per-region mappings: for each region, the voter IDs, the kube-context, the controller/broker pods, and which voter belongs to which region.
- Your contexts, namespaces, credentials, and domain — supply these as environment variables to the commands.
- The per-region KRaftController/Kafka YAMLs for your layout.

**Rehearse this before you need it.** Run the full procedure end-to-end on a staging cluster ahead of any real incident. A dry run validates your adapted mappings and surfaces setup-specific quirks (DNS propagation, cert SANs, storage class, operator/init image pairing) while there's no pressure. DR is not the time to discover that your cluster behaves slightly differently from this reference.

## Topology applicability

Two worked examples ship in-repo — **2DC 3-3** ([`quorum-loss-recovery/`](quorum-loss-recovery/), data-safe) and **2.5DC 2-2-1** ([`lossy-quorum-loss-recovery/`](lossy-quorum-loss-recovery/), lossy) — but the DR **primitives apply to all multi-region KRaft topologies**. The per-topology DR sketches (which scenario maps to which procedure, and the data-safe-vs-lossy verdict for 3DC etc.) live in [`topology-guides/`](../topology-guides/) and the comparison in [`choosing-a-topology.md`](../choosing-a-topology.md) — we don't restate them here. The per-region mappings (which voter IDs, contexts, and pods belong to which region) are where the per-topology adaptation lives; the `kafka-metadata-quorum`/`kafka-metadata-recovery` invocations themselves don't change.

## Decision tree: which subdirectory applies?

```
KRaft quorum status?
├── Healthy (you can run kafka-metadata-quorum describe successfully)
│   ├── All voters present and lagging cleanly → no DR needed
│   └── A minority of voters down + the cluster is still serving →
│       no-quorum-loss-recovery/   (shrink the voter set, then restore when they
│                                   return; no kafka-metadata-recovery needed)
└── Lost (describe times out / current-leader=-1)
    ├── Dead set size  <  majority (e.g. 2DC 3-3 full-DC loss = 3 dead, majority=4) →
    │   quorum-loss-recovery/         (data-safe; RPO=0. CFK 3.3:
    │     cfk-3.3/ (recommended)       2-click plugin or manual; cfk-3.2/ =
    │     or cfk-3.2/                  pod-overlay sidecar)
    └── Dead set size >=  majority (e.g. 2.5DC, 3 of 5 voters dead) →
        lossy-quorum-loss-recovery/   (data loss possible; needs the 2.5DC
          cfk-3.3/ or cfk-3.2/         2-2-1 layout — see its README)
```

If unsure, read both subdirs' READMEs. The procedures are different shapes — quorum-loss requires `kafka-metadata-recovery` (destructive primitive), no-quorum-loss only needs the standard admin RPCs. **The two quorum-loss dirs use the same procedure; the difference is purely the topology and what that means for durability.**

## Quick start: bring up the cluster

Deploy a dynamic-quorum multi-region cluster before running any recovery. There is no bundled deploy script — adapt the [greenfield MRC example](../greenfield/mrc/) (TLS + SASL/PLAIN + OAuth + RBAC across two K8s clusters) to your contexts, namespaces, domain, and credentials:

- **2DC 3-3** (6 voters) for `quorum-loss-recovery/`.
- **2.5DC 2-2-1** (5 voters) for `lossy-quorum-loss-recovery/` and `no-quorum-loss-recovery/`.

Once the quorum is up, confirm it with:
```bash
kubectl exec kraftcontroller-0 -n <ns> -- \
  kafka-metadata-quorum --bootstrap-controller <controller-endpoint> \
  --command-config <client-properties> describe --status
```

With the cluster up, run a recovery **from the matching subdirectory** — each has its own README with the by-hand walkthrough (the recovery commands live there, not here):

- Data-safe quorum loss (2DC 3-3) → [`quorum-loss-recovery/`](quorum-loss-recovery/) — [`cfk-3.3/kubectl-plugin-recovery/`](quorum-loss-recovery/cfk-3.3/kubectl-plugin-recovery/README.md) (recommended), [`cfk-3.3/manual-recovery/`](quorum-loss-recovery/cfk-3.3/manual-recovery/README.md), or [`cfk-3.2/`](quorum-loss-recovery/cfk-3.2/README.md)
- Lossy quorum loss (2.5DC 2-2-1) → [`lossy-quorum-loss-recovery/`](lossy-quorum-loss-recovery/)
- Minority loss, quorum still healthy → [`no-quorum-loss-recovery/`](no-quorum-loss-recovery/)

## Version notes

- **CFK 3.2 paths (`cfk-3.2/`)** — the pod-overlay-sidecar flow. Work on CP 7.9.6+ and CP 8.x with a CFK 3.2 operator/init image.
- **CFK 3.3 paths (`cfk-3.3/manual-recovery/`, `cfk-3.3/kubectl-plugin-recovery/`)** — require a CFK 3.3+ operator/init image (main-container maintenance mode; mounted `kafka-client.properties`). The `kubectl confluent kraft log-length` / `recover-region` commands are the recommended path.
- **Known environment quirk**: a dummy-PVC race can occur if a Kafka PVC is deleted under a live StatefulSet (K8s' STS controller recreates it from the `dummy` volumeClaimTemplate before CFK can). It's a Phase 2 housekeeping issue, not a recovery blocker — the scale-STS-to-zero workaround is in [`quorum-loss-recovery/cfk-3.2/README.md`](quorum-loss-recovery/cfk-3.2/README.md#gotchas).
