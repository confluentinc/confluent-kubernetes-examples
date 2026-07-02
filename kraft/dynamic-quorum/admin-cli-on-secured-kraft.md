# Running Admin CLI Tools on Secured KRaft

> **On CFK 3.3+ you usually don't need this.** The operator generates and mounts
> `/opt/confluentinc/etc/kafka/kafka-client.properties` on every KRaft pod —
> `kafka.properties` plus the global `security.protocol` / `sasl.*` / `ssl.*` overlay and a
> fallback `advertised.listeners`. Pass it straight to `--command-config`:
> ```bash
> kafka-metadata-quorum --command-config /opt/confluentinc/etc/kafka/kafka-client.properties \
>   --bootstrap-controller localhost:9074 describe --replication
> ```
> This page is the **fallback** for older CFK versions that don't mount the file, or if you
> ever hit a bug in the generated config and need to build one by hand.

When KRaft has TLS and/or authentication on the controller listener, admin tools (`kafka-metadata-quorum`, `kafka-features`) need a `--command-config` file. KRaft's `kafka.properties` only has **listener-level** configs (`listener.name.controller.sasl.*`) — admin tools need **global** client configs.

Plaintext examples (no TLS, no auth) don't need a command config — just use `--bootstrap-controller localhost:9074` directly.

## Building the admin properties file

Start with the KRaft server properties as a base. Copy `/opt/confluentinc/etc/kafka/kafka.properties` from any KRaft pod — it has `node.id`, `process.roles`, `log.dirs`, `advertised.listeners` which `add-controller` needs. Then add the global security properties below.

Add only the layers your controller listener has. These are independent — combine as needed.

**If TLS is enabled** (controller listener has `tls.enabled: true`):
```properties
ssl.truststore.location=<value>
ssl.truststore.password=<value>
ssl.truststore.type=<value>
```

**If mTLS** (controller listener has `authentication.type: mtls`) — add keystore in addition to truststore:
```properties
ssl.truststore.location=<value>
ssl.truststore.password=<value>
ssl.truststore.type=<value>
ssl.keystore.location=<value>
ssl.keystore.password=<value>
ssl.keystore.type=<value>
```

The values for these are already in `kafka.properties` at the listener level — look for `listener.name.controller.ssl.truststore.*` and `listener.name.controller.ssl.keystore.*`. Copy the same values but without the `listener.name.controller.` prefix.

**If SASL/PLAIN** (controller listener has `authentication.type: plain`):
```properties
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="kafka" password="kafka-secret";
```

**If OAuth** (controller listener has `authentication.type: oauth`):
```properties
sasl.mechanism=OAUTHBEARER
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="<client>" clientSecret="<secret>";
sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginCallbackHandler
sasl.oauthbearer.token.endpoint.url=<your-keycloak-token-url>
```
Note: OAuth also requires a JVM property on the CLI: `export KAFKA_OPTS="-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls=<token-url>"` (CVE-2025-27817)

**Set `security.protocol`** based on which layers you added:

| TLS | Auth | `security.protocol` |
|-----|------|---------------------|
| No | None | `PLAINTEXT` (no config needed) |
| Yes | None | `SSL` |
| No | SASL | `SASL_PLAINTEXT` |
| Yes | SASL (PLAIN or OAuth) | `SASL_SSL` |
| Yes | mTLS | `SSL` |

## Mounting the file on the pod

Create a ConfigMap with the admin properties and mount it via CFK's `mountedVolumes` so it persists across pod restarts.

**Step 1**: Create the admin properties file locally (copy `kafka.properties` from a pod, add global security configs as described above).

**Step 2**: Create a ConfigMap from the file:
```bash
kubectl create configmap kraft-admin-config \
  --from-file=admin.properties=<your-local-file> -n <namespace>
```

**Step 3**: Add `mountedVolumes` to the KRaftController CR (note: this is at `spec.mountedVolumes`, not under `podTemplate`):
```yaml
apiVersion: platform.confluent.io/v1beta1
kind: KRaftController
spec:
  mountedVolumes:
    volumes:
      - name: admin-config
        configMap:
          name: kraft-admin-config
    volumeMounts:
      - name: admin-config
        mountPath: /mnt/admin-config
```

**Why this triggers a rolling restart**: Adding `mountedVolumes` adds a new volume + volumeMount to the StatefulSet pod template. Kubernetes cannot attach new volumes to running pods — the pod spec is immutable after creation — so it triggers a rolling update. Note that updating the **contents** of an already-mounted ConfigMap/Secret does NOT require a restart (kubelet auto-syncs the data). The restart only happens because you are adding a new volume mount for the first time.

**Tip**: If you know you will need this file, add the `mountedVolumes` at initial deployment time (even with a placeholder ConfigMap) to avoid an extra roll later. If you are adding it to an already running cluster, try to club it with another change that requires a roll (e.g., adding `advertisedListenersEnabled`, changing TLS config) so you only pay for one rolling restart instead of two.

After the roll completes, the file is available at `/mnt/admin-config/admin.properties` on every KRaft pod.

**Alternative (no restart)**: `kubectl cp` the properties file into running pods directly. However, this does not persist across pod restarts — you would need to copy the file again each time a pod restarts.

## Running commands

```bash
kafka-metadata-quorum --bootstrap-controller localhost:9074 \
  --command-config /mnt/admin-config/admin.properties describe --replication

kafka-features --bootstrap-controller localhost:9074 \
  --command-config /mnt/admin-config/admin.properties describe

# add-controller reads node.id, process.roles, advertised.listeners from the base server properties
kafka-metadata-quorum --bootstrap-controller <bootstrap-endpoint>:9074 \
  --command-config /mnt/admin-config/admin.properties add-controller
```
