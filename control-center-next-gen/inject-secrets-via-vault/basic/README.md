# Example 1: Basic Auth Only (No TLS) with Vault Agent Injector

This example demonstrates a C3++ deployment using **only Basic Authentication** (no TLS) with all secrets injected from HashiCorp Vault using Vault Agent Injector.

## What This Example Does

- Deploys KRaft Controller, Kafka, and Control Center Next Gen
- Uses Basic Auth for Prometheus and AlertManager (no TLS)
- **All secrets come from Vault** - no direct K8s Secrets for authentication
- Uses Vault Agent Injector to inject secrets before containers start
- Uses `directoryPathInContainer` to reference the injected secrets

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Vault                                    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ secret/confluent/prometheus-server/basic_txt            │    │
│  │ secret/confluent/prometheus-client/basic_txt            │    │
│  │ secret/confluent/alertmanager-server/basic_txt          │    │
│  │ secret/confluent/alertmanager-client/basic_txt          │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ (Vault Agent Injector)
┌─────────────────────────────────────────────────────────────────┐
│                    C3++ Pod                                      │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ /vault/secrets/                                          │    │
│  │   ├── prometheus-server/basic.txt                        │    │
│  │   ├── prometheus-client/basic.txt                        │    │
│  │   ├── alertmanager-server/basic.txt                      │    │
│  │   └── alertmanager-client/basic.txt                      │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ControlCenter │  │  Prometheus  │  │ AlertManager │          │
│  │   (reads     │  │   (reads     │  │   (reads     │          │
│  │  from DPIC)  │  │  from DPIC)  │  │  from DPIC)  │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
└─────────────────────────────────────────────────────────────────┘
```

## How Vault Agent Injector Works

1. **Annotation-based**: Pods with `vault.hashicorp.com/agent-inject: "true"` trigger injection
2. **Init Container**: Vault injects an init container that runs FIRST (before operator's init container)
3. **Shared Volume**: Secrets are written to `/vault/secrets/` directory
4. **Available to All Containers**: All containers (including operator's init container) can access the secrets

Key annotation: `vault.hashicorp.com/agent-init-first: "true"` ensures Vault runs before other init containers.

## Files in This Example

| File | Description |
|------|-------------|
| `VAULT_SETUP.md` | Step-by-step Vault setup with Agent Injector |
| `confluent-platform.yaml` | KRaft, Kafka, and C3++ manifests with Vault annotations |

## Deployment Steps

### Step 1: Create Namespace

```bash
kubectl create namespace vault-example-1
```

### Step 2: Install Confluent Operator

Follow the instructions at: https://github.com/confluentinc/confluent-operator/blob/master/charts/README.md

### Step 3: Configure Vault with Agent Injector

Follow the instructions in [VAULT_SETUP.md](VAULT_SETUP.md) to:
- Install Vault with Agent Injector enabled
- Enable Kubernetes authentication in Vault
- Create the Vault policy and role
- Store all required secrets

### Step 4: Deploy Confluent Platform

```bash
kubectl apply -f confluent-platform.yaml
```

### Step 5: Wait for Deployment

```bash
# Watch pods
kubectl -n vault-example-1 get pods -w

# Expected output (all Running):
# kraftcontroller-0                  1/1     Running
# kraftcontroller-1                  1/1     Running
# kraftcontroller-2                  1/1     Running
# kafka-0                            1/1     Running
# kafka-1                            1/1     Running
# kafka-2                            1/1     Running
# controlcenter-next-gen-0           3/3     Running
# vault-0                            1/1     Running
# vault-agent-injector-*             1/1     Running
```
