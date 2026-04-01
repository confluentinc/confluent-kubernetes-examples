# Observer Container TLS Configuration

This directory provides three TLS configuration approaches for the Observer Container with Confluent Platform.

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Kubernetes Cluster                             │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                          operator namespace                           │  │
│  │                                                                       │  │
│  │  ┌─────────────────────┐        ┌─────────────────────┐              │  │
│  │  │   KRaftController   │        │       Kafka         │              │  │
│  │  │      StatefulSet    │        │    StatefulSet      │              │  │
│  │  │                     │        │                     │              │  │
│  │  │  ┌───────────────┐  │        │  ┌───────────────┐  │              │  │
│  │  │  │ kraft-0 Pod   │  │        │  │  kafka-0 Pod  │  │              │  │
│  │  │  │ ┌───────────┐ │  │        │  │ ┌───────────┐ │  │              │  │
│  │  │  │ │ KRaft     │ │  │        │  │ │ Kafka     │ │  │              │  │
│  │  │  │ │ Container │ │  │        │  │ │ Container │ │  │              │  │
│  │  │  │ │  :9074    │ │  │        │  │ │  :9071    │ │  │              │  │
│  │  │  │ │  :7777    │◄├──┼────────┼──┤►│  :7777    │ │  │              │  │
│  │  │  │ └───────────┘ │  │        │  │ └───────────┘ │  │              │  │
│  │  │  │ ┌───────────┐ │  │        │  │ ┌───────────┐ │  │              │  │
│  │  │  │ │ Observer  │ │  │        │  │ │ Observer  │ │  │              │  │
│  │  │  │ │ Container │ │  │        │  │ │ Container │ │  │              │  │
│  │  │  │ │  :7443    │ │  │◄───────│  │ │  :7443    │ │  │              │  │
│  │  │  │ └───────────┘ │  │ mTLS   │  │ └───────────┘ │  │              │  │
│  │  │  └───────────────┘  │        │  └───────────────┘  │              │  │
│  │  └─────────────────────┘        └─────────────────────┘              │  │
│  │           ▲                                ▲                          │  │
│  │           │                                │                          │  │
│  │           │         ┌──────────────┐       │                          │  │
│  │           └─────────┤   Secrets    ├───────┘                          │  │
│  │                     │  tls-kraft   │                                  │  │
│  │                     │  tls-kafka   │                                  │  │
│  │                     └──────────────┘                                  │  │
│  │                            ▲                                          │  │
│  │                            │ (DPIC mode only)                         │  │
│  │                     ┌──────┴───────┐                                  │  │
│  │                     │    Vault     │                                  │  │
│  │                     │   vault-0    │                                  │  │
│  │                     └──────────────┘                                  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 📋 Configuration Modes

| Mode | File | Observer mTLS | Metrics mTLS | Vault |
|------|------|---------------|--------------|-------|
| **mTLS + SecretRef** | `confluent_platform.yaml` | K8s Secret | TLS only | ❌ |
| **mTLS + Metrics Auth** | `confluent_platform_mtls.yaml` | K8s Secret | mTLS | ❌ |
| **mTLS + DPIC** | `confluent_platform_dpic.yaml` | Vault DPIC | mTLS | ✅ |

## 🚀 Quick Start

### Prerequisites

```bash
# Required tools
kubectl version --client     # Kubernetes CLI
cfssl version                # CloudFlare SSL toolkit
helm version                 # Helm (for Vault)
gcloud auth list             # GCP authentication (for image pull)
```

### Mode 1: mTLS + SecretRef

```bash
# 1. Setup certificates and secrets
./setup.sh

# 2. Deploy Confluent Platform
kubectl apply -f manifests/confluent_platform.yaml

# 3. Wait for pods
kubectl wait --for=condition=ready pod -l app=kraftcontroller -n operator --timeout=300s
kubectl wait --for=condition=ready pod -l app=kafka -n operator --timeout=300s

# 4. Verify observer
kubectl logs kraftcontroller-0 -c observer -n operator
```

### Mode 2: mTLS + Metrics Auth

```bash
./setup.sh
kubectl apply -f manifests/confluent_platform_mtls.yaml
```

### Mode 3: mTLS + DPIC (Vault)

```bash
# 1. Setup certificates
./setup.sh

# 2. Install and configure Vault
./setup_vault.sh

# 3. Deploy with DPIC
kubectl apply -f manifests/confluent_platform_dpic.yaml
```

## 📜 Certificate Structure

### Generated Files

```
certs/
├── ca/
│   ├── ca.pem              # CA certificate
│   └── ca-key.pem          # CA private key
├── generated/
│   ├── kraft-server.pem    # KRaft server certificate
│   ├── kraft-server-key.pem
│   ├── kafka-server.pem    # Kafka server certificate
│   └── kafka-server-key.pem
└── server_configs/
    ├── ca-config.json      # CFSSL CA configuration
    ├── kraft-server-config.json
    └── kafka-server-config.json
```

### Kubernetes Secrets

| Secret | Contents | Used By |
|--------|----------|---------|
| `ca-pair-sslcerts` | CA cert + key | Managed certs |
| `tls-kraft` | fullchain.pem, privkey.pem, cacerts.pem | KRaftController |
| `tls-kafka` | fullchain.pem, privkey.pem, cacerts.pem | Kafka |
| `credential` | SASL credentials | Authentication |

### Vault Secrets (DPIC mode)

| Path | Keys |
|------|------|
| `/secret/tls-kraft` | cacerts, fullchain, privkey (base64) |
| `/secret/tls-kafka` | cacerts, fullchain, privkey (base64) |

## ⚙️ Observer Configuration Examples

### Basic mTLS Configuration

```yaml
spec:
  services:
    observer:
      image: us.gcr.io/cc-devel/confluent-operator-observer:latest
      authentication:
        type: mtls
      tls:
        secretRef: tls-kraft  # or tls-kafka for Kafka
```

### DPIC Configuration (Vault)

```yaml
spec:
  services:
    observer:
      image: us.gcr.io/cc-devel/confluent-operator-observer:latest
      authentication:
        type: mtls
      tls:
        directoryPathInContainer: /mnt/dpic/certs/tls-kraft
  podTemplate:
    annotations:
      vault.hashicorp.com/agent-inject: "true"
      vault.hashicorp.com/agent-inject-secret-cacerts.pem: "secret/tls-kraft"
      vault.hashicorp.com/agent-inject-template-cacerts.pem: |
        {{- with secret "secret/tls-kraft" -}}
        {{ .Data.cacerts | base64Decode }}
        {{- end -}}
```

### Advanced Configuration with Tuning

```yaml
spec:
  services:
    observer:
      image: us.gcr.io/cc-devel/confluent-operator-observer:latest
      logLevel: debug
      authentication:
        type: mtls
      tls:
        secretRef: tls-kraft
      readiness:
        maxLeoLag: 2000     # Allow higher lag during maintenance
      clients:
        jolokia:
          timeout: "15s"    # Longer timeout for slow networks
          maxRetries: 5
          retryBackoff: "200ms"
      containerOverrides:
        resources:
          requests:
            cpu: "20m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
        probe:
          startup:
            initialDelaySeconds: 30
            failureThreshold: 60
```

## 🔍 Verification Commands

### Check Pods and Containers

```bash
# List all pods
kubectl get pods -n operator

# Check observer container status
kubectl describe pod kraftcontroller-0 -n operator | grep -A 10 "observer"

# View observer logs
kubectl logs kraftcontroller-0 -c observer -n operator --tail=100
```

### Test Observer Endpoints

```bash
# Get pod name
POD=kraftcontroller-0

# Test health endpoint (from inside the cluster)
kubectl exec $POD -c observer -n operator -- \
  curl -sk https://localhost:7443/healthz | jq .

# Test readiness
kubectl exec $POD -c observer -n operator -- \
  curl -sk https://localhost:7443/readyz

# Test with mTLS (using mounted certs)
kubectl exec $POD -c observer -n operator -- \
  curl -sk \
    --cert /mnt/sslcerts/observer/fullchain.pem \
    --key /mnt/sslcerts/observer/privkey.pem \
    --cacert /mnt/sslcerts/observer/cacerts.pem \
    https://localhost:7443/healthz
```

### Verify Certificates

```bash
# Check secret contents
kubectl get secret tls-kraft -n operator -o jsonpath='{.data.fullchain\.pem}' | base64 -d | openssl x509 -text -noout

# Verify Vault secrets (DPIC mode)
kubectl exec vault-0 -n operator -- vault kv get /secret/tls-kraft

# Check certificate in pod
kubectl exec kraftcontroller-0 -c observer -n operator -- \
  cat /mnt/sslcerts/observer/fullchain.pem | openssl x509 -text -noout
```

## 🐛 Troubleshooting

### Observer Container Issues

| Issue | Symptoms | Solution |
|-------|----------|----------|
| **CrashLoopBackOff** | Pod restarts repeatedly | Check `kubectl logs <pod> -c observer` for errors |
| **TLS handshake failed** | Connection refused | Verify certs match and are valid |
| **Config parse error** | Observer won't start | Check ConfigMap for YAML syntax |
| **Jolokia unreachable** | Readiness fails | Main container not ready yet |

### Certificate Issues

```bash
# Verify certificate validity
openssl verify -CAfile certs/ca/ca.pem certs/generated/kraft-server.pem

# Check certificate dates
openssl x509 -in certs/generated/kraft-server.pem -noout -dates

# Verify secret has correct files
kubectl get secret tls-kraft -n operator -o jsonpath='{.data}' | jq 'keys'
```

### Vault DPIC Issues

```bash
# Check Vault pod status
kubectl get pods -n operator | grep vault

# Verify Vault is accessible
kubectl exec vault-0 -n operator -- vault status

# Check Vault agent logs in pod
kubectl logs kraftcontroller-0 -c vault-agent-init -n operator

# Verify injected files
kubectl exec kraftcontroller-0 -c observer -n operator -- ls -la /mnt/dpic/certs/tls-kraft/
```

## 🧹 Cleanup

### Basic Cleanup

```bash
# Remove Confluent Platform
kubectl delete -f manifests/confluent_platform.yaml

# Full cleanup
./teardown.sh
```

### With Vault

```bash
kubectl delete -f manifests/confluent_platform_dpic.yaml
./teardown_vault.sh
./teardown.sh
```

## 📚 Reference

### Certificate Configuration (CFSSL)

**ca-config.json:**
```json
{
  "signing": {
    "default": { "expiry": "8760h" },
    "profiles": {
      "server": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
```

### Vault Annotations Reference

| Annotation | Description |
|------------|-------------|
| `vault.hashicorp.com/agent-inject: "true"` | Enable Vault agent injection |
| `vault.hashicorp.com/role: "confluent-operator"` | Vault role for authentication |
| `vault.hashicorp.com/agent-inject-secret-<file>: "<path>"` | Inject secret at path |
| `vault.hashicorp.com/agent-inject-template-<file>` | Template for secret rendering |

### Observer Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 7080 | HTTP | Observer (no TLS) |
| 7443 | HTTPS | Observer (with TLS) |
| 7777 | HTTP/HTTPS | Jolokia (main container) |
| 9071 | - | Kafka internal |
| 9074 | - | KRaft controller |

---

*See [../README.md](../README.md) for general Observer Container documentation*
