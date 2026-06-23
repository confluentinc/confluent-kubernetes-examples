# Kraft-Based Multi-Region Cluster

This playbook sets up a Kraft-based multi-region cluster with the following configuration:

## Architecture

- **Central Region**: 1 Kraft controller replica
- **East Region**: 2 Kraft controller replicas  
- **West Region**: 2 Kraft controller replicas

## Prerequisites

- Three Kubernetes clusters with contexts: `mrc-central`, `mrc-east`, `mrc-west`
- `cfssl` and `cfssljson` tools installed
- `kubectl` configured with access to all three clusters
- `curl` for downloading MDS tokens

## Setup

1. **Prerequisites**: Ensure the zookeeper-based-cluster is already set up with CA certificates and MDS tokens.

2. Run the setup script:
   ```bash
   ./setup-kraft.sh
   ```

   This will:
   - Copy CA certificate and configuration from zookeeper-based-cluster
   - Generate server certificates for all Kraft controllers
   - Create namespaces in all three regions
   - Deploy Kraft controllers with TLS enabled
   - Wait for all controllers to be in RUNNING state

3. **Apply Migration Jobs**: After Kraft controllers are running, apply migration jobs
   in all regions:
   ```bash
   ./apply-migration-jobs.sh
   ```

   This script applies the KRaftMigrationJob in all three regions. All KMJs must be applied
   for the KRaft controller quorum to form and migration to proceed. See
   [MRC migration sequencing](#mrc-migration-sequencing) for availability considerations.

## Teardown

1. **Teardown Migration Jobs First**: Before tearing down Kraft controllers, remove the migration jobs:
   ```bash
   ./teardown-migration-jobs.sh
   ```

2. Run the teardown script:
   ```bash
   ./teardown.sh
   ```

   This will:
   - Delete all Kraft controllers
   - Remove all TLS secrets and certificates
   - Clean up namespaces
   - Preserve certificate configuration files for reuse

## Certificate Management

The setup generates certificates with comprehensive SANs including:
- Internal Kubernetes service names
- External load balancer endpoints
- MDS (Metadata Service) endpoints for cross-region communication
- Bootstrap endpoints for cluster formation

## Monitoring

### Kraft Controllers
Check the status of Kraft controllers:
```bash
# Central region
kubectl get kraftcontroller -n central --context mrc-central

# East region  
kubectl get kraftcontroller -n east --context mrc-east

# West region
kubectl get kraftcontroller -n west --context mrc-west
```

### Migration Job Status
Monitor the KRaftMigrationJob status to ensure migration is complete:

```bash
# Central region
kubectl get kmj kraftmigrationjob-central -n central --context mrc-central -w -oyaml

# East region
kubectl get kmj kraftmigrationjob-east -n east --context mrc-east -w -oyaml

# West region
kubectl get kmj kraftmigrationjob-west -n west --context mrc-west -w -oyaml
```

**Migration Complete**: The migration is complete when the status shows:
- `phase: COMPLETE`
- `type: platform.confluent.io/kraft-migration` with `status: "True"`
- `reason: KRaftMigrationComplete`

### Finalization
Trigger finalization **one region at a time**. Wait for each region to reach the `COMPLETE`
phase before proceeding to the next:

```bash
# Finalize central region
kubectl annotate kmj kraftmigrationjob-central -n central \
  platform.confluent.io/kraft-migration-trigger-finalize-to-kraft=true --overwrite --context mrc-central
# Wait for COMPLETE phase before proceeding
kubectl get kmj kraftmigrationjob-central -n central --context mrc-central -w -oyaml

# Finalize east region
kubectl annotate kmj kraftmigrationjob-east -n east \
  platform.confluent.io/kraft-migration-trigger-finalize-to-kraft=true --overwrite --context mrc-east
# Wait for COMPLETE phase before proceeding
kubectl get kmj kraftmigrationjob-east -n east --context mrc-east -w -oyaml

# Finalize west region
kubectl annotate kmj kraftmigrationjob-west -n west \
  platform.confluent.io/kraft-migration-trigger-finalize-to-kraft=true --overwrite --context mrc-west
```

> **Note:** Finalization is irreversible — once ZooKeeper is removed from a region's brokers,
> that region cannot roll back to ZooKeeper mode.

### Post-Migration Steps
After migration is complete:

1. **Download updated CRs**: The migration job will provide instructions to download updated Kafka and KRaftController CRs
2. **Release migration lock**: Run the following command for each region:
   ```bash
   # Central region
   kubectl annotate kmj kraftmigrationjob-central -n central platform.confluent.io/kraft-migration-release-cr-lock=true --overwrite --context mrc-central
   
   # East region
   kubectl annotate kmj kraftmigrationjob-east -n east platform.confluent.io/kraft-migration-release-cr-lock=true --overwrite --context mrc-east
   
   # West region
   kubectl annotate kmj kraftmigrationjob-west -n west platform.confluent.io/kraft-migration-release-cr-lock=true --overwrite --context mrc-west
   ```

3. **Remove Zookeeper clusters**: After migration is complete, you can safely remove Zookeeper clusters in all three regions as they are no longer needed.

## MRC migration sequencing

KRaftMigrationJobs must be applied in **all regions** for migration to proceed. The KMJ in
each region releases the `kraft-migration-hold-krc-creation` annotation on that region's
KRaft controllers — without all KMJs applied, controllers in the remaining regions stay in
HOLD, the quorum cannot form a majority, and the migration gets stuck (controllers crash-loop
on secured clusters because the RBAC authorizer cannot initialize without a quorum leader).

During migration, each region's Kafka brokers are rolled multiple times. Each region's
operator rolls brokers independently — within a region, only one broker restarts at a time,
and the operator gates on cluster-wide URP=0 (under-replicated partitions = 0) before rolling
the next. Because the URP check is cluster-wide, a broker restart in one region blocks other
regions from rolling a broker that shares a partition replica.

However, there is no distributed lock across regions — each region's operator evaluates the
URP check on its own loop. There is a small theoretical timing window where two operators
could both read URP=0 and begin a restart before either shutdown registers.

### Prerequisites

- **>= 2 brokers per region.** Restarting a region's only broker leaves that region with
  nothing running — guaranteed outage.
- **`zookeeper.connect` on KRaftController must exactly match the Kafka CR's ZK endpoint**
  (same hosts, same chroot). A mismatch causes the migration to loop indefinitely.

### Migration procedure

Apply KRaftMigrationJobs in all regions. The operator's cluster-wide URP=0 check serializes
broker restarts at the partition-availability level — at most one replica of any given
partition is offline at a time. With >= 2 brokers per region and appropriate RF, this provides
zero downtime. You can stagger the KMJ starts by a few minutes across regions to further
reduce the small URP race window.

To further protect availability, you can increase the replication factor for all topics before
starting migration. In a 3-region deployment: RF >= 4 with `min.insync.replicas` <= RF - 3.

> **Note:** `DUAL-WRITE` is a cluster-wide state, not a per-region state. The last region to
> finish its broker rolls is the bottleneck for this transition.

### Finalization procedure

Trigger finalization **one region at a time**. Wait for each region to reach `COMPLETE`
before proceeding to the next.

> **Note:** Finalization is irreversible — once ZooKeeper is removed from a region's brokers,
> that region cannot roll back to ZooKeeper mode.

### Rollback procedure

If you need to roll back to ZooKeeper, trigger rollback one region at a time. Rollback
involves up to multiple Kafka broker rolls per region, plus a manual step to delete ZooKeeper
znodes.

1. Trigger rollback in the first region. Monitor its status until it reaches
   `RollbackToZkWaitForManualNodeRemovalFromZk`, which indicates the first broker roll is
   complete and the job is waiting for manual intervention.
2. Delete the `/controller` and `/migration` znodes from ZooKeeper as directed by the status
   condition, then apply the continue annotation to resume the rollback. Wait for the region
   to reach `RollbackToZkComplete`.
3. Repeat for each subsequent region, waiting for `RollbackToZkComplete` before moving to
   the next.

## Files

- `setup.sh` - Main setup script
- `teardown.sh` - Cleanup script
- `apply-migration-jobs.sh` - Apply KRaftMigrationJob resources
- `teardown-migration-jobs.sh` - Remove KRaftMigrationJob resources
- `confluent-platform/kraft/` - Kraft controller manifests
- `confluent-platform/migrationjob/` - KRaftMigrationJob manifests
- `certs/server_configs/` - Certificate configuration files
- `certs/ca/` - CA certificate (copied from zookeeper-based-cluster)
- `certs/generated/` - Server certificates (generated)
- `certs/mds/` - MDS tokens (copied from zookeeper-based-cluster)
