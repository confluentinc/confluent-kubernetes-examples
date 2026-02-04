# Vault Setup for Example 3: Combined Basic Auth + TLS (Production)

This example combines:
- **Vault Agent Injector** for basic auth (directoryPathInContainer)
- **External Secrets Operator (ESO)** for TLS (auto-sync from Vault to K8s Secrets)

## Prerequisites

- TLS certificates generated (follow [GENERATE_CERTS.md](GENERATE_CERTS.md) first)

## Step 1: Install External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace vault-example-3 \
  --set installCRDs=true
```

Verify ESO is running:

```bash
kubectl -n vault-example-3 get pods -l app.kubernetes.io/name=external-secrets
# Should show Running pods
```

## Step 2: Install Vault with Agent Injector

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm upgrade --install vault hashicorp/vault \
  --namespace vault-example-3 \
  --set 'server.dev.enabled=true' \
  --set 'injector.enabled=true'
```

Wait for Vault to be ready:

```bash
kubectl -n vault-example-3 get pods -l app.kubernetes.io/name=vault
# vault-0: 1/1 Running
# vault-agent-injector-xxx: 1/1 Running
```

## Step 3: Configure Vault Authentication

Enter the Vault pod:

```bash
kubectl exec -it vault-0 -n vault-example-3 -- /bin/sh
```

Run inside Vault pod:

```bash
# Enable Kubernetes auth method
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

# Create policy
vault policy write confluent-operator - <<EOF
path "secret/*" {
  capabilities = ["read"]
}
EOF

# Create role for Vault Agent Injector and ESO
vault write auth/kubernetes/role/confluent-operator \
  bound_service_account_names=default \
  bound_service_account_namespaces=vault-example-3 \
  policies=confluent-operator \
  ttl=24h
```

## Step 4: Store Basic Auth Secrets

**Important:** Use underscores in key names (e.g., `basic_txt`) for Go template compatibility.

```bash
# Prometheus Server Basic Auth (format: username: password)
vault kv put secret/confluent/prometheus-server \
  basic_txt='admin: prometheus-password'

# Prometheus Client Basic Auth (format: username=x\npassword=y)
vault kv put secret/confluent/prometheus-client \
  basic_txt='username=admin
password=prometheus-password'

# AlertManager Server Basic Auth
vault kv put secret/confluent/alertmanager-server \
  basic_txt='admin: alertmanager-password'

# AlertManager Client Basic Auth
vault kv put secret/confluent/alertmanager-client \
  basic_txt='username=admin
password=alertmanager-password'
```

## Step 5: Exit Vault Pod

```bash
exit
```

## Step 6: Store TLS Certificates in Vault

**Important:** Store as raw PEM (NOT base64-encoded).

```bash
# Store Prometheus TLS (raw PEM)
kubectl exec vault-0 -n vault-example-3 -- vault kv put secret/confluent/prometheus-tls \
  "tls_crt=$(cat certs/prometheus-fullchain.pem)" \
  "tls_key=$(cat certs/prometheus-privkey.pem)"

# Store AlertManager TLS (raw PEM)
kubectl exec vault-0 -n vault-example-3 -- vault kv put secret/confluent/alertmanager-tls \
  "tls_crt=$(cat certs/alertmanager-fullchain.pem)" \
  "tls_key=$(cat certs/alertmanager-privkey.pem)"

# Store CA certificate (raw PEM)
kubectl exec vault-0 -n vault-example-3 -- vault kv put secret/confluent/ca \
  "ca_crt=$(cat certs/ca.crt)"
```

## Step 7: Verify All Secrets in Vault

```bash
kubectl exec vault-0 -n vault-example-3 -- vault kv list secret/confluent/

# Expected:
# alertmanager-client
# alertmanager-server
# alertmanager-tls
# ca
# prometheus-client
# prometheus-server
# prometheus-tls
```

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         Vault                                    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ Basic Auth: prometheus-server, prometheus-client, etc.  │    │
│  │ TLS Certs: prometheus-tls, alertmanager-tls, ca         │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
          │                                       │
          │ Vault Agent Injector                  │ ESO (refreshInterval: 1h)
          │ (for Basic Auth)                      │ (for TLS)
          ▼                                       ▼
┌─────────────────────┐              ┌─────────────────────────┐
│  /vault/secrets/    │              │  K8s Secrets            │
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
                    ┌─────────────────┐
                    │   C3++ Pod      │
                    │  3/3 Running    │
                    └─────────────────┘
```

## Next Steps

1. Deploy External Secrets:
   ```bash
   kubectl apply -f external-secrets.yaml

   # Verify secrets are synced
   kubectl -n vault-example-3 get externalsecret
   # All should show "SecretSynced"

   kubectl -n vault-example-3 get secrets | grep -E "(prometheus|alertmanager)"
   # Should show all 4 TLS secrets
   ```

2. Deploy Confluent Platform:
   ```bash
   kubectl apply -f confluent-platform.yaml
   ```
