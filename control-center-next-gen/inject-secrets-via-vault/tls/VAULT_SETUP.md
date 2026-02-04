# Vault Setup for Example 2: TLS with CSI syncSecret

This example tests if CSI syncSecret can automatically create K8s Secrets for TLS from Vault.

## Prerequisites

- `kubectl` access to the cluster
- Helm installed
- TLS certificates generated (follow [GENERATE_CERTS.md](GENERATE_CERTS.md) first)

## Step 1: Install Secrets Store CSI Driver (with syncSecret enabled)

**Important:** Set `syncSecret.deleteSecretOnPodDelete=false` so secrets persist after the Job completes.

```bash
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo update

helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace vault-example-2 \
  --set syncSecret.enabled=true \
  --set syncSecret.deleteSecretOnPodDelete=false
```

Verify CSI driver is running:

```bash
kubectl -n vault-example-2 get pods -l app=secrets-store-csi-driver
# Should show Running pods on each node
```

## Step 2: Install Vault CSI Provider

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm upgrade --install vault-csi-provider hashicorp/vault \
  --namespace vault-example-2 \
  --set "server.enabled=false" \
  --set "injector.enabled=false" \
  --set "csi.enabled=true"
```

Verify CSI provider is running:

```bash
kubectl -n vault-example-2 get pods -l app.kubernetes.io/name=vault-csi-provider
# Should show Running pods on each node
```

## Step 3: Install Vault Server

```bash
helm upgrade --install vault hashicorp/vault \
  --namespace vault-example-2 \
  --set 'server.dev.enabled=true'
```

Wait for Vault to be ready:

```bash
kubectl -n vault-example-2 get pods -l app.kubernetes.io/name=vault
# vault-0 should be 1/1 Running
```

## Step 4: Enable Kubernetes Authentication

Enter the Vault pod:

```bash
kubectl exec -it vault-0 -n vault-example-2 -- /bin/sh
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
```

## Step 5: Create Vault Policy

```bash
vault policy write confluent-operator - <<EOF
path "secret/*" {
  capabilities = ["read"]
}
EOF
```

## Step 6: Create Kubernetes Role Binding

```bash
vault write auth/kubernetes/role/confluent-operator \
  bound_service_account_names=default \
  bound_service_account_namespaces=vault-example-2 \
  policies=confluent-operator \
  ttl=24h
```

## Step 7: Exit Vault Pod

```bash
exit
```

## Step 8: Store TLS Certificates in Vault

First, generate certificates by following [GENERATE_CERTS.md](GENERATE_CERTS.md).

**Important:** Store certificates as raw PEM data (NOT base64-encoded):

```bash
# Store Prometheus TLS (raw PEM)
kubectl exec vault-0 -n vault-example-2 -- vault kv put secret/confluent/prometheus-tls \
  "tls_crt=$(cat certs/prometheus-fullchain.pem)" \
  "tls_key=$(cat certs/prometheus-privkey.pem)"

# Store AlertManager TLS (raw PEM)
kubectl exec vault-0 -n vault-example-2 -- vault kv put secret/confluent/alertmanager-tls \
  "tls_crt=$(cat certs/alertmanager-fullchain.pem)" \
  "tls_key=$(cat certs/alertmanager-privkey.pem)"

# Store CA certificate (raw PEM)
kubectl exec vault-0 -n vault-example-2 -- vault kv put secret/confluent/ca \
  "ca_crt=$(cat certs/ca.crt)"
```

## Step 9: Verify Secrets in Vault

```bash
kubectl exec vault-0 -n vault-example-2 -- vault kv list secret/confluent/

# Expected output:
# Keys
# ----
# alertmanager-tls
# ca
# prometheus-tls
```

## How syncSecret Works

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
│              SecretProviderClass (vault-c3-tls)                  │
│  - Defines which Vault paths to fetch                           │
│  - Defines secretObjects for syncSecret                         │
└─────────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          ▼                                       ▼
┌─────────────────────┐              ┌─────────────────────────┐
│  /mnt/vault-tls/    │              │  K8s Secrets (synced)   │
│  (mounted files)    │              │  - prometheus-tls       │
│                     │              │  - alertmanager-tls     │
│                     │              │  - prometheus-client-tls│
│                     │              │  - alertmanager-client- │
│                     │              │    tls                  │
└─────────────────────┘              └─────────────────────────┘
                                                  │
                                                  ▼ secretRef
                                     ┌─────────────────────────┐
                                     │  C3++ Pod uses TLS      │
                                     │  via secretRef          │
                                     └─────────────────────────┘
```

## Key Points

1. **syncSecret creates K8s Secrets during volume mount** - before containers start
2. **K8s Secrets are available for secretRef** - the operator can reference them
3. **Vault is the source of truth** - TLS certs are stored in Vault, synced to K8s

## Next Steps

After completing Vault setup:

1. Deploy the SecretProviderClass:
   ```bash
   kubectl apply -f secret-provider-class.yaml
   ```

2. Deploy Confluent Platform:
   ```bash
   kubectl apply -f confluent-platform.yaml
   ```

3. Verify synced secrets were created:
   ```bash
   kubectl -n vault-example-2 get secrets | grep -E "(prometheus|alertmanager)"
   ```
