# Configuring Licenses for Confluent Gateway on Kubernetes

Deploy Confluent Gateway on Kubernetes with license management for trial and enterprise modes.

## License Modes

| Mode | License Required | Route Limit | Image                                                       |
|------|------------------|-------------|-------------------------------------------------------------|
| Trial | No | 4 routes max | `confluentinc/cpc-gateway` or `confluentinc/confluent-gateway-for-cloud` |
| Enterprise (CPC) | Yes | Unlimited | `confluentinc/cpc-gateway`                                               |
| Enterprise (Cloud) | Yes | Unlimited | `confluentinc/confluent-gateway-for-cloud`                               |

This example demonstrates a Gateway configuration with:
- **License**: Confluent Platform License configured
- **Routing Strategy**: Port-based routing
- **External Access**: LoadBalancer

---

## Prerequisites

- Please ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites) for using the examples in this repo.
- You will also require a Kafka cluster set up with a PLAINTEXT listener configured.

## Quickstart
### Step 1: Install CFK Operator

```shell
# Add Confluent Helm repo
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

# Create namespace
kubectl create namespace confluent

# Install operator
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes -n confluent

# Verify installation
kubectl get pods -n confluent
```

### Step 2: Configure License

**Trial Mode (4 routes max):**
No additional steps required.

**Enterprise Mode (unlimited routes):**

```shell
# Create license secret
kubectl create secret generic confluent-gateway-licenses \
 --from-literal=licenses.txt=<your_license_key> \
 -n confluent
 
# Verify secret
kubectl get secret confluent-gateway-licenses -n confluent
```

### Step 3: Deploy gateway yaml

- Modify the `streamingDomains` section in the [gateway.yaml](./gateway.yaml) to point to your Kafka cluster PLAINTEXT listener.
- Now deploy the gateway yaml.
```shell
# Apply gateway configuration
kubectl apply -f gateway.yaml -n confluent

# Wait for gateway pods to be READY
kubectl wait --for=condition=Ready pod -l app=confluent-gateway --timeout=600s -n confluent

# Verify Deployment
kubectl get pods -n confluent
kubectl get gateway -n confluent
kubectl get svc -n confluent
```

### Step 4: Verify License Status

```shell
# Check license mode
kubectl logs -l app=confluent-gateway -n confluent | grep -i license
```

**Trial mode output:**
```
Starting Gateway in trial mode
```

**Enterprise mode output:**
```
Using GATEWAY_LICENSES environment variable
Using licenses file at /etc/gateway/licenses.txt
```

## Testing the Configuration

1. Create a topic `test-topic`:
```shell
kafka-topics \
  --bootstrap-server gateway.example.com:9595 \
  --create \
  --topic test-topic \
  --partitions 1 \
  --replication-factor 1
```

2. Test producing messages:
```
kafka-console-producer \
  --bootstrap-server gateway.example.com:9595 \
  --topic test-topic
```

3. Test consuming messages:
```
kafka-console-consumer \
  --bootstrap-server gateway.example.com:9595 \
  --topic test-topic \
  --from-beginning
```

## Clean Up

To remove all resources created by this example:

- Delete Gateway
```
kubectl delete -f gateway.yaml -n confluent
```