# Dynamic-Quorum Troubleshooting

Failure modes and workarounds we've hit across CP 7.9.6 / 8.1.2 / 8.2.x with CFK on the dynamic-quorum playbooks. Generic — applies to any dynamic-quorum deployment, not specific to a topology or example.

For DR-specific procedures (force-standalone, region rejoin), see [`disaster-recovery/`](disaster-recovery/) instead.

---

## `kafka-metadata-quorum describe` times out / `UnsupportedVersionException: Direct-to-controller communication is not supported with the current MetadataVersion`

The admin client speaks the new "direct to controller" RPC path that requires `metadata.version` advertised by an active leader. Three causes, in order of likelihood:

1. **No leader (quorum is currently lost).** No pod can answer the admin RPC. Verify by hitting JMX directly on any kraft pod:
   ```bash
   kubectl exec <kraft-pod> -- curl -sk \
     http://localhost:7777/jolokia/read/kafka.server:type=raft-metrics
   ```
   If `current-leader=-1` (or `current-state=unattached-voted` / `candidate`), the quorum is genuinely down. Run the quorum-loss-recovery procedure.

2. **`metadata.version` was rolled back or never upgraded.** Check via:
   ```bash
   kubectl exec <kraft-pod> -- kafka-features --bootstrap-controller localhost:9074 \
     --command-config /mnt/admin-config/security.properties describe
   ```
   If `metadata.version` is below the level the admin client expects, run `kafka-features ... upgrade --metadata <ver>`.

3. **Mixed-version brokers in the cluster.** Older brokers can hold `metadata.version` low. Check across all regions:
   ```bash
   kubectl get pods -l type=kafka \
     -o jsonpath='{.items[*].spec.containers[?(@.name=="kafka")].image}'
   ```
   Align CP versions if drifted.

If the error survives all three checks, capture the full describe stack trace plus `current-state` from the raft-metrics MBean before further action — the exact reason class identifies whether it's an API mismatch or a quorum-side issue.

### CP 7.9.6 specific: `--command-config` file content matters

The legacy "merge `kafka.properties` + `security.properties`" pattern works on CP 8.1.2 but breaks on CP 7.9.6 — `kafka.properties` contains `bootstrap.servers=` (empty) and `confluent.metadata.*` keys that confuse the admin client. On 7.9.6, use **only** `/mnt/admin-config/security.properties` directly as `--command-config`.

`add-controller` is the exception: it reads `node.id` from the local config so it still needs a merged file.

---

## PVCs stuck `Pending` with `storageclass.storage.k8s.io "dummy" not found`

A previous manual recovery left `storageClassName: dummy` baked into the StatefulSet's `volumeClaimTemplates`, which is immutable. New PVCs fail to provision because no `dummy` storage class exists.

```bash
kubectl delete sts <kafka|kraftcontroller> -n <ns> --cascade=orphan
kubectl delete pvc data0-<sts>-0 data0-<sts>-1 -n <ns> --wait=false
kubectl delete pod <sts>-0 <sts>-1 -n <ns> --grace-period=0 --force
```

Operator reconciles, recreates the STS with the cluster's default storage class (e.g., `standard-rwo`), PVCs auto-provision fresh disks, pods come up. KRaft pods catch up via Raft fetch from the live leader; Kafka brokers re-replicate partition data via standard ISR.

---

## Consumer groups time out during single-region outage even though topics have RF=3

CFK injects `offsets.topic.replication.factor=1` (and `default.replication.factor`, `transaction.state.log.replication.factor`, `confluent.license.topic.replication.factor`) when `Kafka.spec.replicas < 3`. In MRC each region has 2 brokers but the global pool spans regions, so this default is wrong.

When a region goes down, ~half of `__consumer_offsets`'s 50 single-replica partitions become permanently offline → group coordinator unavailable → `kafka-console-consumer` times out, even when the topic itself has full ISR.

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

To bump RF on an already-existing internal topic, use `kafka-reassign-partitions`. The underlying gap — RF auto-injection should account for total broker count across regions — is a known CFK limitation to be addressed separately.

---

## OAuth `allowed.urls` — explicit URL list as defensive default

Some CP 7.9.x configurations have been observed to reject the `*` wildcard for `org.apache.kafka.sasl.oauthbearer.allowed.urls` (the property is validated by Kafka's OAuth login module, not CFK). The CFK default JVM template ships `*` unconditionally.

Not reproduced on a clean CP 7.9.6 cluster as of 2026-05-05; e2e-c3sso runs against cp-7.9 in CI and passes against `*`. The original report came from a Wells Fargo OCP MRC setup and may be specific to a particular OAuth code path (e.g., outbound `confluent.metadata.sasl.mechanism=OAUTHBEARER` rather than the IdP browser flow).

If your OAuth-enabled CP 7.9.x kafka pods fail to start with an `allowed.urls` validation error, set explicit URLs:

```yaml
spec:
  configOverrides:
    jvm:
      - "-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls=https://idp/.well-known/openid-configuration,https://idp/realms/foo/protocol/openid-connect/certs,https://idp/realms/foo/protocol/openid-connect/token"
```

Works on every CP version. Treat as the safe default for production OAuth deployments regardless of CP version.
