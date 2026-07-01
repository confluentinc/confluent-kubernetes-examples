# DR: KRaft Quorum Loss Recovery — 2DC 3-3 (data-safe) — kubectl plugin (2-click)

**This is the canonical kubectl-plugin walkthrough.** The fully automated CFK 3.3 recovery
path: the `kubectl-confluent` plugin rebuilds the surviving region's quorum in **two
commands**, encoding exactly the sequence the [manual path](../manual-recovery/README.md)
runs by hand (park → log-length → seed → snapshot → force-standalone → release → clear +
rejoin), with a resumable checkpoint journal. The lossy 2.5DC sibling runs the same plugin
— it links here and only adds the data-loss caveat.

> **Data-safe (RPO=0).** 2DC 3-3, full-DC loss = 3 of 6 voters < majority 4, so
> `force-standalone` recovers with zero metadata loss. See
> [`FAULT_TOLERANCE.md`](../../../../FAULT_TOLERANCE.md). **RTO** is the lowest of the
> three paths — Phase 1 is two commands (`log-length` + `recover-region`).
>
> **Scope: Phase 1 only.** The plugin rebuilds the **surviving** region's quorum. For
> Phase 2, follow the manual Phase 2 steps in
> [`../manual-recovery/README.md`](../manual-recovery/README.md) to restore the dead region (dc1).

## Prerequisites

- CFK **3.3+** operator + init image (main-container maintenance mode; mounted
  `kafka-client.properties`) and a dynamic-quorum-enabled `KRaftController`.
- Exactly one `KRaftController` in the target namespace (the plugin refuses to guess).
- The `kubectl-confluent` plugin installed:
  ```bash
  make build-plugin        # in the confluent-operator repo
  kubectl krew install --manifest=bin/kubectl-plugin/release/confluent-platform.yaml \
    --archive=bin/kubectl-plugin/release/kubectl-confluent-<os>-<arch>.tar.gz
  kubectl confluent kraft -h
  ```
- All KRaft + Kafka PVs `reclaimPolicy: Retain`. **Snapshot the KRaft PVs first**; clean up
  afterwards — [parent README](../../../README.md#before-you-start-snapshot-the-kraft-pvs).
- **The dead region must stay down until recovery completes** — a dead-region controller
  rejoining mid-recovery risks split-brain (inherent to KRaft; see the
  [DR README assumption](../../../README.md)). Restore it only via Phase 2.

## Two clicks

> **Test harness only** — to fake a full-DC loss (3 of 6 voters): in a real disaster the
> region is already down; to rehearse, scale that region's controllers to 0 or
> cordon/force-delete its pods.

```bash
# Click 1 — park the surviving region's controllers and read each one's metadata
#           epoch + log end offset. Writes a <controller>-dr-checkpoint ConfigMap.
kubectl confluent kraft log-length --context <dc2-context> -n dc2

# Pick the SEED from the output: HIGHEST EPOCH first; break ties by largest log end offset.
# ⚠ Do NOT pick by log end offset alone — a longer but lower-epoch log can be a stale
#   divergent branch, and seeding from it permanently loses committed metadata.

# Click 2 — rebuild the quorum from the seed (snapshot → force-standalone → release
#           seed as sole voter → clear + rejoin the others as voters).
kubectl confluent kraft recover-region --context <dc2-context> -n dc2 --seed-pod <pod-from-click-1>
```

When `recover-region` finishes it prints the final quorum (`describe --status`) and tells
you to delete the checkpoint ConfigMap once the quorum is confirmed healthy.

## Flags worth knowing

| Flag | Command | Purpose |
|---|---|---|
| `--seed-pod` | recover-region | **Required.** The most up-to-date controller (largest epoch, then offset) from click 1. |
| `--yes` | both | Skip the interactive confirmation (e.g. for scripted/e2e runs). |
| `--timeout` | both | Overall budget (log-length default 5m, recover-region 15m). |
| `--skip-backup` | recover-region | Skip the pre-recovery in-pod metadata snapshot. Use when the data volume lacks space, or when you already took a PV-level snapshot ([parent README](../../../README.md#before-you-start-snapshot-the-kraft-pvs)) and don't need the redundant in-pod copy. |
| `--force-standalone-done` | recover-region | Resume **after** a force-standalone that you completed manually with Confluent support (see below). |
| `--metadata-log-dir` | both | Override the auto-detected metadata log dir. |

## Checkpointing, resume & manual control

The plugin journals its progress to a ConfigMap so an interrupted recovery can resume instead of starting from scratch (and so you have an audit trail of what it did).

**Where it lives.** One ConfigMap per KRaftController, in the controller's namespace, named `<kraftcontroller-name>-dr-checkpoint` (e.g. `kraftcontroller-dr-checkpoint`). The whole journal is one JSON document under the `checkpoint.json` data key.

### The `checkpoint.json` schema

The journal is a single JSON document under the ConfigMap's `checkpoint.json` data key. Top-level fields:

| Field | Meaning |
|---|---|
| `version` | journal schema version (currently `1`) |
| `kraftController`, `namespace` | the KRaftController this journal belongs to |
| `seedPod` | the seed you picked (stamped when `recover-region` starts; empty during click 1) |
| `status` | overall cycle phase — see the phase table below |
| `startedAt`, `updatedAt` | RFC3339 timestamps: journal creation and last write |
| `logLengths[]` | click-1 offset readout — one entry per controller |
| `steps[]` | the ordered per-step journal |

Each `logLengths[]` entry: `pod` (controller pod) and `output` (the **raw** `epoch: N, log end offset: M` line, verbatim — your seed-decision input).

Each `steps[]` entry:

| Field | Meaning |
|---|---|
| `seq` | 1-based order the step was first recorded |
| `step` | step name (see the step table below) |
| `pod` | the controller pod the step acted on |
| `status` | `started` \| `succeeded` \| `failed` \| `manual` (below) |
| `startedAt`, `completedAt` | RFC3339 timestamps |
| `output` | command output (truncated at 4000 chars), recorded on success |
| `error` | failure cause, recorded on `failed` |

**`status` — overall cycle phase:**

| Phase | Meaning |
|---|---|
| `log-length-started` | click 1 in progress (parking / reading offsets) |
| `log-length-done` | click 1 finished; `recover-region` not yet started |
| `recover-region-started` | click 2 in progress **or interrupted** — this is the resumable state |
| `recover-region-done` | click 2 finished successfully |

**`status` — per step:**

| Value | Meaning |
|---|---|
| `started` | written **before** the command runs. A dangling `started` means the process died mid-step: it may or may not have applied, so resume decides by which redo is safe — never by assuming it didn't run |
| `succeeded` | the command completed cleanly |
| `failed` | the command ran but returned an error (`error` holds the cause) |
| `manual` | an irreversible step (`force-standalone`) you completed by hand and acknowledged with `--force-standalone-done`; treated like `succeeded` (skipped) on re-run |

### What each step does

Every step below is a `steps[]` entry. Same columns for both clicks:

| Step | Click | What it does | On failure |
|---|---|---|---|
| `enter-maintenance` | `log-length` | adds each surviving controller to the CR's maintenance-mode annotation; the operator **restarts the pod**, which comes back with its main container parked at a sleep (the KRaft process is **not** running) so it can't serve or mutate metadata | click 1 is restartable — just re-run `log-length` |
| `read-log-end-offset` | `log-length` | reads each parked controller's `(epoch, log end offset)` into `logLengths` — your seed-decision input | click 1 is restartable — just re-run `log-length` |
| `snapshot` | `recover-region` | copies every controller's metadata to a backup dir before any mutation (skip with `--skip-backup` if you hold a PV snapshot) | redoable — re-run `recover-region` |
| `force-standalone` | `recover-region` | **IRREVERSIBLE** — rewrites the voter set on the **seed** to the seed alone, so it can lead a single-voter quorum | **never auto-retried — see (b) below** |
| `remove-seed-from-maintenance` | `recover-region` | removes the seed from the maintenance annotation; the operator restarts it and it comes back **running** and leads the new single-voter quorum | redoable — re-run `recover-region` |
| `clear-metadata` | `recover-region` | wipes a non-seed controller's stale metadata while it is still parked (its snapshot is already retained) | redoable — re-run `recover-region` |
| `remove-pod-from-maintenance` | `recover-region` | removes that controller from the maintenance annotation; the operator restarts it and it comes back as an **Observer** | redoable — re-run `recover-region` |
| `add-controller` | `recover-region` | promotes that Observer to a **Voter** (idempotent: re-adding an existing voter — `DuplicateVoterException` — counts as success) | redoable — re-run `recover-region` |

`snapshot`, `clear-metadata`, `remove-pod-from-maintenance`, and `add-controller` recur per non-seed controller, so `steps[]` has one entry per (step, pod). There is no explicit final "clear maintenance" step — the annotation key is dropped automatically when the last pod leaves maintenance.

### A real `checkpoint.json`

```json
{
  "version": 1,
  "kraftController": "kraftcontroller",
  "namespace": "dc2",
  "seedPod": "kraftcontroller-1",
  "status": "recover-region-done",
  "startedAt": "2026-06-27T01:10:02Z",
  "updatedAt": "2026-06-27T01:28:44Z",
  "logLengths": [
    { "pod": "kraftcontroller-0", "output": "epoch: 7, log end offset: 5240" },
    { "pod": "kraftcontroller-1", "output": "epoch: 8, log end offset: 5238" },
    { "pod": "kraftcontroller-2", "output": "epoch: 7, log end offset: 5240" }
  ],
  "steps": [
    { "seq": 1,  "step": "enter-maintenance",            "pod": "kraftcontroller-0", "status": "succeeded", "startedAt": "2026-06-27T01:10:05Z", "completedAt": "2026-06-27T01:10:41Z" },
    { "seq": 2,  "step": "enter-maintenance",            "pod": "kraftcontroller-1", "status": "succeeded", "startedAt": "2026-06-27T01:10:41Z", "completedAt": "2026-06-27T01:11:16Z" },
    { "seq": 3,  "step": "enter-maintenance",            "pod": "kraftcontroller-2", "status": "succeeded", "startedAt": "2026-06-27T01:11:16Z", "completedAt": "2026-06-27T01:11:52Z" },
    { "seq": 4,  "step": "read-log-end-offset",          "pod": "kraftcontroller-0", "status": "succeeded", "output": "epoch: 7, log end offset: 5240" },
    { "seq": 5,  "step": "read-log-end-offset",          "pod": "kraftcontroller-1", "status": "succeeded", "output": "epoch: 8, log end offset: 5238" },
    { "seq": 6,  "step": "read-log-end-offset",          "pod": "kraftcontroller-2", "status": "succeeded", "output": "epoch: 7, log end offset: 5240" },
    { "seq": 7,  "step": "snapshot",                     "pod": "kraftcontroller-0", "status": "succeeded" },
    { "seq": 8,  "step": "snapshot",                     "pod": "kraftcontroller-1", "status": "succeeded" },
    { "seq": 9,  "step": "snapshot",                     "pod": "kraftcontroller-2", "status": "succeeded" },
    { "seq": 10, "step": "force-standalone",             "pod": "kraftcontroller-1", "status": "succeeded", "output": "Reset voter set to kraftcontroller-1" },
    { "seq": 11, "step": "remove-seed-from-maintenance", "pod": "kraftcontroller-1", "status": "succeeded" },
    { "seq": 12, "step": "clear-metadata",               "pod": "kraftcontroller-0", "status": "succeeded" },
    { "seq": 13, "step": "remove-pod-from-maintenance",  "pod": "kraftcontroller-0", "status": "succeeded" },
    { "seq": 14, "step": "add-controller",               "pod": "kraftcontroller-0", "status": "succeeded", "output": "Added controller 9990 with directory id ... " },
    { "seq": 15, "step": "clear-metadata",               "pod": "kraftcontroller-2", "status": "succeeded" },
    { "seq": 16, "step": "remove-pod-from-maintenance",  "pod": "kraftcontroller-2", "status": "succeeded" },
    { "seq": 17, "step": "add-controller",               "pod": "kraftcontroller-2", "status": "succeeded", "output": "Added controller 9992 with directory id ... " }
  ]
}
```

The seed here is `kraftcontroller-1` because it has the **highest epoch (8)** — even though its log end offset (5238) is *lower* than the other two (5240). Epoch wins; offset only breaks ties within the same epoch. The seed is the only pod with no `clear-metadata`/`remove-pod`/`add-controller` steps — it keeps its log and becomes the sole voter via `force-standalone`, then leads while the others wipe and rejoin.

### Handling a failure

Resume is just re-running the failed click — no special flag. Whichever fails, the cluster is **left parked** for inspection; inspect the journal directly (there's no read subcommand):
```bash
kubectl get configmap <kraftcontroller-name>-dr-checkpoint -n <ns> \
  -o jsonpath='{.data.checkpoint\.json}' | jq '.steps'
```
`steps[]` (status/error/output) is your post-mortem; `status` is the overall phase.

**(a) Any step except `force-standalone`** — every other step (in both clicks) is idempotent/read-only, so you just re-run the click that failed and recovery resumes; the cluster stays parked meanwhile.
- **Click 1 (`log-length`) failed** — re-run it. It re-parks from scratch (parking + offset reads are idempotent), and refuses to re-park only once `recover-region` has started, so it can't disrupt an in-flight recovery:
  ```bash
  kubectl confluent kraft log-length --context <ctx> -n <ns>
  ```
- **Click 2 (`recover-region`) failed** — re-run it with the **same** seed. `succeeded`/`manual` steps are skipped and the failed/dangling one is retried:
  ```bash
  kubectl confluent kraft recover-region --context <ctx> -n <ns> --seed-pod <same-pod>
  ```
  A *different* `--seed-pod` on an in-flight recovery is refused — that would risk seeding from the wrong log.

**(b) Recover-bootstrap failure — `force-standalone`** (the one irreversible step that re-establishes the seed as the sole bootstrap voter). A failed or interrupted attempt may have **already partially rewritten the voter set**, so the plugin **halts, leaves the cluster parked, and will NOT run it again** — and deliberately does not hand you the command to re-run it yourself. **Do not blindly retry it.**
1. Engage Confluent support to inspect the seed's metadata + voter state and determine whether force-standalone actually completed.
2. Once support confirms it is complete, resume from the **next** step — the plugin records force-standalone as `manual` and continues:
   ```bash
   kubectl confluent kraft recover-region --context <ctx> -n <ns> --seed-pod <same-pod> --force-standalone-done
   ```
   `--force-standalone-done` is ignored on a fresh run — it applies only when a prior run left force-standalone `started`/`failed`.

**(c) Take manual control — finish the recovery by hand.** If you'd rather not keep re-running the plugin (or you hit something it can't resolve), you can complete the recovery by hand, and the checkpoint tells you **exactly where to pick up**. The plugin's steps map **1:1** to the [manual recovery procedure](../manual-recovery/README.md) (park → measure offsets → pick seed → snapshot → `force-standalone` → release seed → clear + rejoin each other controller), so there is no lost work — you resume the manual flow from wherever the plugin stopped:

1. Read the journal and find the **last `succeeded` step** and the pod it ran on:
   ```bash
   kubectl get configmap <kraftcontroller-name>-dr-checkpoint -n <ns> \
     -o jsonpath='{.data.checkpoint\.json}' | jq '.status, .seedPod, (.steps[] | {seq, step, pod, status})'
   ```
2. Continue the [manual recovery](../manual-recovery/README.md) from the **next** step after that one, for the **same seed** (`.seedPod`). Steps already `succeeded`/`manual` are done — don't repeat them. A step left `started` or `failed` is where you resume, and is safe to redo by hand — **except `force-standalone`**: see (b), confirm with support before touching the voter set.
3. The cluster stays **parked** until you release each controller, so you have time to inspect. When the quorum is rebuilt and healthy (`kafka-metadata-quorum … describe --status` shows the expected voters), delete the checkpoint ConfigMap.

> On CFK **3.2** there is no plugin — that release recovers entirely via the [manual pod-overlay path](../../cfk-3.2/README.md). The primitives and seed rule are identical; only parking (pod-overlay sidecar) and admin auth (in-pod `/tmp/admin.properties`) differ, so a checkpoint left by a 3.3 plugin run still tells you which step to resume from there.

**Start over from scratch:** delete the checkpoint ConfigMap. That clears the re-park guard and lets `log-length` run fresh:
```bash
kubectl delete configmap <kraftcontroller-name>-dr-checkpoint -n <ns>
```

**Single-operator contract.** One operator drives a recovery serially; writes are last-writer-wins with no locking. Don't run concurrent invocations and **don't hand-edit `checkpoint.json`** — the supported levers are re-run (auto-resume), `--force-standalone-done`, and deleting the ConfigMap to restart.

**Cleanup.** The plugin never deletes the checkpoint. Once the quorum is confirmed healthy, remove it: `kubectl delete configmap <kraftcontroller-name>-dr-checkpoint -n <ns>`.

## Then: restore the dead region (Phase 2)

Follow the manual Phase 2 steps in [`../manual-recovery/README.md`](../manual-recovery/README.md) to restore the dead region (dc1).

## References

- [Manual CFK 3.3 path (full step-by-step)](../manual-recovery/README.md) · [CFK 3.2 path (pod-overlay sidecar)](../../cfk-3.2/README.md) · [lossy sibling](../../../lossy-quorum-loss-recovery/cfk-3.3/kubectl-plugin-recovery/README.md)
- [`FAULT_TOLERANCE.md`](../../../../FAULT_TOLERANCE.md) · [2DC topology guide](../../../../topology-guides/2dc.md)
