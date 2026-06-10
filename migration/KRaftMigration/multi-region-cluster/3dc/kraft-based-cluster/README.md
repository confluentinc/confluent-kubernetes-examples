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

3. **Apply Migration Jobs**: After Kraft controllers are running, apply the migration jobs:
   ```bash
   ./apply-migration-jobs.sh
   ```

   This will create KRaftMigrationJob resources in all three regions to migrate from Zookeeper to Kraft.

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
