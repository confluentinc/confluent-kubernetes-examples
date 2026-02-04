# Vault Setup for Example 1: Basic Auth Only (Vault Agent Injector)

This document provides step-by-step instructions to configure HashiCorp Vault for the Basic Auth Only example using Vault Agent Injector.

## Prerequisites

- `kubectl` access to the cluster
- Helm installed

## Step 1: Install Vault with Agent Injector Enabled

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm upgrade --install vault hashicorp/vault \
  --namespace vault-example-1 \
  --set "server.dev.enabled=true" \
  --set "injector.enabled=true"
```

Wait for Vault to be ready:

```bash
kubectl -n vault-example-1 get pods
# vault-0 should be 1/1 Running
# vault-agent-injector-* should be 1/1 Running
```

## Step 2: Enable Kubernetes Authentication

Enter the Vault pod:

```bash
kubectl exec -it vault-0 -n vault-example-1 -- /bin/sh
```

Run the following commands inside the Vault pod:

```bash
# Enable Kubernetes auth method
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

## Step 3: Create Vault Policy

Still inside the Vault pod:

```bash
vault policy write confluent-operator - <<EOF
path "secret/*" {
  capabilities = ["read"]
}
EOF
```

## Step 4: Create Kubernetes Role Binding

```bash
vault write auth/kubernetes/role/confluent-operator \
  bound_service_account_names=default \
  bound_service_account_namespaces=vault-example-1 \
  policies=confluent-operator \
  ttl=24h
```

## Step 5: Store Secrets in Vault

**Important**: Use underscores in key names (e.g., `basic_txt`) for Go template compatibility.

### Prometheus Server Basic Auth

Format for server-side: `username: password`

```bash
vault kv put secret/confluent/prometheus-server \
  basic_txt='admin: prometheus-password'
```

### Prometheus Client Basic Auth

Format for client-side: `username=value` and `password=value` on separate lines

```bash
vault kv put secret/confluent/prometheus-client \
  basic_txt='username=admin
password=prometheus-password'
```

### AlertManager Server Basic Auth

```bash
vault kv put secret/confluent/alertmanager-server \
  basic_txt='admin: alertmanager-password'
```

### AlertManager Client Basic Auth

```bash
vault kv put secret/confluent/alertmanager-client \
  basic_txt='username=admin
password=alertmanager-password'
```

## Step 6: Verify Secrets

```bash
# List all secrets
vault kv list secret/confluent/

# Verify specific secrets
vault kv get secret/confluent/prometheus-server
vault kv get secret/confluent/prometheus-client
vault kv get secret/confluent/alertmanager-server
vault kv get secret/confluent/alertmanager-client
```

## Step 7: Exit Vault Pod

```bash
exit
```

## How Vault Agent Injector Works

1. **Annotation-based**: Pods with `vault.hashicorp.com/agent-inject: "true"` trigger injection
2. **Init Container**: Vault injects an init container that runs FIRST and fetches secrets
3. **Shared Volume**: Secrets are written to `/vault/secrets/` directory
4. **Available to All Containers**: All containers (including operator's init container) can access the secrets

## Secret Format Reference

| Secret | Format | Example |
|--------|--------|---------|
| Server Basic Auth | `username: password` | `admin: prometheus-password` |
| Client Basic Auth | `username=value\npassword=value` | `username=admin\npassword=secret` |

## Next Steps

After completing Vault setup, deploy Confluent Platform:

```bash
kubectl apply -f confluent-platform.yaml
```

Note: SecretProviderClass is NOT needed when using Vault Agent Injector.
