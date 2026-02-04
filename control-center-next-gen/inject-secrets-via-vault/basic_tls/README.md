# Example 3: Combined Basic Auth + TLS (Production)

This example demonstrates a C3++ deployment using both **TLS encryption** and **Basic Authentication**, with all secrets stored in HashiCorp Vault.

## What This Example Does

- Deploys KRaft Controller, Kafka, and Control Center Next Gen
- Uses **TLS + Basic Auth** for Prometheus and AlertManager
- **All secrets come from Vault** using two methods:
  - **Vault Agent Injector** for basic auth → `directoryPathInContainer`
  - **External Secrets Operator (ESO)** for TLS → `secretRef`

## Why ESO for TLS? (vs CSI syncSecret)

| Feature | CSI syncSecret + Job | ESO |
|---------|---------------------|-----|
| Initial secret creation | Manual (run Job first) | ✅ Automatic |
| Secret rotation | Manual (re-run Job + restart pods) | ✅ Auto-sync (restart pods) |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              Vault                                       │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ Basic Auth Secrets (basic_txt)                                     │  │
│  │   secret/confluent/prometheus-server                               │  │
│  │   secret/confluent/prometheus-client                               │  │
│  │   secret/confluent/alertmanager-server                             │  │
│  │   secret/confluent/alertmanager-client                             │  │
│  ├───────────────────────────────────────────────────────────────────┤  │
│  │ TLS Secrets (tls_crt, tls_key, ca_crt)                             │  │
│  │   secret/confluent/prometheus-tls                                  │  │
│  │   secret/confluent/alertmanager-tls                                │  │
│  │   secret/confluent/ca                                              │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
          │                                       │
          │ Vault Agent Injector                  │ ESO (refreshInterval: 1h)
          │ (runs as init container)              │ (continuous sync)
          ▼                                       ▼
┌─────────────────────┐              ┌─────────────────────────┐
│  /vault/secrets/    │              │  K8s Secrets (auto)     │
│  prometheus-server/ │              │  - prometheus-tls       │
│    basic.txt        │              │  - alertmanager-tls     │
│  prometheus-client/ │              │  - prometheus-client-tls│
│    basic.txt        │              │  - alertmanager-client- │
│  alertmanager-*/    │              │    tls                  │
│    basic.txt        │              └─────────────────────────┘
└─────────────────────┘                          │
          │                                       │
          │ directoryPathInContainer              │ secretRef
          └───────────────────┬───────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           C3++ Pod (3/3 Running)                         │
│  ┌────────────────────┐ ┌────────────────────┐ ┌────────────────────┐   │
│  │   ControlCenter    │ │     Prometheus     │ │    AlertManager    │   │
│  │  Auth: DPIC        │ │  Auth: DPIC        │ │  Auth: DPIC        │   │
│  │  TLS: secretRef    │ │  TLS: secretRef    │ │  TLS: secretRef    │   │
│  └────────────────────┘ └────────────────────┘ └────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

## Files in This Example

| File | Description |
|------|-------------|
| `GENERATE_CERTS.md` | TLS certificate generation instructions |
| `VAULT_SETUP.md` | Vault + ESO setup with secret storage |
| `external-secrets.yaml` | ESO SecretStore and ExternalSecret definitions |
| `confluent-platform.yaml` | C3++ manifests with Basic Auth + TLS |

## Deployment Steps

### Step 1: Create Namespace

```bash
kubectl create namespace vault-example-3
```

### Step 2: Install Confluent Operator

Follow the instructions at: https://github.com/confluentinc/confluent-operator/blob/master/charts/README.md

### Step 3: Generate TLS Certificates

Follow [GENERATE_CERTS.md](GENERATE_CERTS.md) to create TLS certificates.

### Step 4: Configure Vault and Store Secrets

Follow [VAULT_SETUP.md](VAULT_SETUP.md) to:
- Install External Secrets Operator
- Install Vault with Agent Injector
- Store basic auth secrets in Vault
- Store TLS certificates in Vault

### Step 5: Deploy External Secrets

```bash
kubectl apply -f external-secrets.yaml

# Verify ExternalSecrets are synced
kubectl -n vault-example-3 get externalsecret
# All should show STATUS: SecretSynced

# Verify K8s secrets were created
kubectl -n vault-example-3 get secrets | grep -E "(prometheus|alertmanager)"
# Expected: prometheus-tls, alertmanager-tls, prometheus-client-tls, alertmanager-client-tls

# Verify secret has correct keys
kubectl -n vault-example-3 get secret prometheus-tls -o jsonpath='{.data}' | jq 'keys'
# Expected: ["ca.crt", "tls.crt", "tls.key"]
```

### Step 6: Deploy Confluent Platform

```bash
kubectl apply -f confluent-platform.yaml
```

### Step 7: Watch Deployment

```bash
kubectl -n vault-example-3 get pods -w

# Wait for all pods to be Running:
# - kraftcontroller-0,1,2: 1/1 Running
# - kafka-0,1,2: 1/1 Running
# - controlcenter-next-gen-0: 3/3 Running
```

## Secret Rotation

### When Vault Secrets Are Updated

ESO automatically syncs K8s secrets based on `refreshInterval` (default: 1h). However, pods need to be restarted to pick up new secrets:

```bash
# 1. Update certificates in Vault (see VAULT_SETUP.md Step 8)

# 2. Wait for ESO to sync (up to refreshInterval) or force sync:
kubectl -n vault-example-3 annotate externalsecret prometheus-tls force-sync=$(date +%s) --overwrite

# 3. Verify secret was updated
kubectl -n vault-example-3 get externalsecret prometheus-tls
# Check LAST SYNC time

# 4. Restart pods to pick up new certs
kubectl -n vault-example-3 delete pod controlcenter-next-gen-0
kubectl -n vault-example-3 rollout restart statefulset kraftcontroller
kubectl -n vault-example-3 rollout restart statefulset kafka
```
