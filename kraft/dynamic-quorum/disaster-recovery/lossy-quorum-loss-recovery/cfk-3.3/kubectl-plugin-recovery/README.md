# DR: KRaft Quorum Loss Recovery — 2.5DC 2-2-1 (lossy) — kubectl plugin (2-click)

The **lossy** 2.5DC variant of the plugin path. It runs the **same two commands** as the
data-safe example — install steps, flags, resume/safety semantics, and Phase 2 are all
identical, so they live once in the canonical
[**data-safe kubectl-plugin README**](../../../quorum-loss-recovery/cfk-3.3/kubectl-plugin-recovery/README.md).
**The only difference is data safety.**

> ## ⚠ READ FIRST — this procedure can lose committed writes
>
> 2.5DC 2-2-1 = 5 voters, majority = 3. Losing dc1 + dc3 kills 3 of 5 — the dead set
> **equals** the majority, so `force-standalone` can rebuild from a seed that never saw a
> committed write. **RPO is unbounded.** Confirm you accept unknown RPO before running
> `recover-region`; prefer waiting if dc1/dc3's disks are intact. Math in
> [`FAULT_TOLERANCE.md`](../../../../FAULT_TOLERANCE.md). Data-safe sibling:
> [`quorum-loss-recovery/`](../../../quorum-loss-recovery/cfk-3.3/kubectl-plugin-recovery/README.md).

## Two clicks

> **Test harness only** — to fake the dc1+dc3 outage so the surviving region loses quorum:
> in a real disaster the regions are already down; to rehearse, scale those regions'
> controllers to 0 or cordon/force-delete their pods.

```bash
# Click 1 — park dc2's controllers, read each one's epoch + offset.
kubectl confluent kraft log-length --context <dc2-context> -n dc2

# Pick the SEED: largest epoch, then (only on a tie) largest offset.

# Click 2 — rebuild from the seed (dc2 grows back to 2 voters here, vs 3 in 2DC).
kubectl confluent kraft recover-region --context <dc2-context> -n dc2 --seed-pod <pod>
```

Phase 2 — restore the dead regions (dc1 and dc3): follow the manual Phase 2 steps in [`../manual-recovery/README.md`](../manual-recovery/README.md).

For flags (`--seed-pod`, `--yes`, `--timeout`, `--skip-backup`, `--force-standalone-done`,
`--metadata-log-dir`), install steps, and resume/safety semantics, see the
[canonical README](../../../quorum-loss-recovery/cfk-3.3/kubectl-plugin-recovery/README.md#flags-worth-knowing).

## References

- [Canonical data-safe plugin README (flags, resume, safety)](../../../quorum-loss-recovery/cfk-3.3/kubectl-plugin-recovery/README.md) · [Manual CFK 3.3 path](../manual-recovery/README.md) · [CFK 3.2 path](../../cfk-3.2/README.md)
- [`FAULT_TOLERANCE.md`](../../../../FAULT_TOLERANCE.md) · [2.5DC topology guide](../../../../topology-guides/2-5dc.md)
