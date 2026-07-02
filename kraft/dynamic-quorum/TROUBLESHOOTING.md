# Dynamic-Quorum Troubleshooting

Failure modes, admin-CLI gotchas, and workarounds for dynamic-quorum KRaft on CFK. Generic — applies to any dynamic-quorum deployment, not a specific topology or example.

For DR-specific procedures (force-standalone, region rejoin), see [`disaster-recovery/`](disaster-recovery/). For building an admin properties file on older CFK, see [`admin-cli-on-secured-kraft.md`](admin-cli-on-secured-kraft.md).

## Quick checks

```bash
# Bootstrap-coordination ConfigMap
kubectl get cm kraftcontroller-dynamic-quorum -n <ns> -o yaml

# Bootstrap runs in the main container's configure script (not the init container)
kubectl logs kraftcontroller-0 -n <ns>
```

---

## Kafka CLI tool OutOfMemoryError (usually missing `--command-config`)

If any `kafka-*` CLI tool (e.g. `kafka-metadata-quorum`, `kafka-features`) crashes with:
```
ERROR Uncaught exception in thread 'kafka-admin-client-thread | adminclient-1'
java.lang.OutOfMemoryError: Java heap space
```
**The most common cause is missing security configuration**, not insufficient heap. When the CLI cannot authenticate with the KRaft controller (e.g. missing `--command-config` with SSL/SASL properties), it retries internally and leaks memory until it hits the default 256MB ceiling. Increasing heap with `KAFKA_HEAP_OPTS="-Xmx512m"` only delays the crash — the real fix is providing the correct `--command-config`. On CFK 3.3+ that's the mounted `/opt/confluentinc/etc/kafka/kafka-client.properties`; on older versions see [`admin-cli-on-secured-kraft.md`](admin-cli-on-secured-kraft.md).

If you are certain the security config is correct and the OOM is genuine (e.g. large metadata on a plaintext cluster), then increase heap:
```bash
KAFKA_HEAP_OPTS="-Xmx512m" kafka-metadata-quorum ...
```

---

## Admin CLI `--command-config` on secured clusters <a name="admin-cli-command-config"></a>

`kafka.properties` cannot be used directly as `--command-config` for `kafka-metadata-quorum` or `kafka-features` on secured clusters. It only contains **listener-level** security properties (e.g. `listener.name.controller.ssl.truststore.location`, `listener.name.controller.plain.sasl.jaas.config`), which the admin client ignores. Admin CLI tools are Kafka clients — they need **global-level** properties (`ssl.truststore.location`, `sasl.jaas.config`, `security.protocol`, etc.). With listener-prefixed-only config the client has effectively no security config and fails with a `TimeoutException` or `OutOfMemoryError` (the underlying Kafka error is unhelpfully generic, which is why this gotcha exists).

**On CFK 3.3+ you don't build this file yourself.** The operator generates and mounts `/opt/confluentinc/etc/kafka/kafka-client.properties` on every KRaft pod — it's `kafka.properties` plus the global `security.protocol` / `sasl.*` / `ssl.*` overlay and a fallback `advertised.listeners`, so it works as `--command-config` as-is (including for `add-controller`, which also needs `node.id`, `process.roles`, `log.dirs`, `advertised.listeners`):
```bash
kafka-metadata-quorum --command-config /opt/confluentinc/etc/kafka/kafka-client.properties \
  --bootstrap-controller localhost:9074 describe --replication
```
Only on older CFK versions that don't mount this file do you build one by hand — see [`admin-cli-on-secured-kraft.md`](admin-cli-on-secured-kraft.md).

### CP 7.9.6 specific: `--command-config` file content matters

The legacy "merge `kafka.properties` + `security.properties`" pattern works on CP 8.1.2 but breaks on CP 7.9.6 — `kafka.properties` contains `bootstrap.servers=` (empty) and `confluent.metadata.*` keys that confuse the admin client. On 7.9.6, use **only** the global `security.properties` directly as `--command-config`. `add-controller` is the exception: it reads `node.id` from the local config so it still needs a merged file.

---

## `advertised.listeners` missing or empty in `--command-config` <a name="advertised-listeners-command-config"></a>

When you run `add-controller`, the leader reads the new voter's endpoint from the `advertised.listeners` in the properties file you pass via `--command-config`. If that file has no `advertised.listeners`, or has the empty-host form `CONTROLLER://:9074`, it misbehaves (two symptoms, same root cause):

- **`No subject alternative DNS name matching localhost found`** — the empty host resolves to `localhost`, so the leader tries to connect back to its **own** localhost (not the new voter's pod); the leader's cert has a different FQDN as SAN, so the SSL handshake fails.
- **`Voter key for VOTE or BEGIN_QUORUM_EPOCH request didn't match the receiver's replica key` spam** — a bug in the `kafka-metadata-quorum` CLI (not the controller): with no `advertised.listeners` in the command-config, the leader spams this. If you already hit it and the quorum is otherwise formed, **kill the leader pod once** — the stale CLI state doesn't survive a restart.

Fix: set `advertised.listeners=CONTROLLER://<real-fqdn>:9074` in the **client properties file** passed via `--command-config`. This is separate from `advertisedListenersEnabled` in the KRaftController CR spec — the CR spec controls the KRaft **server** properties and is only needed for MRC (cross-cluster DNS resolution, where the [MRC advertised-listeners bug](README.md#mrc-version-compatibility) comes into play). On CFK 3.3+ the mounted `kafka-client.properties` already carries a usable `advertised.listeners`. **CP 8.2+ avoids both symptoms entirely** — with `controller.quorum.auto.join.enable=true`, observer-to-voter promotion happens automatically and never invokes the CLI.

---

## SSL endpoint identification and cert SANs

CFK auto-generated certs include the pod FQDN (`<pod>.<statefulset>.<namespace>.svc.cluster.local`) as a SAN, not `localhost`. So:
- `--bootstrap-controller localhost:9074` → cert SAN mismatch → SSL fails
- `--bootstrap-controller <pod-fqdn>:9074` → matches SAN → works without disabling endpoint identification

Do not disable `ssl.endpoint.identification.algorithm` — use the FQDN in `--bootstrap-controller` instead.

---

## `kafka-metadata-quorum describe` times out / `UnsupportedVersionException: Direct-to-controller communication is not supported with the current MetadataVersion`

The admin client speaks the "direct to controller" RPC path that requires a `metadata.version` advertised by an active leader. Three causes, in order of likelihood:

1. **No leader (quorum is currently lost).** No pod can answer the admin RPC. Verify by hitting JMX directly on any kraft pod:
   ```bash
   kubectl exec <kraft-pod> -n <ns> -- curl -sk \
     http://localhost:7777/jolokia/read/kafka.server:type=raft-metrics
   ```
   If `current-leader=-1` (or `current-state=unattached-voted` / `candidate`), the quorum is genuinely down. Run the quorum-loss-recovery procedure in [`disaster-recovery/`](disaster-recovery/).

2. **`metadata.version` was rolled back or never upgraded.** Check via `kafka-features ... describe`; if below the level the admin client expects, run `kafka-features ... upgrade --metadata <ver>`.

3. **Mixed-version brokers in the cluster.** Older brokers can hold `metadata.version` low. Check the CP image across all regions and align if drifted.

If the error survives all three checks, capture the full describe stack trace plus `current-state` from the raft-metrics MBean — the exact reason class identifies whether it's an API mismatch or a quorum-side issue.

---

## `remove-controller` has no lasting effect with auto-join (CP 8.2+) <a name="remove-controller-auto-join"></a>

With `controller.quorum.auto.join.enable=true` (default on CP 8.2+), running `remove-controller` on a controller whose pod is still running does nothing permanent — the controller re-joins as an observer and promotes itself back to voter. `remove-controller` only sticks if the target pod is **stopped** (scaled down, deleted, or crashed) or auto-join is disabled. To test it manually, stop the removed controller's pod immediately after removal. This is the desired production behavior — auto-join provides automatic recovery from transient controller failures.

---

## Bootstrap ConfigMap marked formatted too early → setup stuck with zero voters

If the `kraftcontroller-dynamic-quorum` ConfigMap reads `bootstrap_formatted: true` before the bootstrap pod has actually formatted (e.g. it was hand-edited, or carried over from a previous cluster), the bootstrap pod formats in rejoin mode instead of bootstrap mode → no initial voter is created → setup hangs. Recovery: delete the bootstrap pod's PVC (it goes `Pending`), then delete the bootstrap pod. On restart the PVC is recreated, the volume formats as the standalone bootstrap, and the pod becomes the leader as intended.

---

## Bootstrap / init container stuck (RBAC)

The bootstrap pod must be able to update the dynamic-quorum bootstrap ConfigMap. Check the ServiceAccount's permissions (replace `<namespace>` / `<service-account-name>` with your KRaftController namespace and `spec.podTemplate.serviceAccountName`):
```bash
kubectl auth can-i update configmaps --as=system:serviceaccount:<namespace>:<service-account-name> -n <namespace>
```

---

## Cluster ID mismatch (MRC)

In MRC you must pass the cluster ID in the specs. If you don't, the second region generates its own cluster ID and acts as a separate cluster instead of a second region of the MRC cluster. Verify it matches across all controllers:
```bash
for i in 0 1 2; do
  echo "kraftcontroller-$i:"
  kubectl exec kraftcontroller-$i -n <ns> -- cat /var/lib/kafka/data/meta.properties | grep cluster.id
done
```

---

## `advertisedListeners` changes don't auto-roll the controllers <a name="advertisedlisteners-no-auto-roll"></a>

CFK deliberately does **not** roll pods when the `init-config` ConfigMap changes — init-config holds per-pod metadata (`node.id`, `log.dirs`, `process.roles`) not expected to change at runtime, so the operator only rolls on `shared-config` changes (TLS, SASL, quorum config, JVM, etc.). `advertised.listeners` is the exception: it lives in init-config (it's pod-specific) but **does** need a restart to take effect. So after adding/changing external access / `advertisedListeners` on a running cluster, the operator updates `init-config` but the pods do **not** restart on their own. Trigger an operator-managed rolling restart by bumping a pod-template annotation (do **not** patch the StatefulSet directly — the operator overwrites it):
```bash
kubectl patch kraftcontroller kraftcontroller -n <namespace> --type=merge \
  -p '{"spec":{"podTemplate":{"annotations":{"kafkacluster-manual-roll":"2"}}}}'
```
Increment the value each time you need another roll.

---

## MRC greenfield startup hangs: `channel manager timed out before sending the request` (advertised-listeners bug) <a name="mrc-greenfield-hang"></a>

```
[ControllerRegistrationManager id=100] RegistrationResponseHandler: channel manager timed out before sending the request
```
If you see this while bringing up a **dynamic-quorum MRC** cluster (advertised listeners present from initial creation), **you're on a CP version with the advertised-listeners bug** ([KAFKA-20247](https://issues.apache.org/jira/browse/KAFKA-20247)). **Root cause**: the initial `ControllerRegistration` RPC times out; `failedRPC` increments but `pendingRPC` is never reset, so every later attempt skips sending and the bootstrap voter never registers. It triggers on any external-access type: even with DNS pre-resolved, LB forwarding rules take seconds to provision, so the first RPC times out. **Fix**: use a CP version with the fix — **7.9.6+, 8.0.5+, 8.1.2+, 8.2.1+, or 8.3.0+** (affected: 7.9.5, 8.0.0-8.0.4, 8.1.1, 8.2.0). Background: [MRC Version Compatibility](README.md#mrc-version-compatibility).

---

## ZK→KRaft migration: do I need to set `kraft-migration-ibp-version`? <a name="ibp-migration"></a>

On **CFK 3.3.0+**: not for standard CP images — CFK auto-infers the IBP (`inter.broker.protocol.version`) from the Kafka image tag (CP 7.0-7.9 → IBP 3.0-3.9). The `platform.confluent.io/kraft-migration-ibp-version` annotation is then only needed for **custom images** or CP versions CFK doesn't have a mapping for (it errors and asks you to set it); if you set it on a standard image, CFK ignores it (and warns if it disagrees with the derived value). **On CFK earlier than 3.3.0 the annotation is mandatory** — auto-inference isn't available, so set `platform.confluent.io/kraft-migration-ibp-version` yourself (e.g. `"3.9"` for the dynamic-quorum migration).

---

## PVCs stuck `Pending` with `storageclass.storage.k8s.io "dummy" not found`

A previous manual recovery left `storageClassName: dummy` baked into the StatefulSet's `volumeClaimTemplates`, which is immutable. New PVCs fail to provision because no `dummy` storage class exists.
```bash
kubectl delete sts <kafka|kraftcontroller> -n <ns> --cascade=orphan
kubectl delete pvc data0-<sts>-0 data0-<sts>-1 -n <ns> --wait=false
kubectl delete pod <sts>-0 <sts>-1 -n <ns> --grace-period=0 --force
```
The operator reconciles, recreates the STS with the cluster's default storage class, PVCs auto-provision fresh disks, pods come up. KRaft pods catch up via Raft fetch from the live leader; Kafka brokers re-replicate via standard ISR.

---

## Pod stuck `Pending` / `FailedAttachVolume … NotFound … Error 404 … disks/pvc-…` — the underlying cloud disk was deleted <a name="disk-deleted"></a>

`reclaimPolicy: Retain` protects the PVC, not against a direct cloud-API disk deletion (e.g. a stray `delete_unattached_disks` job). Confirm with `gcloud compute disks list --filter="name=<pv-name>"` (empty = gone). Recovery — replace each lost PV with a fresh disk so pods can schedule, then the normal Observer→Voter promotion applies. You do **not** hand-craft PVs; you delete the orphan PVC/PV and let CFK recreate real ones (your storage class, not the `dummy` volumeClaimTemplate placeholder):
```bash
CTX=<region-ctx>;  REGION=<region>
# 1. Force-delete the stuck pods.
kubectl --context $CTX delete pod -n $REGION --grace-period=0 --force kafka-0 kafka-1 kraftcontroller-0 kraftcontroller-1
# 2. Delete the orphan PVCs (strip the pvc-protection finalizer if they hang).
kubectl --context $CTX delete pvc -n $REGION data0-kafka-0 data0-kafka-1 data0-kraftcontroller-0 data0-kraftcontroller-1 --timeout=10s || true
for p in data0-kafka-0 data0-kafka-1 data0-kraftcontroller-0 data0-kraftcontroller-1; do
  kubectl --context $CTX patch pvc $p -n $REGION -p '{"metadata":{"finalizers":null}}'
done
# 3. Delete the orphan PVs (they reference disks that no longer exist).
for pv in <orphan-pv-names>; do
  kubectl --context $CTX delete pv $pv --timeout=10s || true
  kubectl --context $CTX patch pv $pv -p '{"metadata":{"finalizers":null}}'
done
# 4. Re-delete the pods, then scale the STS to 0 and back so CFK creates real PVCs bound to fresh PVs.
kubectl --context $CTX delete pod -n $REGION --grace-period=0 --force kafka-0 kafka-1 kraftcontroller-0 kraftcontroller-1
kubectl --context $CTX scale statefulset kafka -n $REGION --replicas=0
kubectl --context $CTX scale statefulset kafka -n $REGION --replicas=2
```

---

## Consumer groups time out during a single-region outage even though topics have RF=3

CFK injects `offsets.topic.replication.factor=1` (and `default.replication.factor`, `transaction.state.log.replication.factor`, `confluent.license.topic.replication.factor`) when `Kafka.spec.replicas < 3`. In MRC each region has 2 brokers but the global pool spans regions, so this default is wrong.

When a region goes down, ~half of `__consumer_offsets`'s 50 single-replica partitions become permanently offline → group coordinator unavailable → consumers time out, even when the topic itself has full ISR.

Workaround — set in the Kafka CR **before first bringup** (internal topics are auto-created at first activity, RF fixed at creation time):
```yaml
spec:
  configOverrides:
    server:
      - "default.replication.factor=3"
      - "offsets.topic.replication.factor=3"
      - "transaction.state.log.replication.factor=3"
      - "transaction.state.log.min.isr=2"
      - "confluent.license.topic.replication.factor=3"
      - "min.insync.replicas=2"
```
To bump RF on an already-existing internal topic, use `kafka-reassign-partitions`.

---

## OAuth `allowed.urls` rejected — use an explicit URL list

Some CP 7.9.x configurations reject the `*` wildcard for `org.apache.kafka.sasl.oauthbearer.allowed.urls` (the property is validated by Kafka's OAuth login module, not CFK). If your OAuth-enabled CP 7.9.x kafka pods fail to start with an `allowed.urls` validation error, set explicit URLs:
```yaml
spec:
  configOverrides:
    jvm:
      - "-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls=https://idp/.well-known/openid-configuration,https://idp/realms/foo/protocol/openid-connect/certs,https://idp/realms/foo/protocol/openid-connect/token"
```
Works on every CP version. A safe default for production OAuth deployments regardless of CP version.
