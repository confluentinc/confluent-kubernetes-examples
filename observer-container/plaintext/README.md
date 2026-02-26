# Observer Container - Plaintext Configuration

This directory contains a minimal plaintext (no TLS) configuration for testing the Observer Container.

> ⚠️ **Warning**: This configuration is for **development/testing only**. Do not use in production.

## Quick Start

```bash
# Create namespace
kubectl create ns confluent

# Deploy
kubectl apply -f confluent_platform.yaml

# Check status
kubectl get pods -n confluent

# View observer logs
kubectl logs kraftcontroller-0 -c observer -n confluent
```

## Configuration

The plaintext configuration:
- No TLS encryption
- No authentication for observer endpoints
- HTTP on port 7080

```yaml
spec:
  services:
    observer:
      image: us.gcr.io/cc-devel/confluent-observer-container:latest
      # No authentication or TLS configuration
```

## Testing Observer Endpoints

```bash
# Test health endpoint
kubectl exec kraftcontroller-0 -c observer -n confluent -- \
  curl -s http://localhost:7080/healthz | jq .

# Test readiness
kubectl exec kraftcontroller-0 -c observer -n confluent -- \
  curl -s http://localhost:7080/readyz

# Test liveness
kubectl exec kraftcontroller-0 -c observer -n confluent -- \
  curl -s http://localhost:7080/livez
```

## Cleanup

```bash
kubectl delete -f confluent_platform.yaml
kubectl delete ns confluent
```

## Next Steps

For production deployments, use one of the TLS configurations in the `../tls/` directory.

