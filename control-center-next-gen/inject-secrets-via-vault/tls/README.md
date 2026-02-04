# Example 2: TLS with Vault CSI syncSecret

This example tests if CSI syncSecret can automatically create K8s Secrets for TLS from Vault, without manual secret creation.

## What This Example Demonstrates

- **Result**: CSI syncSecret successfully creates K8s Secrets for TLS from Vault
- **Requirement**: A bootstrap pod is needed to trigger syncSecret before deploying the CR (operator validates `secretRef` exists)
- **Goal**: TLS certificates stored in Vault, automatically synced to K8s Secrets, used via `secretRef`
- **No basic auth** - just TLS to isolate the test

## How syncSecret Should Work

1. ControlCenter CR includes `mountedVolumes` with CSI driver
2. When pod starts, CSI volume is mounted (before any containers)
3. CSI driver fetches secrets from Vault
4. syncSecret creates K8s Secrets from the fetched content
5. `secretRef` can now reference these K8s Secrets
6. Init containers and main containers start

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Vault                                    │
│  secret/confluent/prometheus-tls (tls_crt, tls_key)             │
│  secret/confluent/alertmanager-tls (tls_crt, tls_key)           │
│  secret/confluent/ca (ca_crt)                                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ (CSI Driver + syncSecret)
┌─────────────────────────────────────────────────────────────────┐
│                    K8s Secrets (auto-created)                    │
│  prometheus-tls (kubernetes.io/tls)                              │
│  alertmanager-tls (kubernetes.io/tls)                            │
│  prometheus-client-tls (Opaque, ca.crt)                          │
│  alertmanager-client-tls (Opaque, ca.crt)                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ (secretRef)
┌─────────────────────────────────────────────────────────────────┐
│                    C3++ Pod                                      │
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
