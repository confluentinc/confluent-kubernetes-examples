# Dynamic KRaft Quorum (KIP-853) in Confluent for Kubernetes

This document provides a comprehensive overview of the Dynamic KRaft feature ([KIP-853](https://cwiki.apache.org/confluence/display/KAFKA/KIP-853)) and its usage with Confluent for Kubernetes (CFK).

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
| **KRaft (Static Quorum)** | CP 7.4+ | All active CFK versions | Supported (continues in all future versions) |
| **KRaft (Dynamic Quorum)** | CP 7.9+ | CFK 3.2+ | Using latest CP patch recommended |
| **KRaft (Dynamic Quorum) MRC** | CP 7.9.6+ (in 7.9.x), 8.1.2+ (in 8.1.x) | CFK 3.2+ | 8.0.x and 8.2.x have known issues for MRC. See [KMETA-2851](#kmeta-2851-mrc-version-compatibility). Expected Fix Version - 8.0.5, 8.2.1 (Q2 2026 Patch Release) |
| **Auto-Join Dynamic Quorum** | CP 8.2+ | CFK 3.2+ | Simplifies observer promotion (no manual `add-controller`) |
| **ZK to KRaft (Dynamic Quorum) Migration** | CP 7.9.6+ | CFK 3.2+ | Use CP 7.9 only -- ZK is removed in CP 8.0+ |
| **Static to Dynamic KRaft Migration** | CP 8.0+ | CFK 3.2+ | Works on all 8.0+ versions for both single region and MRC -- not affected by KMETA-2851 |

Users must upgrade to **CFK 3.2+** to use dynamic quorum features. See [CFK upgrade documentation](https://docs.confluent.io/operator/current/co-upgrade.html).

**Key Notes**:
- **CP 7.9.6+ or 8.1.2+** recommended for dynamic quorum. For single-cluster (non-MRC) deployments, CP 8.0.4+ and 8.2.0+ also work fine -- the version restrictions above are specific to MRC greenfield.
- **CP 8.2+** has support for auto-join (reduces manual promotion steps).
- All active CFK versions support KRaft static quorum deployment.
- **CFK 3.2+** adds dynamic quorum support and KRaft Migration Job (KMJ).
- ZK to KRaft migration with dynamic quorum is only on CP 7.9.6+ (ZK removed in 8.0).
- **Scale-up/scale-down of KRaft controllers is not yet supported via CFK.** Controller membership changes (add/remove) must be done manually using `kafka-metadata-quorum` CLI. Automated scale operations can be added in a future CFK release.

### KMETA-2851: MRC Version Compatibility

MRC deployments require `advertisedListenersEnabled: true` on KRaft for cross-cluster communication. This interacts with KMETA-2851 differently depending on the deployment path:

| Deployment Path | Affected by KMETA-2851? | CP Versions That Work |
|----------------|------------------------|----------------------|
| **MRC Greenfield** (advertised listeners from start) | Yes | CP 7.9.6, 8.1.2 |
| **MRC ZK to KRaft (Dynamic Quorum) Migration** (advertised listeners from start) | Yes | CP 7.9.6 |
| **MRC Static to Dynamic Migration** (advertised listeners added after quorum formed) | No | All CP 8.0+ |
| **Single-cluster** (no advertised listeners) | No | All CP versions |

The static to dynamic migration path avoids KMETA-2851 because advertised listeners are enabled in Step 1 of the migration, after the quorum is already formed and controllers are already registered. The bug only triggers when advertised listeners are present at initial pod startup.

---

## Examples

| Category | Example | Path | Security | MRC |
|----------|---------|------|----------|-----|
| **Greenfield** | Quickstart (includes auto-join) | [greenfield/single-cluster/quickstart/](greenfield/single-cluster/quickstart/) | None | No |
| | Secured (LDAP RBAC) | [greenfield/single-cluster/secured/](greenfield/single-cluster/secured/) | TLS + SASL/PLAIN + LDAP RBAC | No |
| | MRC -- LoadBalancer (Secured) | [greenfield/mrc/2dc-greenfield-loadbalancer/](greenfield/mrc/2dc-greenfield-loadbalancer/) | TLS + SASL/PLAIN + OAuth + RBAC | Yes (LB) |
| **Static to Dynamic Migration** | Single Cluster | [migration/static-to-dynamic/single-cluster/](migration/static-to-dynamic/single-cluster/) | None | No |
| | MRC (Secured) | [migration/static-to-dynamic/mrc/](migration/static-to-dynamic/mrc/) | TLS + SASL/PLAIN + OAuth + RBAC | Yes (LB) |
| **ZK to KRaft Migration** | Single Cluster | [migration/zk-to-kraft/single-cluster/](migration/zk-to-kraft/single-cluster/) | None | No |
| | MRC (Secured) | [migration/zk-to-kraft/mrc/](migration/zk-to-kraft/mrc/) | TLS + SASL/PLAIN + OAuth + RBAC | Yes (LB) |

**Notes:**
- Static to Dynamic migration: No bootstrapPod, ConfigMap, or RBAC needed -- the cluster is already formatted.
- ZK to KRaft migration: Requires bootstrapPod, ConfigMap, RBAC for initial cluster formatting.
- MRC examples require advertised listeners for cross-cluster communication (see [Section 5.3](#53-advertised-listeners-and-mrc)).
- For ZK-to-KRaft migration with **static quorum** (kraft.version=0), see the [KRaftMigrationJob examples](../../migration/KRaftMigration/).

---

## 1. Why is Dynamic KRaft Needed?

### The Problem with Static KRaft

In the original KRaft implementation (CP 7.4 onwards), the controller quorum was **static**:

- Controller membership was fixed at cluster creation time
- Defined in `controller.quorum.voters` property (e.g., `1@host1:9093,2@host2:9093,3@host3:9093`)
- **Cannot add or remove controllers** without recreating the entire cluster
- **Cannot recover from controller failure** without manual intervention
- **Cannot scale the quorum** to handle increased metadata load

### Real-World Impact

**Problem Scenarios**:

1. **Hardware Failure**: A controller node dies -- quorum permanently reduced -- risk of quorum loss
2. **Regional Disaster**: In Multi-Region Clusters (MRC), losing a region could mean permanent loss of controllers
3. **Scaling Needs**: Cannot add controllers when metadata load increases
4. **Maintenance**: Cannot safely decommission controllers for hardware upgrades

**Example**:
- 6 controllers in MRC (3 in central, 3 in east), quorum needs 4
- East region has a disk failure -- 2 controllers go down
- Now only 4 controllers remain (3 central + 1 east) -- quorum maintained but fragile
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
> [migration guide](migration/static-to-dynamic/mrc/) for the correct procedure.

> **NOTE**: kraft.version 0 to 1 upgrade is NOT supported on CP 7.9.x. Use CP 8.0+ for
> static to dynamic quorum migration.

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
controller.quorum.bootstrap.servers=kraft-central0.my-domain.example.com:9074,kraft-central1.my-domain.example.com:9074,kraft-central2.my-domain.example.com:9074,kraft-east0.my-domain.example.com:9074,kraft-east1.my-domain.example.com:9074
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

**Key Difference**: Only the **bootstrap controller** is a voter initially and thus also becomes the leader. All other controllers join as observers and eventually get promoted to voters. In static quorum, all are voters from the start and any can become leader initially.

#### Advertised Listeners

**Static KRaft**: The `advertised.listeners` property was not required. Static quorum uses `controller.quorum.voters=100@kraft-central0.example.com:9093,101@kraft-central1.example.com:9093,...` which already contains all endpoints.

**Dynamic KRaft**:
In MRC clusters, `advertised.listeners` must be defined. (If the cluster is limited to a single region, it is not needed since KRaft/Kafka can resolve each other's internal K8s DNS.)
See [Section 5.3](#53-advertised-listeners-and-mrc) for the KMETA-2851 bug that affects MRC deployments with advertised listeners.
```
advertised.listeners=CONTROLLER://kraft-central0.my-domain.example.com:9074 #pod1
advertised.listeners=CONTROLLER://kraft-central1.my-domain.example.com:9074 #pod2
advertised.listeners=CONTROLLER://kraft-central2.my-domain.example.com:9074 #pod3
advertised.listeners=CONTROLLER://kraft-east0.my-domain.example.com:9074 #pod4
advertised.listeners=CONTROLLER://kraft-east1.my-domain.example.com:9074 #pod5
advertised.listeners=CONTROLLER://kraft-east2.my-domain.example.com:9074 #pod6
```

This is because dynamic quorum does not use `controller.quorum.bootstrap.servers` to derive advertised listeners. The `controller.quorum.bootstrap.servers` property is only used for initial discovery, not for advertising the controller's reachable endpoint.

---

## 3. Checking Quorum Mode

### Check Configuration

```bash
$ kafka-features --bootstrap-controller localhost:9074 describe
Feature: confluent.metadata.version  SupportedMinVersion: CP-7.3-IV3  SupportedMaxVersion: CP-8.1-IV1A  FinalizedVersionLevel: CP-8.1-IV1A  Epoch: 11368
Feature: eligible.leader.replicas.version  SupportedMinVersion: 0  SupportedMaxVersion: 1  FinalizedVersionLevel: 0  Epoch: 11368
Feature: group.version  SupportedMinVersion: 0  SupportedMaxVersion: 1  FinalizedVersionLevel: 0  Epoch: 11368
Feature: kraft.version  SupportedMinVersion: 0  SupportedMaxVersion: 1  FinalizedVersionLevel: 0  Epoch: 11368
Feature: metadata.version  SupportedMinVersion: 3.3-IV3  SupportedMaxVersion: 4.1-IV1  FinalizedVersionLevel: UNKNOWN 0  Epoch: 11368
Feature: share.version  SupportedMinVersion: 0  SupportedMaxVersion: 1  FinalizedVersionLevel: 0  Epoch: 11368
Feature: streams.version  SupportedMinVersion: 0  SupportedMaxVersion: 1  FinalizedVersionLevel: 0  Epoch: 11368
Feature: transaction.version  SupportedMinVersion: 0  SupportedMaxVersion: 2  FinalizedVersionLevel: 0  Epoch: 11368
```

`kraft.version.FinalizedVersionLevel` determines whether you are using static quorum (version 0) or dynamic quorum (version 1).

**Important**: There is also a `kraft.version` field in the `meta.properties` file. If this is set to 1, it merely states that using KRaft with dynamic quorum (KIP-853) is *possible*, not that it is currently *in use*. The `FinalizedVersionLevel` from `kafka-features describe` is the authoritative source.

**Directory ID changes on kraft.version upgrade**: When upgrading from `kraft.version=0` (static) to `kraft.version=1` (dynamic), each controller's `DirectoryId` automatically changes from the placeholder value `AAAAAAAAAAAAAAAAAAAAAA` to a unique UUID. This is expected behavior -- static quorum does not use directory IDs, so they are all set to the same placeholder. The upgrade to dynamic quorum assigns real directory IDs to each controller. These new directory IDs are what you use in `remove-controller --controller-directory-id` commands.

**`remove-controller` fails with "Remove voter request didn't include a valid voter"**: This error means you are on `kraft.version=0` (static quorum). At kraft.version=0, all directory IDs are the placeholder `AAAAAAAAAAAAAAAAAAAAAA`, which is not a valid voter identity. Dynamic quorum operations (`remove-controller`, `add-controller`) only work after upgrading to `kraft.version=1`. Example error:
```
org.apache.kafka.common.errors.InvalidRequestException: Remove voter request didn't include a valid voter
```
This is expected and confirms the cluster is still on static quorum. Proceed with the migration to kraft.version=1.

**`UnknownHostException` for cross-cluster controller FQDNs (MRC)**: When running admin commands (e.g., `kafka-metadata-quorum describe --status`) on a static quorum MRC cluster **without** `advertisedListenersEnabled`, the admin client uses internal K8s pod FQDNs (e.g., `kraftcontroller-2.kraftcontroller.central.svc.cluster.local`). Controllers in other K8s clusters cannot resolve these internal DNS names. This is expected -- admin commands only work from the cluster where the leader is. After enabling `advertisedListenersEnabled` (migration step 1), the admin client uses the external LoadBalancer DNS names which resolve from any cluster.

### Check Quorum Status

```bash
# View current quorum members
kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --status

# Dynamic quorum will show:
# - CurrentVoters: Active voting members
# - CurrentObservers: Non-voting members (either controllers waiting to be promoted,
#   or brokers which are always observers and will not be promoted to voters)
```

### Check Replication Status

```bash
# View detailed replication info
kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --replication

# Output shows:
# NodeId  DirectoryId  ReplicaState  LogEndOffset  Lag  LastCaughtUpMs
# 100     <uuid>       Leader        1234567       0    <timestamp>
# 101     <uuid>       Follower      1234567       0    <timestamp>
# 102     <uuid>       Observer      1234560       7    <timestamp>  # Not yet promoted
```

**Note**: If TLS or SASL is configured on KRaft listeners, these commands require a `--command-config` file with the appropriate security properties. See [Running Admin CLI Tools on Secured KRaft](#running-admin-cli-tools-on-secured-kraft) for the full guide.

### Dynamic Operations

#### Add Controller to Quorum

```bash
# Promote an observer to voter (run FROM the observer pod, connect TO an existing voter)
kubectl exec kraftcontroller-2 -n central -- \
  kafka-metadata-quorum \
  --bootstrap-controller kraftcontroller-0.kraftcontroller.central.svc.cluster.local:9074 \
  --command-config /mnt/admin-config/admin.properties \
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

## 4. Troubleshooting Tips

**Check Bootstrap Status**:
```bash
kubectl get cm kraftcontroller-dynamic-quorum -n <namespace> -o yaml
```

**Check Main Container Logs** (bootstrap tool runs in the main container's configure script, not the init container):
```bash
kubectl logs kraftcontroller-0 -n <namespace>
```

**Common Issues**:

1. **Kafka CLI tool OutOfMemoryError (Java heap space)**:
   If any `kafka-*` CLI tool (e.g. `kafka-metadata-quorum`, `kafka-features`) crashes with:
   ```
   ERROR Uncaught exception in thread 'kafka-admin-client-thread | adminclient-1'
   java.lang.OutOfMemoryError: Java heap space
   ```
   **The most common cause is missing security configuration**, not insufficient heap. When the CLI cannot authenticate with the KRaft controller (e.g., missing `--command-config` with SSL/SASL properties), it retries internally and leaks memory until it hits the default 256MB ceiling. Increasing heap with `KAFKA_HEAP_OPTS="-Xmx512m"` only delays the crash — the real fix is providing the correct `--command-config` properties file. See [Running Admin CLI Tools on Secured KRaft](#running-admin-cli-tools-on-secured-kraft) for how to build this file.

   If you are certain the security config is correct and the OOM is genuine (e.g., large metadata on a plaintext cluster), then increase heap:
   ```bash
   KAFKA_HEAP_OPTS="-Xmx512m" kafka-metadata-quorum ...
   ```

2. **`add-controller` / admin CLI properties file**: <a name="add-controller-properties-file"></a>

   `kafka.properties` cannot be used directly as `--command-config` for `kafka-metadata-quorum` or `kafka-features` on secured clusters. The reason is that `kafka.properties` only contains **listener-level** security properties (e.g., `listener.name.controller.ssl.truststore.location`, `listener.name.controller.plain.sasl.jaas.config`). Admin CLI tools are Kafka clients — they need **global-level** properties (`ssl.truststore.location`, `sasl.jaas.config`, `security.protocol`, etc.). Listener-prefixed properties are ignored by the admin client, so it effectively has no security config and fails with a `TimeoutException` or `OutOfMemoryError`.

   You need a separate admin properties file with global client security configs. If using `add-controller`, the file also needs `node.id`, `process.roles`, `log.dirs`, and `advertised.listeners` — copy these from `kafka.properties` as a base.

   See [Running Admin CLI Tools on Secured KRaft](#running-admin-cli-tools-on-secured-kraft) for the full guide on building and mounting this file.

3. **`advertised.listeners` -- empty host resolves to localhost**:

   `listeners=CONTROLLER://:9074` binds to all interfaces but has no hostname. When passed to `add-controller`, the leader reads this as the new voter's endpoint and tries to connect back to verify reachability. The empty host resolves to `localhost` -- meaning the leader connects to its **own** localhost, not the new voter's pod. The leader's own cert has a different FQDN as SAN, so the SSL handshake fails with `No subject alternative DNS name matching localhost found`.

   Fix: always set `advertised.listeners=CONTROLLER://<real-fqdn>:9074` in the **client properties file** passed via `--command-config` to tools like `kafka-metadata-quorum` or `kafka-features`. This is separate from setting `advertisedListenersEnabled` in the KRaftController CR spec — the CR spec controls the KRaft **server** properties and is only needed for MRC (where cross-cluster DNS resolution is required, and where [KMETA-2851](#kmeta-2851-mrc-version-compatibility) comes into play). The `--command-config` file is what the CLI tool uses as a client to talk to the controller.

4. **SSL endpoint identification and cert SANs**:

   CFK auto-generated certs include the pod FQDN (`<pod>.<statefulset>.<namespace>.svc.cluster.local`) as a SAN, not `localhost`. So:
   - `--bootstrap-controller localhost:9074` -- cert SAN mismatch -- SSL fails
   - `--bootstrap-controller <pod-fqdn>:9074` -- matches SAN -- works without disabling endpoint identification

   Do not disable `ssl.endpoint.identification.algorithm` -- use the FQDN in `--bootstrap-controller` instead.

5. **Init container stuck**: Check RBAC permissions. The bootstrap pod must be able to update the dynamic-quorum bootstrap ConfigMap. Replace `<namespace>` and `<service-account-name>` with your KRaftController namespace and `spec.podTemplate.serviceAccountName`.
   ```bash
   kubectl auth can-i update configmaps --as=system:serviceaccount:<namespace>:<service-account-name> -n <namespace>
   ```
   Example:
   ```bash
   kubectl auth can-i update configmaps --as=system:serviceaccount:central:kraftcontroller-sa -n central
   ```

6. **Cluster ID mismatch**: In MRC you need to pass the cluster ID in specs. If you do not pass it, the second region creates its own cluster ID and acts as a separate cluster instead of a second region of your MRC cluster. You can check in the KRaftController CR status or in the meta.properties file.
   ```bash
   # Verify cluster IDs match across all controllers
   for i in 0 1 2; do
     echo "kraftcontroller-$i:"
     kubectl exec kraftcontroller-$i -n central -- \
       cat /var/lib/kafka/data/meta.properties | grep cluster.id
   done
   ```

---

## 5. Important Notes and Common Pitfalls

### 5.1 Auto-Join Feature (CP 8.2+)

**What Auto-Join Does**:
- **ONLY** eliminates the manual `kafka-metadata-quorum add-controller` command
- Observers automatically promote themselves to voters when caught up with the leader

**What Auto-Join Does NOT Do**:
- Does NOT eliminate the bootstrap ConfigMap
- Does NOT eliminate the bootstrap pod selection
- Does NOT change the `--standalone` vs `--no-initial-controllers` format logic
- Does NOT change RBAC requirements

**Key Property**:
```properties
controller.quorum.auto.join.enable=true  # CP 8.2+ only
```

**Notes**:
- If accidentally added on an older CP version, this property will simply be ignored.
- To disable this property, use config overrides. Although in usual scenarios it does not make much sense to disable it:
```yaml
spec:
  configOverrides:
    server:
      - controller.quorum.auto.join.enable=false
```

**Everything Else Stays the Same**:
- Bootstrap ConfigMap creation
- Bootstrap pod runs `--standalone`
- Other pods run `--no-initial-controllers`
- Other pods join as observers
- Bootstrap process unchanged
- Quorum formation unchanged

**`remove-controller` + Auto-Join Interaction**:

If auto-join is enabled (`controller.quorum.auto.join.enable=true`, default on CP 8.2+), running `remove-controller` on a controller that is still running will have no lasting effect -- the removed controller will automatically re-join the quorum as an observer and promote itself back to voter. This means:

- `remove-controller` only has a permanent effect if the target controller pod is **stopped** (scaled down, deleted, or crashed) or auto-join is **disabled**
- To test `remove-controller` manually with auto-join enabled, you must stop the removed controller's pod immediately after removal, or it will re-add itself
- This is actually the desired production behavior -- auto-join provides automatic recovery from transient controller failures

---

### 5.2 ConfigMap Bootstrap Coordination

**Correct ConfigMap Format** (CRITICAL):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kraftcontroller-dynamic-quorum
  namespace: confluent
data:
  bootstrap-status: '{"bootstrap_formatted": false}'
```

**What's Stored**:
- ONLY `true` or `false` for `bootstrap_formatted`
- NO timestamps, NO extra metadata
- Simple boolean to track if cluster has been bootstrapped
- Only needed on the cluster which has the bootstrap pod
- Needed for both greenfield setup and ZK-to-KRaft migration

**Why This Matters**: If `bootstrap_formatted: true` is set accidentally, kraftcontroller-0 will format with `--no-initial-controllers` (rejoin mode) instead of `--standalone` (bootstrap mode). This means zero voters are created and setup gets stuck.

To recover from this state: delete the PVC, then delete the bootstrap pod. It will restart, a new PVC will be created, and the pod will format the volume with the `--standalone` flag and become leader as expected.

---

### 5.3 Advertised Listeners and MRC

> **Any MRC setup with dynamic quorum requires advertised listeners.** Without them,
> cross-cluster communication fails. However, there is a known CP bug (KMETA-2851)
> that can affect greenfield MRC deployments when advertised listeners are defined from
> the start. Read this entire section before setting up MRC.

#### Static vs Dynamic Quorum Difference

In **static quorum** MRC, `advertised.listeners` on KRaft controllers was **not mandatory** -- controllers used `controller.quorum.voters` which already contained all endpoints. However, even in static quorum MRC, without `advertised.listeners` cross-cluster admin client commands (`kafka-metadata-quorum`, `kafka-features`) will fail when routed to a leader in a different cluster -- the leader returns its internal K8s DNS which is not resolvable from other clusters.

In **dynamic quorum** MRC, `advertised.listeners` **is mandatory in the KRaft server properties**. Without it, when an observer runs `add-controller` to join the quorum, the leader responds with its internal DNS (e.g. `kraftcontroller-0.kraftcontroller.central.svc.cluster.local:9074`). Pods in other regions/clusters cannot resolve this internal DNS, so observer-to-voter promotion fails.

Note: `advertised.listeners` in the **client properties file** passed to `kafka-metadata-quorum --command-config` works fine and is unaffected by this issue. The problem is only when `advertised.listeners` is present in the KRaft **server** properties (i.e. `kafka.properties` that the controller process boots with).

#### CP Bug Blocking MRC (KMETA-2851)

Defining `advertised.listeners` in the KRaft server properties from the start triggers a confirmed CP bug:

```
[ControllerRegistrationManager id=100] RegistrationResponseHandler: channel manager timed out before sending the request
```

**Root cause**: When the initial `ControllerRegistration` RPC times out, `failedRPC` is incremented but `pendingRPC` is not reset to `false`. All subsequent registration attempts see `pendingRPC = true` and skip sending, so the controller never retries registration. The bootstrap voter cannot register itself and the cluster is stuck.

**Affected versions**: CP 7.9.5, 8.0.4, 8.1.1, 8.2.0 (and earlier patch releases).

**Fixed in**: CP 7.9.6, 8.1.2. NOT fixed in 8.0.x (incl 8.0.4) or 8.2.0. Expected fix in 8.0.5 and 8.2.1 (Q2 2026 patch release).

**Important**: This bug affects **ALL MRC greenfield** deployments where `advertised.listeners` is present from the start, regardless of external access type. Tested and confirmed on both `type: loadBalancer` and `type: staticForHostBasedRouting` with pre-created static IPs and DNS -- even with DNS resolving before pod startup, the LB forwarding rules take seconds to provision, causing the first registration RPC to time out.

**Static-to-dynamic migration** is NOT affected because advertised listeners are added after the quorum is already formed (Step 1 of migration) -- at that point the controller is already registered and the registration RPC does not need to happen again.

#### Current Status

| Deployment | Dynamic Quorum Support | Notes |
|------------|----------------------|-------|
| **Single-cluster** | All CP versions | No advertised listeners needed |
| **MRC greenfield** | CP 7.9.6+, 8.1.2+ | Needs KMETA-2851 fix (8.0.4 confirmed NOT fixed) |
| **MRC static-to-dynamic migration** | All CP versions | Advertised listeners added after quorum formed -- not affected by KMETA-2851 |

**Single-Region Deployment** (works today):
```yaml
spec:
  listeners:
    advertisedListenersEnabled: false  # Default -- no advertised.listeners generated
```

**MRC Deployment** (requires patched CP):

MRC with dynamic quorum requires:
1. `advertised.listeners` pointing to the external/public DNS on each controller
2. `controller.quorum.bootstrap.servers` with all public DNS endpoints
3. LoadBalancer external access on the controller listener

**CP versions which have this fix**: 7.9.6 and 8.1.2.
Note: 8.0.4 and 8.2.0 were shipped before this fix was merged.

---

### 5.4 Greenfield Dynamic Quorum Setup

For new clusters deployed directly with dynamic quorum (no migration from static quorum or ZooKeeper).

#### How Bootstrap Works

Dynamic quorum requires exactly **one bootstrap controller** that creates the initial quorum. All other controllers join as **observers** and must be promoted to **voters**.

1. **Bootstrap pod** (typically `kraftcontroller-0` in the bootstrap region): Formats storage with `kafka-storage format --standalone`, becoming the sole initial voter and leader.
2. **All other pods**: Format storage with `kafka-storage format --no-initial-controllers`, joining the existing quorum as observers.
3. **Observer promotion**: Each observer is promoted to voter using `kafka-metadata-quorum add-controller` (or automatically with auto-join on CP 8.2+).

#### Required Resources

**ConfigMap** (`kraftcontroller-dynamic-quorum`): Tracks whether the bootstrap pod has already formatted storage. Prevents split-brain on restarts — without it, if the bootstrap pod's PVC is lost, it would re-format with `--standalone` and create a second independent quorum.

```yaml
data:
  bootstrap-status: '{"bootstrap_formatted": false}'
```

Once the bootstrap pod formats, it updates this to `true`. All subsequent restarts see `true` and skip the standalone format.

**RBAC** (ServiceAccount + Role + RoleBinding): The bootstrap pod needs permission to read and update the ConfigMap. Observer pods do not access the ConfigMap at all.

**KRaftController CR fields**:
```yaml
spec:
  dynamicQuorumConfig:
    enabled: true          # Generates controller.quorum.bootstrap.servers (not voters)
    bootstrapPod: 0        # Pod ordinal that does the standalone format
```

#### Single-Cluster vs MRC

| | Single-Cluster | MRC |
|---|---|---|
| **Advertised listeners** | Not needed (internal K8s DNS works) | Required — cross-cluster pods cannot resolve internal DNS |
| **ConfigMap + RBAC** | One set in the namespace | One set in the bootstrap region only |
| **Cluster ID** | Auto-generated by bootstrap pod | Must be passed to non-bootstrap regions via `spec.clusterID` |
| **Observer promotion** | Promote non-bootstrap pods | Promote non-bootstrap pods in bootstrap region + all pods in other regions |
| **External access** | Not needed | LoadBalancer on controller listener for cross-cluster communication |

#### Examples

- [Single-cluster quickstart (no security)](greenfield/single-cluster/quickstart/)
- [Single-cluster secured (TLS + SASL/PLAIN + LDAP RBAC)](greenfield/single-cluster/secured/)
- [MRC with LoadBalancer (TLS + SASL/PLAIN + OAuth + RBAC)](greenfield/mrc/2dc-greenfield-loadbalancer/)

---

### 5.5 ZK to KRaft Migration Specifics

**CP Version Requirements**:
- **CP 7.9.6+** required for dynamic quorum during migration
- **CP 7.9.0** has a bug where it formats KRaft with kraft.version=0 (static quorum). If you then try to do observer promotion, it crashes the observer and leader. Even converting the quorum from version 0 to 1 still has issues. Not recommended to use older patches for migration.

**IBP Version Annotation** (CRITICAL):
Must set on the Kafka CR before starting migration:
```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  annotations:
    platform.confluent.io/kraft-migration-ibp-version: "3.9"  # MUST SET
spec:
  image:
    application: confluentinc/cp-server:7.9.6
```

**Why**: Default IBP 3.6 is incompatible with kraft.version=1 (dynamic quorum). Without this annotation:
- kraft.version cannot be finalized to 1
- Direct-to-controller APIs blocked
- Observer promotion fails

**Observer-to-Voter Promotion Timing** (promoting KRaft controllers from observer to voter):
- Promote DURING DUAL_WRITE phase (before finalization)
- Do NOT promote after finalization (too late)

**Migration Phases**:
```
SETUP -> MIGRATE -> DUAL_WRITE (promote observers to voters here!) -> MoveToKRaftControllerOnly -> FINALIZED
```

**Observer-to-Voter Promotion Best Practice**:
Always connect `--bootstrap-controller` to an **EXISTING VOTER**, not another observer. For simplicity, use the bootstrap pod to promote any observer to voter.

**Correct**:
```bash
# Run FROM observer pod, connect TO existing voter.
# NOTE: For secured clusters do NOT use kafka.properties as --command-config.
# See Section 4 Troubleshooting for the correct client properties file.
kubectl exec kraftcontroller-1 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller \
    kraftcontroller-0.kraftcontroller.confluent.svc.cluster.local:9074 \
    --command-config /mnt/admin-config/admin.properties \
    add-controller
```

**Verification Commands**:
```bash
# Check kraft.version is finalized to 1
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-features --bootstrap-controller localhost:9074 describe | grep kraft.version

# Check quorum status (expect 3 voters)
kubectl exec kraftcontroller-0 -n confluent -- \
  kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --status

# Check migration phase
kubectl get kraftmigrationjob kraftmigrationjob -n confluent \
  -o jsonpath='{.status.phase}{"\n"}{.status.subPhase}{"\n"}'
```

---

### 5.6 Static to Dynamic KRaft Migration (kraft.version 0 to 1)

For existing KRaft clusters running with static quorum that need to migrate to dynamic quorum.

#### What This Is NOT

This is NOT a greenfield deployment. The cluster is already running with KRaft static quorum.
Therefore:
- **No bootstrapPod** -- cluster is already running, no initial bootstrap needed
- **No ConfigMap** (`kraftcontroller-dynamic-quorum`) -- only needed for greenfield/ZK-to-KRaft
- **No RBAC** (ServiceAccount/Role/RoleBinding for ConfigMap) -- only needed for greenfield/ZK-to-KRaft

#### Requirements

- **CP 8.0+** (kraft.version 0 to 1 upgrade is NOT supported on CP 7.9.x)
- **CFK 3.2+** (for `dynamicQuorumConfig` and `advertisedListenersEnabled` support)
- Existing KRaft cluster at kraft.version=0 (verify with `kafka-features describe`)

#### Migration Steps

**Step 1 (MRC only): Add Advertised Listeners on KRaft**

Only needed for MRC setups where KRaft controllers communicate across Kubernetes clusters
via external DNS. For single-cluster setups where KRaft communication happens over internal
K8s DNS, skip to Step 2.

- Add `advertisedListenersEnabled: true` to KRaftController CR
- This change alone does NOT trigger an auto-roll -- add a pod template annotation
  (`kafkacluster-manual-roll`) to force the roll
- Apply to all clusters, wait for rolling restart to complete
- After this step, cross-cluster admin commands (`kafka-metadata-quorum`, `kafka-features`)
  work from both regions

**Step 2: Upgrade kraft.version**

Run from any controller pod:
```bash
kafka-features --bootstrap-controller localhost:9074 upgrade --feature kraft.version=1
```

Verify with:
```bash
kafka-features --bootstrap-controller localhost:9074 describe
# Should show: kraft.version FinalizedVersionLevel: 1
```

This is a metadata-level operation -- no YAML changes, no pod restarts.

**Step 3: Switch KRaft from Voters to Bootstrap Servers**

**Do this promptly after Step 2.** A v1 cluster with `controller.quorum.voters` on controllers
is a cautious state:
- Still safer than static quorum for DR
- But during disaster recovery, controllers should not have the voters property
- Minimize time in this state

Add `dynamicQuorumConfig.enabled: true` to KRaftController CR. CFK will generate
`controller.quorum.bootstrap.servers` and remove `controller.quorum.voters`.
Apply to all clusters, wait for rolling restart.

**Step 4: Roll Kafka to Pick Up Bootstrap Servers**

Kafka brokers still have the old `controller.quorum.voters` property. KRaft now has
`dynamicQuorumConfig.enabled`, so the next Kafka reconciliation will switch to
`controller.quorum.bootstrap.servers`.

Force the roll via pod template annotation (`kafkacluster-manual-roll`).
Apply to all clusters, wait for rolling restart.

#### Properties at Each Step

| Step | KRaft properties | Kafka properties | kraft.version |
|------|-----------------|-----------------|---------------|
| Start | voters | voters | 0 |
| After Step 1 (MRC only) | voters + advListeners | voters (unchanged) | 0 |
| After Step 2 | voters + advListeners | voters (unchanged) | 1 |
| After Step 3 | bootstrap.servers + advListeners | voters (unchanged) | 1 |
| After Step 4 | bootstrap.servers + advListeners | bootstrap.servers | 1 |

For single-cluster setups, skip Step 1 -- the table starts at Step 2 directly from the Start state.

#### What Changes After the Upgrade (Step 2)

After running `kafka-features upgrade --feature kraft.version=1`, two things change immediately:

1. **`kafka-features describe` output**: `kraft.version FinalizedVersionLevel` changes from `0` to `1`.
2. **`kafka-metadata-quorum describe --replication` output**: Each controller's `DirectoryId`
   changes from the placeholder `AAAAAAAAAAAAAAAAAAAAAA` (used by static quorum) to a unique
   UUID per controller. This is expected -- static quorum does not use directory IDs. The new
   UUIDs are what you use in `remove-controller --controller-directory-id` commands.

#### Things to Avoid

- **Do NOT just change `controller.quorum.voters` to `controller.quorum.bootstrap.servers`**
  and assume the migration is done. The kraft.version must be upgraded via the CLI tool.
- **Do NOT add `dynamicQuorumConfig.enabled` on KRaft before upgrading kraft.version (Step 2).**
  If KRaft has `dynamicQuorumConfig.enabled` at kraft.version=0 and Kafka reconciles,
  CFK gives Kafka only `bootstrap.servers` (drops voters). At v0, Kafka with only
  bootstrap.servers crashloops (`UnattachedState, voters=[]`). Follow the step order.
- **Do NOT skip Step 1 for MRC.** Without advertised listeners, cross-cluster admin commands
  fail because controllers advertise internal K8s DNS that remote clusters cannot resolve.
  Also see [KMETA-2851](#53-advertised-listeners-and-mrc) for a known bug when advertised
  listeners are defined from initial cluster creation (affects greenfield, not this migration path).

#### Examples

- [MRC migration example](migration/static-to-dynamic/mrc/) -- True multi-cluster (2 GKE clusters, 3+3 KRaft, 2+2 Kafka)
- [Single-cluster migration example](migration/static-to-dynamic/single-cluster/) -- Simple single-cluster setup

---

## Running Admin CLI Tools on Secured KRaft

When KRaft has TLS and/or authentication on the controller listener, admin tools (`kafka-metadata-quorum`, `kafka-features`) need a `--command-config` file. KRaft's `kafka.properties` only has **listener-level** configs (`listener.name.controller.sasl.*`) -- admin tools need **global** client configs.

Plaintext examples (no TLS, no auth) do not need a command config -- just use `--bootstrap-controller localhost:9074` directly.

### Building the admin properties file

Start with the KRaft server properties as a base. Copy `/opt/confluentinc/etc/kafka/kafka.properties` from any KRaft pod -- it has `node.id`, `process.roles`, `log.dirs`, `advertised.listeners` which `add-controller` needs. Then add the global security properties below.

Add only the layers your controller listener has. These are independent -- combine as needed.

**If TLS is enabled** (controller listener has `tls.enabled: true`):
```properties
ssl.truststore.location=<value>
ssl.truststore.password=<value>
ssl.truststore.type=<value>
```

**If mTLS** (controller listener has `authentication.type: mtls`) -- add keystore in addition to truststore:
```properties
ssl.truststore.location=<value>
ssl.truststore.password=<value>
ssl.truststore.type=<value>
ssl.keystore.location=<value>
ssl.keystore.password=<value>
ssl.keystore.type=<value>
```

The values for these are already in `kafka.properties` at the listener level -- look for `listener.name.controller.ssl.truststore.*` and `listener.name.controller.ssl.keystore.*`. Copy the same values but without the `listener.name.controller.` prefix.

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

### Mounting the file on the pod

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

### Running commands

```bash
kafka-metadata-quorum --bootstrap-controller localhost:9074 \
  --command-config /mnt/admin-config/admin.properties describe --replication

kafka-features --bootstrap-controller localhost:9074 \
  --command-config /mnt/admin-config/admin.properties describe

# add-controller reads node.id, process.roles, advertised.listeners from the base server properties
kafka-metadata-quorum --bootstrap-controller <bootstrap-endpoint>:9074 \
  --command-config /mnt/admin-config/admin.properties add-controller
```

---

## 6. Operational Notes

### Rolling KRaftController After `advertisedListeners` Changes

CFK deliberately does **not** trigger a pod roll when the `init-config` ConfigMap changes. This is by design -- init-config holds per-pod metadata (`node.id`, `log.dirs`, `process.roles`) that is not expected to change at runtime, so the operator only rolls on `shared-config` changes (TLS, SASL, quorum config, JVM, etc.).

`advertised.listeners` is the exception: it lives in init-config (because it is pod-specific) but **does** require a restart to take effect in `kafka.properties`. If you add or change external access / `advertisedListeners` on a running cluster you will see the operator update the `init-config` ConfigMap but the pods will **not** restart automatically.

**How to manually trigger the roll:**

Patch the `spec.podTemplate.annotations` on the KRaftController CR. The operator merges these
into the StatefulSet pod template on the next reconcile, changing the pod template hash and
triggering a proper operator-managed rolling restart:

```bash
kubectl patch kraftcontroller kraftcontroller -n <namespace> --type=merge \
  -p '{"spec":{"podTemplate":{"annotations":{"kafkacluster-manual-roll":"2"}}}}'
```

Increment the value (e.g. `"2"` to `"3"`) each time you need another roll. Do **not** patch the StatefulSet directly -- the operator will overwrite it on the next reconcile.

---

### Known Issues and Gotchas

#### 1. `Voter key didn't match receiver's replica key` spam from `kafka-metadata-quorum`

```
Voter key for VOTE or BEGIN_QUORUM_EPOCH request didn't match the receiver's replica key
```

**Root cause:** Bug in the `kafka-metadata-quorum` CLI tool itself, not in the broker/controller.

**Trigger:** When running `kafka-metadata-quorum --bootstrap-controller <endpoint> --command-config kraft.properties` for observer-to-voter promotion (`add-controller`), if the properties file passed via `--command-config` does **not** contain `advertised.listeners`, the leader will spam this error.

**Fix:** Ensure the properties file passed to `--command-config` includes `advertised.listeners` pointing to the pod's own external endpoint. This is independent of whether `advertised.listeners` is present in the KRaft server's own `kafka.properties` used to start the process.

**If you already hit this and the quorum is formed but the leader keeps spamming the error:** Kill the leader pod once. It will restart and the error will go away — the stale state from the CLI invocation does not persist across restarts.

**CP 8.2+ workaround:** With `controller.quorum.auto.join.enable=true`, observer-to-voter promotion happens automatically without invoking the `kafka-metadata-quorum` tool, so this error is never triggered regardless of whether `advertised.listeners` is in the command-config file.

---

#### 2. ZooKeeper-to-KRaft migration: KRaft starts with `kraft.version=0` on CP 7.9.0

During ZK-to-KRaft migration, CP 7.9.0 has a bug that causes KRaft to start with `kraft.version=0` instead of the expected finalized version. This breaks dynamic quorum.

**Fix:** Use **CP 7.9.6** or later -- this version has the fix.

---

## 7. Summary

### Key Takeaways

1. **Dynamic KRaft (KIP-853)** enables controller membership changes without cluster recreation
2. **Static vs Dynamic**: `controller.quorum.voters` to `controller.quorum.bootstrap.servers`
3. **Observer-to-Voter Promotion**: New controllers join as observers, must be manually promoted (or automatically with auto-join on CP 8.2+)
4. **Bootstrap Coordination**: Uses ConfigMap + init container to coordinate bootstrap controller selection
5. **RBAC Required**: Bootstrap pod needs permissions to read/update ConfigMap
6. **Split-Brain Prevention**: Kubernetes atomic ConfigMap updates ensure only one bootstrap controller
7. **advertisedListeners changes require a manual roll** -- patch `spec.podTemplate.annotations` on the CR (see Operational Notes above)

---

## 8. References

- **KIP-853**: [Dynamic Controller Quorum](https://cwiki.apache.org/confluence/display/KAFKA/KIP-853)
- **CFK Documentation**: [Confluent for Kubernetes](https://docs.confluent.io/operator/current/overview.html)
- **KRaft Migration**: [CFK KRaft Migration](https://docs.confluent.io/operator/current/co-migrate-kraft.html)
- **ZK-to-KRaft Migration (Static Quorum)**: [KRaftMigrationJob examples](../../migration/KRaftMigration/)
