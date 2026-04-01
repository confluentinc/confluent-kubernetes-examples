# Observer Container Playbook

This playbook provides comprehensive examples for deploying the **Observer Container** - a sidecar for health monitoring in Confluent Platform components (Kafka and KRaftController).

## 📋 Overview

The Observer Container is a lightweight sidecar that:
- Provides **enhanced health probes** (startup, liveness, readiness)
- Validates **KRaft controller LEO lag** across the cluster
- Checks **Kafka broker under-replicated partitions (URP)**
- Supports **mTLS authentication** for secure probe communication
- Integrates with **Vault** for certificate management (DPIC)

```
┌──────────────────────────────────────────────────────────────────────┐
│                          Kubernetes Pod                              │
│  ┌─────────────────────┐    ┌──────────────────────────────────────┐ │
│  │   Main Container    │    │        Observer Container            │ │
│  │ (Kafka/KRaft)       │    │                                      │ │
│  │                     │◄───│  ┌──────────────┐                    │ │
│  │  ┌─────────────┐    │    │  │ HTTP Server  │◄──── Kubelet       │ │
│  │  │   Jolokia   │────┼───►│  │ /readyz      │      Probes        │ │
│  │  │   :7777     │    │    │  │ /livez       │                    │ │
│  │  └─────────────┘    │    │  │ /startupz    │                    │ │
│  │                     │    │  │ /healthz     │                    │ │
│  └─────────────────────┘    │  └──────────────┘                    │ │
│                             └──────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

## 📁 Directory Structure

```
observer-container/
├── README.md                    # This file
├── plaintext/                   # No TLS configuration
│   └── confluent_platform.yaml  # Basic plaintext deployment
└── tls/                         # TLS configurations
    ├── README.md                # Detailed TLS documentation
    ├── setup.sh                 # Certificate & secret setup
    ├── teardown.sh              # Cleanup script
    ├── setup_vault.sh           # Vault installation & config
    ├── teardown_vault.sh        # Vault cleanup
    ├── certs/                   # Generated certificates
    │   ├── ca/                  # CA certificates
    │   ├── generated/           # Component certificates
    │   └── server_configs/      # CFSSL configuration
    ├── creds/                   # SASL credentials
    └── manifests/               # Kubernetes manifests
        ├── confluent_platform.yaml       # mTLS + SecretRef
        ├── confluent_platform_mtls.yaml  # mTLS + Metrics Auth
        └── confluent_platform_dpic.yaml  # mTLS + Vault DPIC
```

## 🚀 Quick Start

### Option 1: Plaintext (No TLS) - Development Only

```bash
cd plaintext/
kubectl apply -f confluent_platform.yaml
```

### Option 2: mTLS with Kubernetes Secrets

```bash
cd tls/
./setup.sh
kubectl apply -f manifests/confluent_platform.yaml
```

### Option 3: mTLS with Vault DPIC

```bash
cd tls/
./setup.sh
./setup_vault.sh
kubectl apply -f manifests/confluent_platform_dpic.yaml
```

## ⚙️ Observer Configuration Reference

### CRD Configuration

```yaml
spec:
  services:
    observer:
      # Observer container image
      image: "confluentinc/confluent-operator-observer:latest"
      
      # Authentication for observer endpoints
      authentication:
        type: mtls  # or omit for no auth
      
      # TLS configuration
      tls:
        secretRef: tls-secret  # Kubernetes secret with certificates
      
      # Logging level (debug, info, warn, error)
      logLevel: "info"
      
      # Readiness check thresholds
      readiness:
        maxLeoLag: 1000   # KRaft: max LEO lag before not-ready
        maxURP: 0         # Kafka: max URPs before not-ready
      
      # Jolokia client settings
      clients:
        jolokia:
          timeout: "10s"
          maxRetries: 3
          retryBackoff: "100ms"
      
      # Multi-cluster peer endpoints (advanced)
      cluster:
        peerEndpoints:
          - "https://controller-0.cluster-b:7777/jolokia"
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `OBSERVER_PROTOCOL` | HTTP/HTTPS | Auto-detected |
| `OBSERVER_PORT` | Server port | 7080 (HTTP) / 7443 (HTTPS) |
| `OBSERVER_CA_FILE` | CA cert path | From TLS config |
| `OBSERVER_CERT_FILE` | Client cert | From TLS config |
| `OBSERVER_KEY_FILE` | Client key | From TLS config |

## 🔍 Health Check Endpoints

| Endpoint | Purpose | Used By |
|----------|---------|---------|
| `/startupz` | Basic JVM/process check | Startup probe |
| `/livez` | Port connectivity check | Liveness probe |
| `/readyz` | Full health validation | Readiness probe |
| `/healthz` | Diagnostic dashboard | Debugging |

### Health Check Logic

**KRaft Controller:**
```
Startup:  Jolokia connectivity OK
Liveness: Controller port 9074 reachable
Readiness: LEO lag ≤ maxLeoLag (default: 1000)
```

**Kafka Broker:**
```
Startup:  Jolokia connectivity OK
Liveness: Internal port 9071 reachable
Readiness: URP count ≤ maxURP (default: 0)
```

## 🔐 Security Configurations

| Mode | Observer Auth | Metrics Auth | Cert Source |
|------|--------------|--------------|-------------|
| Plaintext | None | None | N/A |
| TLS + SecretRef | mTLS | TLS | K8s Secret |
| mTLS + SecretRef | mTLS | mTLS | K8s Secret |
| mTLS + DPIC | mTLS | mTLS | Vault |

## 🐛 Troubleshooting

### Check Observer Container Status

```bash
# View observer logs
kubectl logs <pod> -c observer -n operator

# Check observer endpoints
kubectl exec <pod> -c observer -n operator -- \
  curl -k https://localhost:7443/healthz
```

### Common Issues

| Symptom | Cause | Solution |
|---------|-------|----------|
| Observer CrashLoopBackOff | Missing certificates | Verify TLS secrets exist |
| Readiness always false | High LEO lag | Check controller sync |
| Readiness always false | URPs present | Check broker replication |
| mTLS handshake failure | Cert mismatch | Regenerate certificates |
| Vault injection failing | DPIC path wrong | Check Vault annotations |

### Debug Commands

```bash
# Check certificate secrets
kubectl get secrets -n operator | grep tls

# Verify Vault secrets (DPIC mode)
kubectl exec vault-0 -n operator -- vault kv get /secret/tls-kraft

# Check observer config
kubectl get cm <component>-observer-config -n operator -o yaml

# Test Jolokia connectivity from observer
kubectl exec <pod> -c observer -n operator -- \
  curl -k https://localhost:7777/jolokia/read/java.lang:type=Runtime/Uptime
```

## 📊 Metrics & Monitoring

The `/healthz` endpoint provides diagnostic information:

```json
{
  "status": "healthy",
  "component": "kafka",
  "checks": {
    "liveness": { "status": "healthy", "port": 9071 },
    "readiness": { "status": "healthy", "urp": 0 }
  },
  "uptime": "1h23m",
  "history": [
    { "time": "2025-01-01T12:00:00Z", "ready": true, "alive": true }
  ]
}
```

## 📚 Additional Resources

- [Observer Container Technical README](../../observer-container/README.md)
- [CFK Documentation](https://docs.confluent.io/operator/current/overview.html)
- [Kubernetes Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)

## 🔄 Version Compatibility

| Observer Version | CFK Version | CP Version |
|-----------------|-------------|------------|
| v0.1.0+ | 2.9+ | 7.7+ |

---

*For detailed TLS configuration options, see [tls/README.md](tls/README.md)*

