# Example 2: TLS with Vault CSI syncSecret

This example tests if CSI syncSecret can automatically create K8s Secrets for TLS from Vault, without manual secret creation.

## What This Example Demonstrates

- **Result**: CSI syncSecret successfully creates K8s Secrets for TLS from Vault
- **Challenge**: Operator validates `secretRef` secrets exist BEFORE creating pods, but CSI syncSecret only creates secrets when a pod mounts the volume
- **Solution**: Use a Job to mount the CSI volume first, triggering syncSecret to create K8s Secrets before deploying Confluent CRs

## How It Works (Job-based Approach)

The naive approach (mounting CSI volume directly in ControlCenter CR) doesn't work because:
1. Operator validates `secretRef` secrets exist before creating pods
2. CSI syncSecret only creates K8s Secrets when a pod mounts the volume
3. This creates a chicken-and-egg problem

**Solution:** Run a Job first to trigger syncSecret:

1. Deploy SecretProviderClass (defines Vault paths and K8s secret mapping)
2. Run a Job that mounts the CSI volume
3. CSI driver fetches secrets from Vault and mounts as files
4. syncSecret creates K8s Secrets from the mounted content
5. Job completes (secrets persist due to `deleteSecretOnPodDelete=false`)
6. Deploy ControlCenter CR - operator finds secrets, creates pods
7. C3++ pod uses `secretRef` to mount the synced secrets

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Vault                                    │
│  secret/confluent/prometheus-tls (tls_crt, tls_key)             │
│  secret/confluent/alertmanager-tls (tls_crt, tls_key)           │
│  secret/confluent/ca (ca_crt)                                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ CSI Driver fetches on volume mount
┌─────────────────────────────────────────────────────────────────┐
│           Secret Sync Job (runs once, then completes)            │
│  - Mounts CSI volume referencing SecretProviderClass            │
│  - Triggers syncSecret to create K8s Secrets                    │
│  - Auto-deletes after 5 minutes (ttlSecondsAfterFinished)       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ syncSecret creates
┌─────────────────────────────────────────────────────────────────┐
│                    K8s Secrets (persisted)                       │
│  prometheus-tls (Opaque: tls.crt, tls.key, ca.crt)              │
│  alertmanager-tls (Opaque: tls.crt, tls.key, ca.crt)            │
│  prometheus-client-tls (Opaque: ca.crt)                         │
│  alertmanager-client-tls (Opaque: ca.crt)                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ secretRef
┌─────────────────────────────────────────────────────────────────┐
│                    C3++ Pod (deployed after Job)                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ControlCenter │  │  Prometheus  │  │ AlertManager │          │
│  │  TLS client  │  │  TLS server  │  │  TLS server  │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. Kubernetes cluster
2. `kubectl` access to the cluster
3. Helm installed

## Files in This Example

| File | Description |
|------|-------------|
| `GENERATE_CERTS.md` | TLS certificate generation instructions |
| `VAULT_SETUP.md` | Vault, CSI driver, and CSI provider setup |
| `secret-provider-class.yaml` | SecretProviderClass with syncSecret config |
| `secret-sync-job.yaml` | Job to trigger syncSecret (runs once, secrets persist) |
| `confluent-platform.yaml` | C3++ manifests using TLS via secretRef |

## Deployment Steps

### Step 1: Create Namespace

```bash
kubectl create namespace vault-example-2
```

### Step 2: Install Confluent Operator

Follow the instructions at: https://github.com/confluentinc/confluent-operator/blob/master/charts/README.md

### Step 3: Generate TLS Certificates

Follow [GENERATE_CERTS.md](GENERATE_CERTS.md) to create TLS certificates.

### Step 4: Configure Vault and Store TLS Certs

Follow [VAULT_SETUP.md](VAULT_SETUP.md) to:
- Install CSI driver (with syncSecret enabled)
- Install Vault CSI provider
- Install Vault server
- Store TLS certificates in Vault

### Step 5: Deploy SecretProviderClass

```bash
kubectl apply -f secret-provider-class.yaml
```

### Step 6: Run Secret Sync Job (Required)

The operator validates that `secretRef` secrets exist before creating pods. We use a Job to trigger syncSecret first:

```bash
# Run the secret sync job
kubectl apply -f secret-sync-job.yaml

# Wait for Job to complete
kubectl -n vault-example-2 get job vault-secret-sync -w
# Wait until COMPLETIONS shows 1/1

# Verify all 4 secrets were created with correct keys
kubectl -n vault-example-2 get secrets | grep -E "(prometheus|alertmanager)"
# Expected: prometheus-tls, alertmanager-tls, prometheus-client-tls, alertmanager-client-tls

# Verify prometheus-tls has ca.crt
kubectl -n vault-example-2 get secret prometheus-tls -o jsonpath='{.data}' | jq 'keys'
# Expected: ["ca.crt", "tls.crt", "tls.key"]
```

### Step 7: Deploy Confluent Platform

```bash
kubectl apply -f confluent-platform.yaml
```

### Step 8: Watch Deployment

```bash
kubectl -n vault-example-2 get pods -w

# ControlCenter should be 3/3 Running
```

**Note:** The Job auto-cleans up after 5 minutes (`ttlSecondsAfterFinished: 300`). Secrets persist because CSI driver was installed with `syncSecret.deleteSecretOnPodDelete=false`.

## Secret Rotation

When TLS certificates are updated in Vault, you need to manually sync and restart:

```bash
# 1. Update certificates in Vault (see VAULT_SETUP.md Step 10)

# 2. Delete old K8s secrets
kubectl -n vault-example-2 delete secret prometheus-tls alertmanager-tls prometheus-client-tls alertmanager-client-tls

# 3. Re-run the sync Job (delete old job first)
kubectl -n vault-example-2 delete job vault-secret-sync --ignore-not-found
kubectl apply -f secret-sync-job.yaml

# 4. Wait for Job to complete
kubectl -n vault-example-2 get job vault-secret-sync -w

# 5. Restart ControlCenter to pick up new certs
kubectl -n vault-example-2 delete pod controlcenter-next-gen-0
```

**For automatic rotation**, consider using External Secrets Operator (ESO) - see Example 3 (basic_tls).
