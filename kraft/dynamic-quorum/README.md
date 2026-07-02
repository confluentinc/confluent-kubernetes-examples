# Dynamic KRaft Quorum (KIP-853) in Confluent for Kubernetes

This document provides a comprehensive overview of the Dynamic KRaft feature ([KIP-853](https://cwiki.apache.org/confluence/display/KAFKA/KIP-853)) and its implementation in Confluent for Kubernetes (CFK).

### kraft.version Quick Reference

| kraft.version | Quorum Type | Config Property | Description |
|---------------|-------------|-----------------|-------------|
| **0** | **Static Quorum** | `controller.quorum.voters` | Fixed controller membership, set at cluster creation |
| **1** | **Dynamic Quorum (KIP-853)** | `controller.quorum.bootstrap.servers` | Controllers can be added/removed dynamically |

---

## Version Compatibility

### Confluent Platform

| Feature | CP Version | CFK Version | Status |
|---------|---------|--------|--------|
| **KRaft (Static Quorum)** | CP 7.4+ | All active CFK versions| ✅ Supported (continues in all future versions) |
| **KRaft (Dynamic Quorum)** | CP 7.9+ | CFK 3.2+ | Using latest CP patch recommended |
| **KRaft (Dynamic Quorum) MRC** | 7.9.6+, 8.0.5+, 8.1.2+, 8.2.1+, 8.3.0+ | CFK 3.2+ | Needs the [MRC advertised-listeners fix](#mrc-version-compatibility). Earlier patches (8.0.0-8.0.4, 8.2.0) have the MRC bug. |
| **Auto-Join Dynamic Quorum** | CP 8.2+ | CFK 3.2+ | Simplifies observer promotion (no manual `add-controller`) |
| **ZK → KRaft (Dynamic Quorum) Migration** | CP 7.9.6+ | CFK 3.2+ | Use CP 7.9 only — ZK is removed in CP 8.0+ |
| **Static → Dynamic KRaft Migration** | CP 8.0+ | CFK 3.2+ | Works on all 8.0+ versions for both Single Region and MRC — not affected by the MRC advertised-listeners bug |
| **KRaft controller scale-up (roll-free)** | CP 7.9+ (voter auto-join CP 8.2+) | **CFK 3.3+** | Increase `replicas` without rolling existing controllers/brokers; scale-down not supported |
| **Auto-mounted admin `kafka-client.properties`** | — | **CFK 3.3+** | Admin CLI config mounted on kraft pods; pre-3.3 requires a manually built admin properties file |
| **`kubectl confluent kraft` quorum-loss DR plugin** | — | **CFK 3.3+** | 2-click quorum-loss recovery (`log-length`/`recover-region`); pre-3.3 uses the manual DR procedure |


Users must upgrade to **CFK 3.2+** to use dynamic quorum features. See [CFK upgrade documentation](https://docs.confluent.io/operator/current/co-upgrade.html).

**Key Notes**:
- **CP 7.9.6+ or 8.1.2+** recommended for dynamic quorum. For single-cluster (non-MRC) deployments, CP 8.0.4+ and 8.2.0+ also work fine — the version restrictions above are specific to MRC greenfield. CP 8.0.5+, 8.2.1+, and 8.3.0+ also carry the MRC advertised-listeners fix, so MRC greenfield works on those too.
- **CP 8.2+** has support for auto-join (reduces manual promotion steps)
- All active CFK versions support KRaft static quorum deployment
- **CFK 3.2+** adds dynamic quorum support and KRaft Migration Job (KMJ)
- ZK → KRaft migration with dynamic quorum is only on CP 7.9.6+ (ZK removed in 8.0)
- **KRaft controller scale-up is supported on CFK 3.3+** (requires `dynamicQuorumConfig.enabled: true`). Increasing `KRaftController.spec.replicas` adds controllers without rolling the existing controllers or the Kafka brokers; on CP 8.2+ the new controllers auto-join the quorum as voters, and on CP < 8.2 they come up as observers that you promote manually with `kafka-metadata-quorum add-controller`. **Scale-down is not supported** — the operator rejects a `replicas` decrease, because a StatefulSet shrink drops the highest-ordinal pod regardless of voter status and could drop a live voter and lose quorum.

### MRC Version Compatibility

> Any MRC setup with dynamic quorum needs advertised listeners for cross-cluster communication. Defining them from initial cluster creation triggers a known CP registration-timeout bug ([KAFKA-20247](https://issues.apache.org/jira/browse/KAFKA-20247)), fixed in the versions below.

**Why advertised listeners are mandatory for dynamic MRC**: In **static quorum** MRC, `advertised.listeners` on KRaft controllers was not mandatory — `controller.quorum.voters` already carried all endpoints. In **dynamic quorum** MRC it **is** mandatory in the KRaft server properties: without it a KRaft controller sends its local in-cluster DNS to the others, which a controller in the other K8s cluster can't resolve, so it fails to join the quorum. (The `advertised.listeners` in the **client** properties file passed to `--command-config` is a separate thing and is unaffected — see [Troubleshooting](#45-troubleshooting-tips) item 3.)

Which CP versions work, by deployment path:

| Deployment Path | Affected by the advertised-listeners bug? | CP Versions That Work |
|----------------|------------------------|----------------------|
| **MRC Greenfield** (advertised listeners from start) | Yes | 7.9.6+, 8.0.5+, 8.1.2+, 8.2.1+, 8.3.0+ |
| **MRC ZK → KRaft (Dynamic Quorum) Migration** (advertised listeners from start) | Yes | 7.9.6+ (ZK only ships in 7.9.x) |
| **MRC Static→Dynamic Migration** (advertised listeners added after quorum formed) | No | All CP 8.0+ |
| **Single-cluster** (no advertised listeners) | No | All CP versions |

The static→dynamic migration path avoids the bug because advertised listeners are added **after** the quorum is already formed — the bug only triggers when they're present at initial pod startup. If you hit the registration-timeout symptom on MRC greenfield, you're on an affected CP version — see [Troubleshooting](#45-troubleshooting-tips) item 10.

## 1. Why is Dynamic KRaft Needed?

### The Problem with Static KRaft

In the original KRaft implementation (cp  7.4 onwards), the controller quorum was **static**:

- Controller membership was fixed at cluster creation time
- Defined in `controller.quorum.voters` property (e.g., `1@host1:9093,2@host2:9093,3@host3:9093`)
- **Cannot add or remove controllers** without recreating the entire cluster
- **Cannot recover from controller failure** without manual intervention
- **Cannot scale the quorum** to handle increased metadata load

### Real-World Impact

**Problem Scenarios**:

1. **Hardware Failure**: A controller node dies → Quorum permanently reduced → Risk of quorum loss
2. **Regional Disaster**: In Multi-Region Clusters (MRC), losing a region could mean permanent loss of controllers
3. **Scaling Needs**: Cannot add controllers when metadata load increases
4. **Maintenance**: Cannot safely decommission controllers for hardware upgrades

**Example**:
- 6 controllers in MRC (3 in central, 3 in east), quorum needs 4
- East region has a disk failure → 2 controllers go down
- Now only 4 controllers remain (3 central + 1 east) → Quorum maintained but fragile
- **With Dynamic KRaft**: Remove the failed controllers from quorum, fix the disks, add them back
- **With Static KRaft**: Not straightforward to restore without cluster recreation

### Business Value

- **Improved Availability**: Recover from controller failures with lesser downtime
- **Disaster Recovery**: Handle regional failures in MRC deployments with relative ease
- **Reduced Risk**: No need for full cluster recreation to change quorum membership

---

## 2. Static vs Dynamic KRaft: Technical Comparison

> **WARNING**: Simply changing `controller.quorum.voters` to `controller.quorum.bootstrap.servers`
> in the config does NOT migrate from static to dynamic quorum. The migration requires a specific
> sequence of steps including adding advertised listeners, upgrading kraft.version via the
> `kafka-features` CLI tool, and then switching properties. See the
> [migration guide](migration/static-to-dynamic/mrc/README.md) for the correct procedure.

> **NOTE**: kraft.version 0 → 1 upgrade is NOT supported on CP 7.9.x. Use CP 8.0+ for
> static → dynamic quorum migration.

### Configuration Differences

#### Static KRaft (Traditional)

**Property**: `controller.quorum.voters`

```properties
# Fixed list of all voters at startup
controller.quorum.voters=100@kraft-central0.example.com:9093,101@kraft-central1.example.com:9093,102@kraft-central2.example.com:9093,200@kraft-east0.example.com:9093,201@kraft-east1.example.com:9093
```

**Characteristics**:
- All voters must be specified upfront
- Cannot change membership after cluster starts
- All nodes must know about each other at bootstrap time

#### Dynamic KRaft (KIP-853)

**Property**: `controller.quorum.bootstrap.servers`

```properties
# Bootstrap from initial voter(s), then join dynamically
controller.quorum.bootstrap.servers=kraft-central0.example.com:9074,kraft-central1.example.com:9074,kraft-central2.example.com:9074,kraft-east0.example.com:9074,kraft-east1.example.com:9074
```

**Characteristics**:
- Only need to know one active controller to join
- New controllers join as **Observers** (read-only)
- Can be **promoted to Voters** dynamically via CLI
- Can be **removed from quorum** dynamically via CLI

### Storage Format Commands

#### Formatting Storage

**Static KRaft**:
```bash
# Must specify all voters at format time
kafka-storage format \
  --cluster-id <cluster-id> \
  --config /etc/kafka/server.properties
```

**Dynamic KRaft**:
```bash
# Bootstrap controller creates the cluster
kafka-storage format \
  --cluster-id <cluster-id> \
  --config /etc/kafka/server.properties \
  --standalone

# Other controllers format without bootstrap flag
kafka-storage format \
  --cluster-id <cluster-id> \
  --config /etc/kafka/server.properties \
  --no-initial-controllers
```

**Key Difference**: Only the **bootstrap controller** it voter initially and thus also becomes leader. Then all the observer join and eventually get promoted to voters vs in static quorum all are voters and thus anyone can become the leader in begining

#### Advertised Listeners

**Static KRaft**: Here we didnt need to define this `advertised.listeners` property. It uses the `controller.quorum.voters=100@kraft-central0.example.com:9093,101@kraft-central1.example.com:9093,102@kraft-central2.example.com:9093,200@kraft-east0.example.com:9093,201@kraft-east1.example.com:9093` to figure out the advertised listeners.

**Dynamic KRaft**:
Here we need to define `advertised.listeners` in MRC clusters. (If the cluster is limited to single region then no need as kraft/kafka can resolve each others internal k8s dns.)
See [MRC Version Compatibility](#mrc-version-compatibility) for the advertised-listeners bug that affects MRC deployments.
```
advertised.listeners=CONTROLLER://kraft-central0.example.com:9074 #pod1
advertised.listeners=CONTROLLER://kraft-central1.example.com:9074 #pod2
advertised.listeners=CONTROLLER://kraft-central2.example.com:9074 #pod3
advertised.listeners=CONTROLLER://kraft-east0.example.com:9074 #pod4
advertised.listeners=CONTROLLER://kraft-east1.example.com:9074 #pod5
advertised.listeners=CONTROLLER://kraft-east2.example.com:9074 #pod6
```

This is because here it doesnt use `controller.quorum.bootstrap.servers` property to pick advertised listeners. `controller.quorum.bootstrap.servers=kraft-central0.example.com:9074,kraft-central1.example.com:9074,kraft-central2.example.com:9074,kraft-east0.example.com:9074,kraft-east1.example.com:9074`

### Checking Quorum Mode

#### Check Configuration

```bash
$ kafka-features  --bootstrap-controller  localhost:9074 describe
Feature: confluent.metadata.version	SupportedMinVersion: CP-7.3-IV3	SupportedMaxVersion: CP-8.1-IV1A	FinalizedVersionLevel: CP-8.1-IV1A	Epoch: 11368
Feature: eligible.leader.replicas.version	SupportedMinVersion: 0	SupportedMaxVersion: 1	FinalizedVersionLevel: 0	Epoch: 11368
Feature: group.version	SupportedMinVersion: 0	SupportedMaxVersion: 1	FinalizedVersionLevel: 0	Epoch: 11368
Feature: kraft.version	SupportedMinVersion: 0	SupportedMaxVersion: 1	FinalizedVersionLevel: 0	Epoch: 11368
Feature: metadata.version	SupportedMinVersion: 3.3-IV3	SupportedMaxVersion: 4.1-IV1	FinalizedVersionLevel: UNKNOWN 0	Epoch: 11368
Feature: share.version	SupportedMinVersion: 0	SupportedMaxVersion: 1	FinalizedVersionLevel: 0	Epoch: 11368
Feature: streams.version	SupportedMinVersion: 0	SupportedMaxVersion: 1	FinalizedVersionLevel: 0	Epoch: 11368
Feature: transaction.version	SupportedMinVersion: 0	SupportedMaxVersion: 2	FinalizedVersionLevel: 0	Epoch: 11368
```

kraft.version.FinalizedVersionLevel is what determines if we are using static quoru(version 0) vs dynamic quorum(version 1) 

**Important thing to note is there is also kraft.version defined in the meta.properties file. But if this is set to 1 it merely states that using kraft with dynamic quorum i.e kip 853 is possible and not that it is in use.**

**Directory ID changes on kraft.version upgrade**: When upgrading from `kraft.version=0` (static) to `kraft.version=1` (dynamic), each controller's `DirectoryId` automatically changes from the placeholder value `AAAAAAAAAAAAAAAAAAAAAA` to a unique UUID. This is expected behavior — static quorum does not use directory IDs, so they are all set to the same placeholder. The upgrade to dynamic quorum assigns real directory IDs to each controller. These new directory IDs are what you use in `remove-controller --controller-directory-id` commands.

**`remove-controller` fails with "Remove voter request didn't include a valid voter"**: This error means you are on `kraft.version=0` (static quorum). At kraft.version=0, all directory IDs are the placeholder `AAAAAAAAAAAAAAAAAAAAAA`, which is not a valid voter identity. Dynamic quorum operations (`remove-controller`, `add-controller`) only work after upgrading to `kraft.version=1`. Example error:
```
org.apache.kafka.common.errors.InvalidRequestException: Remove voter request didn't include a valid voter
```
This is expected and confirms the cluster is still on static quorum. Proceed with the migration to kraft.version=1.

**`UnknownHostException` for cross-cluster controller FQDNs (MRC)**: When running admin commands (e.g., `kafka-metadata-quorum describe --status`) on a static quorum MRC cluster **without** `advertisedListenersEnabled`, the admin client uses internal K8s pod FQDNs (e.g., `kraftcontroller-2.kraftcontroller.central.svc.cluster.local`). Controllers in other K8s clusters cannot resolve these internal DNS names. This is expected — admin commands only work from the cluster where the leader is. After enabling `advertisedListenersEnabled` (migration step 1), the admin client uses the external LoadBalancer DNS names which resolve from any cluster.

#### Check Quorum Status

```bash
# View current quorum members
kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --status

# Dynamic quorum will show:
# - CurrentVoters: Active voting members
# - CurrentObservers: Non-voting members (either controllers who are waiting to be promoted or brokers are also in this list who are observers but will not be promoted to voters)
```

#### Check Replication Status

```bash
# View detailed replication info
kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --replication

# Output shows:
# NodeId  DirectoryId  ReplicaState  LogEndOffset  Lag  LastCaughtUpMs
# 100     <uuid>       Leader        1234567       0    <timestamp>
# 101     <uuid>       Follower      1234567       0    <timestamp>
# 102     <uuid>       Observer      1234560       7    <timestamp>  # ← Not yet promoted
```

**Note: If we have ssl or sasl set on kraft listeners then running these commands will need a client properties file to have ssl truststore and sasl credentials to talk to kraft controller listener**

### Dynamic Operations

#### Add Controller to Quorum

```bash
# Promote an observer to voter
kubectl exec kraftcontroller-2 -n central -- \
  kafka-metadata-quorum \
  --bootstrap-controller kraft-central0.example.com:9074 \
  --command-config /opt/confluentinc/etc/kafka/kafka.properties \
  add-controller
```

#### Remove Controller from Quorum

```bash
# Get directory ID first
DIRECTORY_ID=$(kubectl exec kraftcontroller-0 -n central -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 \
  describe --replication | grep "^200" | awk '{print $2}')

# Remove the controller
kubectl exec kraftcontroller-0 -n central -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 \
  remove-controller --controller-id 200 --controller-directory-id $DIRECTORY_ID
```

---

## 3. Deployment Examples

Each example has its own README with step-by-step instructions and resource YAMLs.

| Category | Example | Path | Security | MRC |
|----------|---------|------|----------|-----|
| **Greenfield** | Quickstart (includes auto-join) | [greenfield/quickstart/](greenfield/quickstart/) | None | No |
| | Secured (LDAP RBAC) | [greenfield/secured/](greenfield/secured/) | TLS + SASL/PLAIN + LDAP RBAC | No |
| | MRC — LoadBalancer (Secured) | [greenfield/mrc/2dc-greenfield-loadbalancer/](greenfield/mrc/2dc-greenfield-loadbalancer/) | TLS + SASL/PLAIN + OAuth + RBAC | Yes (LB) |
| **Static→Dynamic Migration** | Quickstart | [migration/static-to-dynamic/quickstart/](migration/static-to-dynamic/quickstart/) | None | No |
| | MRC (Secured) | [migration/static-to-dynamic/mrc/](migration/static-to-dynamic/mrc/) | TLS + SASL/PLAIN + OAuth + RBAC | Yes (LB) |
| **ZK→KRaft Migration** | Quickstart | [migration/zk-to-kraft/quickstart/](migration/zk-to-kraft/quickstart/) | None | No |
| | MRC (Secured) | [migration/zk-to-kraft/secured/](migration/zk-to-kraft/secured/) | TLS + SASL/PLAIN + OAuth + RBAC | Yes (LB) |
| **Disaster Recovery** | No quorum loss (2.5DC) | [disaster-recovery/no-quorum-loss-recovery/](disaster-recovery/no-quorum-loss-recovery/) | TLS + SASL/PLAIN + OAuth + RBAC | Yes (2 GKE clusters) |
| | Quorum loss — data-safe 2DC | [disaster-recovery/quorum-loss-recovery/](disaster-recovery/quorum-loss-recovery/) — `cfk-3.2/` (pod-overlay sidecar), `cfk-3.3/manual-recovery/`, `cfk-3.3/kubectl-plugin-recovery/` (2-click) | TLS + SASL/PLAIN + OAuth + RBAC | Yes (2 GKE clusters) |
| | Quorum loss — lossy 2.5DC | [disaster-recovery/lossy-quorum-loss-recovery/](disaster-recovery/lossy-quorum-loss-recovery/) — same three paths; data loss possible | TLS + SASL/PLAIN + OAuth + RBAC | Yes (2 GKE clusters) |

**Notes:**
- Static→Dynamic migration: no bootstrapPod, ConfigMap, or RBAC needed — the cluster is already formatted
- ZK→KRaft migration: requires bootstrapPod, ConfigMap, RBAC for initial cluster formatting
- MRC examples require advertised listeners for cross-cluster communication (see [MRC Version Compatibility](#mrc-version-compatibility))
- Disaster recovery runs on a true 2-cluster setup (deploy a dynamic-quorum MRC cluster — adapt the [greenfield MRC example](greenfield/mrc/) — in 2DC 3-3 for the data-safe path or 2.5DC 2-2-1 for the lossy/no-quorum-loss paths). The CFK 3.2 path uses a pod-overlay sidecar; the CFK 3.3 paths use maintenance-mode + the `kubectl confluent kraft` plugin. Start from [disaster-recovery/README.md](disaster-recovery/README.md).

---

## 4. Setting Up Dynamic Quorum in CFK

This section covers what you need to provide for CFK to deploy Dynamic KRaft.

### Overview

For **greenfield** and **ZK→KRaft migration** deployments, dynamic quorum needs three things in the KRaftController's namespace:

1. A bootstrap **ConfigMap** (`kraftcontroller-dynamic-quorum`)
2. A **ServiceAccount** + **Role** + **RoleBinding** granting that ConfigMap's pods access to it
3. `dynamicQuorumConfig.bootstrapPod: N` on the KRaftController CR (the pod ordinal to bootstrap)

CFK uses this ConfigMap to select exactly one controller to format as the bootstrap while the others join, and to avoid re-formatting on restart.

(Static→dynamic migration does **not** need any of these — the cluster is already formatted.)

### 4.1 Bootstrap ConfigMap

Create it once, before deploying:
```bash
kubectl create configmap kraftcontroller-dynamic-quorum \
  --from-literal=bootstrap-status='{"bootstrap_formatted": false}'
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kraftcontroller-dynamic-quorum
  namespace: central
data:
  bootstrap-status: '{"bootstrap_formatted": false}'
```

You can inspect it any time with `kubectl get cm kraftcontroller-dynamic-quorum -o yaml` to see whether the cluster has been bootstrapped.

### 4.2 Kubernetes RBAC Requirements

The KRaftController pods need access to the bootstrap ConfigMap. Grant it via a ServiceAccount referenced by the CR's pod template:

```yaml
# ServiceAccount for the pods
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kraftcontroller-sa
  namespace: central

---
# Role with ConfigMap permissions
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kraftcontroller-cm-role
  namespace: central
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["kraftcontroller-dynamic-quorum"]
  verbs: ["get", "list", "watch", "update", "patch"]

---
# RoleBinding to connect SA to Role
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kraftcontroller-cm-rolebinding
  namespace: central
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kraftcontroller-cm-role
subjects:
- kind: ServiceAccount
  name: kraftcontroller-sa
  namespace: central
```

**StatefulSet uses ServiceAccount**:
```yaml
spec:
  template:
    spec:
      serviceAccountName: kraftcontroller-sa  # ← Links pods to SA
```

**Security Principle**: Least privilege
- RBAC grants access to ONLY the specific ConfigMap needed
- RBAC is scoped to ONLY the namespace where KRaft controllers run
- No cluster-wide permissions required


### 4.3 Auto-Join (CP 8.2+)

**What auto-join does**: it **only** eliminates the manual `kafka-metadata-quorum add-controller` step — observers automatically promote themselves to voters once caught up with the leader.

**What it does NOT do**:
- ❌ Does NOT eliminate the bootstrap ConfigMap
- ❌ Does NOT eliminate bootstrap pod selection
- ❌ Does NOT change the `--standalone` vs `--no-initial-controllers` format logic
- ❌ Does NOT change RBAC requirements

Everything else (bootstrap ConfigMap, bootstrap pod `--standalone`, other pods `--no-initial-controllers` joining as observers, quorum formation) is unchanged.

**Key property**:
```properties
controller.quorum.auto.join.enable=true  # CP 8.2+ only
```

- Set accidentally on an older CP version, it is simply ignored.
- To disable it (rarely useful), use overrides:
  ```yaml
  spec:
    configOverrides:
      server:
        - controller.quorum.auto.join.enable=false
  ```

**CFK considerations**:
- CFK attempts to detect the CP version from the image and auto-enables auto-join on CP 8.2+.
- Version detection can fail with custom images (e.g. ones with added diagnostic tools).
- CFK doesn't currently expose an explicit toggle; a future enhancement may add `autoJoin: true/false` to the CRD spec.

See [Troubleshooting](#45-troubleshooting-tips) item 9 for the `remove-controller` + auto-join interaction.

### 4.4 Greenfield Quick Reference

For new clusters deployed directly with dynamic quorum (not migrated from static quorum or ZooKeeper). The bootstrap mechanics, ConfigMap, and RBAC are covered in 4.1-4.3; the dynamic-quorum-specific CR fields are:

```yaml
spec:
  dynamicQuorumConfig:
    enabled: true          # Generates controller.quorum.bootstrap.servers (not voters)
    bootstrapPod: 0        # Pod ordinal that does the standalone format
```

Single-cluster vs MRC differences:

| | Single-Cluster | MRC |
|---|---|---|
| **Advertised listeners** | Not needed (internal K8s DNS works) | Required — cross-cluster pods cannot resolve internal DNS |
| **ConfigMap + RBAC** | One set in the namespace | One set in the bootstrap region only |
| **Cluster ID** | Auto-generated by bootstrap pod | Must be passed to non-bootstrap regions via `spec.clusterID` |
| **Observer promotion** | Promote non-bootstrap pods | Promote non-bootstrap pods in bootstrap region + all pods in other regions |
| **External access** | Not needed | LoadBalancer on controller listener for cross-cluster communication |

MRC additionally hits the [MRC advertised-listeners bug](#mrc-version-compatibility) — see that section for supported CP versions. Full worked example: [`greenfield/mrc/2dc-greenfield-loadbalancer/`](greenfield/mrc/2dc-greenfield-loadbalancer/).

### 4.5 Troubleshooting Tips

**Check Bootstrap Status**:
```bash
kubectl get cm kraftcontroller-dynamic-quorum -n central -o yaml
```

**Check Main Container Logs** (bootstrap tool runs in the main container's configure script, not the init container):
```bash
kubectl logs kraftcontroller-0 -n central
```

**Common Issues**:

1. **Kafka CLI tool OutOfMemoryError (Java heap space)**:
   If any `kafka-*` CLI tool (e.g. `kafka-metadata-quorum`, `kafka-features`) crashes with:
   ```
   ERROR Uncaught exception in thread 'kafka-admin-client-thread | adminclient-1'
   java.lang.OutOfMemoryError: Java heap space
   ```
   **The most common cause is missing security configuration**, not insufficient heap. When the CLI cannot authenticate with the KRaft controller (e.g., missing `--command-config` with SSL/SASL properties), it retries internally and leaks memory until it hits the default 256MB ceiling. Increasing heap with `KAFKA_HEAP_OPTS="-Xmx512m"` only delays the crash — the real fix is providing the correct `--command-config` properties file. On CFK 3.3+ that's the mounted `/opt/confluentinc/etc/kafka/kafka-client.properties`; on older versions see [Running Admin CLI Tools on Secured KRaft](admin-cli-on-secured-kraft.md).

   If you are certain the security config is correct and the OOM is genuine (e.g., large metadata on a plaintext cluster), then increase heap:
   ```bash
   KAFKA_HEAP_OPTS="-Xmx512m" kafka-metadata-quorum ...
   ```

2. **`add-controller` / admin CLI properties file** <a name="add-controller-properties-file"></a>:

   `kafka.properties` cannot be used directly as `--command-config` for `kafka-metadata-quorum` or `kafka-features` on secured clusters. It only contains **listener-level** security properties (e.g., `listener.name.controller.ssl.truststore.location`, `listener.name.controller.plain.sasl.jaas.config`), which the admin client ignores. Admin CLI tools are Kafka clients — they need **global-level** properties (`ssl.truststore.location`, `sasl.jaas.config`, `security.protocol`, etc.). With listener-prefixed-only config the client has effectively no security config and fails with a `TimeoutException` or `OutOfMemoryError` (the underlying Kafka error is unhelpfully generic, which is why this gotcha exists).

   **On CFK 3.3+ you don't build this file yourself.** The operator generates and mounts `/opt/confluentinc/etc/kafka/kafka-client.properties` on every KRaft pod — it's `kafka.properties` plus the global `security.protocol` / `sasl.*` / `ssl.*` overlay and a fallback `advertised.listeners`, so it works as `--command-config` as-is (including for `add-controller`, which also needs `node.id`, `process.roles`, `log.dirs`, `advertised.listeners`):
   ```bash
   kafka-metadata-quorum --command-config /opt/confluentinc/etc/kafka/kafka-client.properties \
     --bootstrap-controller localhost:9074 describe --replication
   ```
   Only on older CFK versions that don't mount this file do you build one by hand — see [Running Admin CLI Tools on Secured KRaft](admin-cli-on-secured-kraft.md) (kept as a fallback).

3. **`advertised.listeners` missing/empty in the `--command-config` file** (two symptoms, same root cause):

   When you run `add-controller`, the leader reads the new voter's endpoint from the `advertised.listeners` in the properties file you pass via `--command-config`. If that file has no `advertised.listeners`, or has the empty-host form `CONTROLLER://:9074`, it misbehaves:

   - **`No subject alternative DNS name matching localhost found`** — the empty host resolves to `localhost`, so the leader tries to connect back to its **own** localhost (not the new voter's pod); the leader's cert has a different FQDN as SAN, so the SSL handshake fails.
   - **`Voter key for VOTE or BEGIN_QUORUM_EPOCH request didn't match the receiver's replica key` spam** — a bug in the `kafka-metadata-quorum` CLI (not the controller): with no `advertised.listeners` in the command-config, the leader spams this. If you already hit it and the quorum is otherwise formed, **kill the leader pod once** — the stale CLI state doesn't survive a restart.

   Fix: set `advertised.listeners=CONTROLLER://<real-fqdn>:9074` in the **client properties file** passed via `--command-config`. This is separate from `advertisedListenersEnabled` in the KRaftController CR spec — the CR spec controls the KRaft **server** properties and is only needed for MRC (cross-cluster DNS resolution, where the [MRC advertised-listeners bug](#mrc-version-compatibility) comes into play). On CFK 3.3+ the mounted `kafka-client.properties` already carries a usable `advertised.listeners`. **CP 8.2+ avoids both symptoms entirely** — with `controller.quorum.auto.join.enable=true`, observer-to-voter promotion happens automatically and never invokes the CLI.

4. **SSL endpoint identification and cert SANs**:

   CFK auto-generated certs include the pod FQDN (`<pod>.<statefulset>.<namespace>.svc.cluster.local`) as a SAN, not `localhost`. So:
   - `--bootstrap-controller localhost:9074` → cert SAN mismatch → SSL fails
   - `--bootstrap-controller <pod-fqdn>:9074` → matches SAN → works without disabling endpoint identification

   Do not disable `ssl.endpoint.identification.algorithm` — use the FQDN in `--bootstrap-controller` instead.

5. **Init container stuck**: Check RBAC permissions. The init container (bootstrap pod only) must be able to update the dynamic-quorum bootstrap ConfigMap. Replace `<namespace>` and `<service-account-name>` with your KRaftController namespace and `spec.podTemplate.serviceAccountName` (e.g. `central` and `kraftcontroller-sa` in the playbooks).
   ```bash
   kubectl auth can-i update configmaps --as=system:serviceaccount:<namespace>:<service-account-name> -n <namespace>
   ```
   Example (playbook default):
   ```bash
   kubectl auth can-i update configmaps --as=system:serviceaccount:central:kraftcontroller-sa -n central
   ```

6. **Cluster ID mismatch**: In MRC you must pass the cluster ID in the specs. If you don't, the second region generates its own cluster ID and acts as a separate cluster instead of a second region of the MRC cluster. Check in the KRaftController CR status or in the `meta.properties` file.
  ```bash
   # Verify cluster IDs match across all controllers
   for i in 0 1 2; do
     echo "kraftcontroller-$i:"
     kubectl exec kraftcontroller-$i -n central -- \
       cat /var/lib/kafka/data/meta.properties | grep cluster.id
   done
   ```

7. **Bootstrap ConfigMap has `bootstrap_formatted: true` too early → setup stuck with zero voters**: If the `kraftcontroller-dynamic-quorum` ConfigMap reads `true` before the bootstrap pod has actually formatted (e.g. it was hand-edited, or carried over from a previous cluster), the bootstrap pod formats with `--no-initial-controllers` (rejoin mode) instead of `--standalone` (bootstrap mode) → no initial voter is created → setup hangs. Recovery: delete the bootstrap pod's PVC (it goes `Pending`), then delete the bootstrap pod. On restart the PVC is recreated, the volume formats with `--standalone`, and the pod becomes the leader as intended.

8. **`advertisedListeners` changes don't auto-roll the controllers**: CFK deliberately does **not** roll pods when the `init-config` ConfigMap changes — init-config holds per-pod metadata (`node.id`, `log.dirs`, `process.roles`) not expected to change at runtime, so the operator only rolls on `shared-config` changes (TLS, SASL, quorum config, JVM, etc.). `advertised.listeners` is the exception: it lives in init-config (it's pod-specific) but **does** need a restart to take effect in `kafka.properties`. So after adding/changing external access / `advertisedListeners` on a running cluster, the operator updates `init-config` but the pods do **not** restart on their own. Trigger an operator-managed rolling restart by bumping a pod-template annotation (do **not** patch the StatefulSet directly — the operator overwrites it):
   ```bash
   kubectl patch kraftcontroller kraftcontroller -n <namespace> --type=merge \
     -p '{"spec":{"podTemplate":{"annotations":{"kafkacluster-manual-roll":"2"}}}}'
   ```
   Increment the value (`"2"` → `"3"`) each time you need another roll.

9. **`remove-controller` has no lasting effect with auto-join (CP 8.2+)**: with `controller.quorum.auto.join.enable=true` (default on CP 8.2+), running `remove-controller` on a controller whose pod is still running does nothing permanent — the controller re-joins as an observer and promotes itself back to voter. `remove-controller` only sticks if the target pod is **stopped** (scaled down, deleted, or crashed) or auto-join is disabled. To test it manually, stop the removed controller's pod immediately after removal. This is the desired production behavior — auto-join provides automatic recovery from transient controller failures.

10. **MRC greenfield startup hangs with `channel manager timed out before sending the request` (advertised-listeners bug)**:
    ```
    [ControllerRegistrationManager id=100] RegistrationResponseHandler: channel manager timed out before sending the request
    ```
    If you see this while bringing up a **dynamic-quorum MRC** cluster (advertised listeners present from initial creation), **you're on a CP version with the advertised-listeners bug**. **Root cause**: the initial `ControllerRegistration` RPC times out; `failedRPC` increments but `pendingRPC` is never reset, so every later attempt skips sending and the bootstrap voter never registers — the cluster is stuck. It triggers on any external-access type (`loadBalancer` or `staticForHostBasedRouting`): even with DNS pre-resolved, LB forwarding rules take seconds to provision, so the first RPC times out. **Fix**: use a CP version with the fix — **7.9.6+, 8.0.5+, 8.1.2+, 8.2.1+, or 8.3.0+** (affected: 7.9.5, 8.0.0-8.0.4, 8.1.1, 8.2.0). Background: [MRC Version Compatibility](#mrc-version-compatibility).

11. **ZK→KRaft migration: do I need to set `kraft-migration-ibp-version`?** On **CFK 3.3.0+**: not for standard CP images — CFK auto-infers the IBP (`inter.broker.protocol.version`) from the Kafka image tag (CP 7.0-7.9 → IBP 3.0-3.9). The `platform.confluent.io/kraft-migration-ibp-version` annotation is then only needed for **custom images** or CP versions CFK doesn't have a mapping for (it errors and asks you to set it); if you set it on a standard image, CFK ignores it (and warns if it disagrees with the derived value). **On CFK earlier than 3.3.0 the annotation is mandatory** — auto-inference isn't available, so set `platform.confluent.io/kraft-migration-ibp-version` yourself (e.g. `"3.9"` for the dynamic-quorum migration).

12. **Pod stuck `Pending` / `FailedAttachVolume … NotFound … Error 404 … disks/pvc-…` — the underlying cloud disk was deleted**: `reclaimPolicy: Retain` protects the PVC, not against a direct cloud-API disk deletion (e.g. a stray `delete_unattached_disks` job). Confirm with `gcloud compute disks list --filter="name=<pv-name>"` (empty = gone). Recovery — replace each lost PV with a fresh disk so pods can schedule, then the normal Observer→Voter promotion applies. You do **not** hand-craft PVs; you delete the orphan PVC/PV and let CFK recreate real ones (your storage class, not the `dummy` volumeClaimTemplate placeholder):
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
    (Validated 2026-05-07: PVCs deleted, fresh PVs auto-provisioned, pods came up empty, fetched from the leader, promoted via `add-controller` — no manual disk creation.)


---

## 5. Migration

Two paths into dynamic quorum, each with a full worked example under [`migration/`](migration/) — the example READMEs have the runnable, secured, step-by-step procedures. These notes just call out the gotchas that are easy to get wrong.

### 5.1 ZK→KRaft Migration

Full examples: [`migration/zk-to-kraft/quickstart/`](migration/zk-to-kraft/quickstart/) and [`migration/zk-to-kraft/secured/`](migration/zk-to-kraft/secured/).

- **CP version**: use **CP 7.9.6+**. CP 7.9.0 has a bug that formats KRaft at `kraft.version=0` (static); observer promotion then crashes the observer and the leader, and converting 0→1 afterward is unreliable. (ZK ships only in 7.9.x — it's removed in CP 8.0.)
- **IBP**: on **CFK 3.3.0+** no longer set by hand — CFK auto-infers `inter.broker.protocol.version` from the image, and the `kraft-migration-ibp-version` annotation is only for custom images. On CFK earlier than 3.3.0 you must set the annotation manually (see [Troubleshooting](#45-troubleshooting-tips) item 11).
- **Promote observers during the `DUAL_WRITE` phase** (`SETUP → MIGRATE → DUAL_WRITE → MoveToKRaftControllerOnly → FINALIZED`), before finalization — `kraft.version=1` is active then; promoting after finalization is too late.
- **`add-controller` connects to an existing voter**, run from the observer pod (not to another observer). On secured clusters use the mounted client config, not `kafka.properties` ([Troubleshooting](#45-troubleshooting-tips) item 2).

### 5.2 Static → Dynamic KRaft Migration (kraft.version 0 → 1)

Full examples: [`migration/static-to-dynamic/quickstart/`](migration/static-to-dynamic/quickstart/) (single-cluster) and [`migration/static-to-dynamic/mrc/`](migration/static-to-dynamic/mrc/) (MRC) — both walk the four phases with a per-phase property table. The flow:

```
(MRC only) add advertisedListeners → upgrade kraft.version 0→1 → switch KRaft to dynamicQuorumConfig → roll Kafka
```

Requires **CP 8.0+** (the 0→1 upgrade isn't supported on 7.9.x) and **CFK 3.2+**. No bootstrapPod / ConfigMap / RBAC — the cluster is already formatted. Two things that bite people:

- **The `kraft.version` upgrade is a CLI step** (`kafka-features ... upgrade --feature kraft.version=1`). Just swapping `controller.quorum.voters` → `controller.quorum.bootstrap.servers` in YAML does **not** migrate — `kraft.version` stays 0.
- **Don't enable `dynamicQuorumConfig` before the kraft.version upgrade.** At v0, if Kafka reconciles with only `bootstrap.servers` (no voters) it crashloops (`UnattachedState, voters=[]`). Follow the phase order.

---

## 6. Disaster Recovery

For detailed disaster recovery procedures when more than half of KRaft controllers are down (quorum loss), including the `kafka-metadata-recovery` tool and the Pod Overlay approach, see [disaster-recovery/](./disaster-recovery/) — split into data-safe 2DC ([quorum-loss-recovery/](./disaster-recovery/quorum-loss-recovery/)) and lossy 2.5DC ([lossy-quorum-loss-recovery/](./disaster-recovery/lossy-quorum-loss-recovery/)).

---

## 7. Summary

### Key Takeaways

1. **Dynamic KRaft (KIP-853)** enables controller membership changes without cluster recreation
2. **Static vs Dynamic**: `controller.quorum.voters` → `controller.quorum.bootstrap.servers`
3. **Observer-to-Voter Promotion**: New controllers join as observers, must be manually promoted
4. **Bootstrap setup** (greenfield / ZK→KRaft): provide a bootstrap ConfigMap + ServiceAccount/Role/RoleBinding + `dynamicQuorumConfig.bootstrapPod` on the CR
5. **RBAC**: the bootstrap ServiceAccount needs `get`/`update` on that ConfigMap
6. **One bootstrap controller**: exactly one controller formats as the bootstrap; the rest join and are promoted (and it won't re-format on restart)
7. **advertisedListeners changes require a manual roll** — patch `spec.podTemplate.annotations` on the CR (see [Troubleshooting](#45-troubleshooting-tips) item 8)

---

## 8. References

- **KIP-853**: Dynamic Controller Quorum (https://cwiki.apache.org/confluence/display/KAFKA/KIP-853)
- **CFK documentation**: [Confluent for Kubernetes docs](https://docs.confluent.io/operator/current/overview.html)
- **Greenfield examples**: [`greenfield/`](greenfield/)
- **MRC setup**: [`greenfield/mrc/2dc-greenfield-loadbalancer/`](greenfield/mrc/2dc-greenfield-loadbalancer/)
- **Migration examples**: [`migration/`](migration/)
- **DR scenarios**: [`disaster-recovery/`](disaster-recovery/)
