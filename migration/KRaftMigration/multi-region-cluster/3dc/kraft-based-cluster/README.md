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
   **one region at a time**:
   ```bash
   ./apply-migration-jobs.sh
   ```

   This script applies the KRaftMigrationJob in each region sequentially, waiting for each
   region to complete its broker rolls before proceeding to the next. See
   [MRC migration sequencing](#mrc-migration-sequencing) for why this is necessary.

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

In a Multi-Region Cluster (MRC), apply the KRaftMigrationJob to one region at a time and
wait for each region to complete its broker rolls before proceeding to the next. This applies
to both the migration and finalization stages.

During migration, each region's Kafka brokers are rolled multiple times. During finalization,
brokers are rolled again to remove the ZooKeeper dependency, and KRaft controllers are rolled
to remove migration configs. Since each region's operator rolls brokers independently with no
cross-region coordination, triggering multiple regions simultaneously can cause brokers holding
replicas of the same partition to restart at the same time — potentially making topics
unavailable even when the replication factor would otherwise survive a single-region restart.

### Migration procedure

1. Apply the KRaftMigrationJob CR in the first region. Monitor its status until it reaches
   the `MIGRATE` phase with subphase `MigrateMonitorMigrationProgress`. At this point, all
   broker rolls for this region are complete.
2. Repeat for each subsequent region, waiting for the same status before moving to the next.
3. Once the final region completes its broker rolls, the KRaft controllers across all regions
   will detect that all voters have registered and transition the cluster to `DUAL-WRITE` state.
4. Verify that all regions report the `DUAL-WRITE` phase before proceeding to finalization.

> **Note:** `DUAL-WRITE` is a cluster-wide state, not a per-region state. The last region to
> finish its broker rolls is the bottleneck for this transition.

### Finalization procedure

1. Trigger finalization in the first region. This removes the ZooKeeper dependency from Kafka
   brokers and the migration configuration from KRaft controllers, each requiring a roll. Wait
   for the region to reach the `COMPLETE` phase.
2. Repeat for each subsequent region, waiting for `COMPLETE` before moving to the next.

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

### Parallel migration (advanced)

If minimizing migration time is a priority and your cluster can tolerate multiple brokers
restarting simultaneously across regions, you can trigger all regions in parallel. Before
doing so, ensure:

- **KRaft quorum availability**: The KRaft controller quorum must be large enough to maintain
  a majority even when one controller per region is restarting simultaneously. In a 2-region
  deployment, you need at least 6 KRaft controllers (3 per region); in a 3-region deployment,
  you need at least 7. This ensures the quorum retains a majority even with one controller
  down in every region at the same time.
- **Topic availability**: The replication factor for all topics must be greater than the number
  of regions, and `min.insync.replicas` must be configured so that writes can continue even
  with one replica per region unavailable. For example, in a 3-region deployment, RF >= 4 with
  `min.insync.replicas` <= RF - 3 ensures that one broker restarting per region does not cause
  topic unavailability.

If either condition is not met, use the sequential one-region-at-a-time approach described
above.

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
