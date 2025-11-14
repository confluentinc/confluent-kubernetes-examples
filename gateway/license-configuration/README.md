# Configuring Licenses for Confluent Gateway on Kubernetes

This example demonstrates how to configure and manage licenses for Confluent Gateway on Kubernetes, including the differences between trial mode and enterprise licensed modes.

## Overview

Confluent Gateway supports different deployment models with corresponding license types:

| Gateway Image                     | Required License Type    | Use Case                           |
|-----------------------------------|--------------------------|------------------------------------|
| `cpc-gateway`                     | CPC License              | For on-premises Kafka clusters     |
| `confluent-gateway-for-cloud`     | CC Gateway Addon License | For Confluent Cloud Kafka clusters |

> **Note:** You can configure license type based on your deployment target.
> 
> For hybrid deployments, you can provide multiple license tokens.

---

## License Modes

### 🏢 Enterprise Mode for Gateway with CPC Deployments
- **License required:** Valid CPC license token
- **Capability:** Supports only CPC streaming domains
- **Purpose:** Gateway forwarding to self-managed Kafka clusters
- **Duration:** As specified in the license claim
- **Image:** Use `confluentinc/cpc-gateway`

### ☁️ Enterprise Mode for Gateway with Confluent-Cloud Deployments
- **License required:** Valid CC Gateway Addon license token
- **Capability:** Supports only ConfluentCloud streaming domains
- **Purpose:** Gateway forwarding to Confluent Cloud clusters
- **Duration:** As specified in the license claim
- **Image:** Use `confluentinc/confluent-gateway-for-cloud`

### 🆓 Trial Mode (Default)
- **No license required** - Gateway starts automatically in trial mode
- **Limitation:** Maximum of 4 routes can be configured
- **Purpose:** Evaluation and testing

---

## Prerequisites

- Please ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites) for using the examples in this repo.
- You will also require a Kafka cluster set up with a PLAINTEXT listener configured.
- Valid Confluent license token for enterprise mode

---

## Quick Start

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
No additional steps required - Gateway will start in trial mode automatically.

**Enterprise Mode (unlimited routes):**

To use enterprise mode, create a Kubernetes secret with your valid license token(s).

**Option A: Create license secret from file**
```shell
# Create licenses.txt with your token(s) - one per line
echo "your-license-token-here" > licenses.txt
# echo "your-second-license-token-here" >> licenses.txt  # For multiple tokens

# Create secret from file
kubectl create secret generic confluent-gateway-licenses \
  --from-file=licenses.txt=licenses.txt \
  -n confluent

# Verify secret
kubectl get secret confluent-gateway-licenses -n confluent
```

**Option B: Create license secret directly**
```shell
kubectl create secret generic confluent-gateway-licenses \
  --from-literal=licenses.txt='your-license-token-here' \
  -n confluent
```

> **Note:** Contact Confluent to obtain a valid license token for production use.

### Step 3: Deploy Gateway

**Update Configuration:**
Modify the `streamingDomains` section in [gateway.yaml](./gateway.yaml) to point to your Kafka cluster:

```yaml
streamingDomains:
  - name: sample-domain
    kafka:
      bootstrapServers: 
        - id: plaintext-sasl-plain
          endpoint: your-kafka-bootstrap.server:9092  # Update this
```

**Deploy Gateway:**
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

---

## Example Configuration

This example configures **4 passthrough routes** to demonstrate the trial mode limit and port-based routing strategy.

### Route Configuration

| Route Name          | Gateway Port | Purpose                          |
|---------------------|--------------|----------------------------------|
| passthrough-route   | 9595         | Primary route (used in examples) |
| passthrough-route-2 | 9596         | Additional route #2              |
| passthrough-route-3 | 9597         | Additional route #3              |
| passthrough-route-4 | 9598         | Additional route #4              |

**Route Properties:**
- **Authentication:** Passthrough (authentication handled by Kafka broker)
- **Broker Identification:** Port-based strategy
- **Streaming Domain:** sample-domain → Your Kafka cluster
- **External Access:** LoadBalancer service type

---

## Using the Gateway

### Download Kafka Clients

Download Kafka binaries from [Apache Kafka Downloads](https://kafka.apache.org/downloads) to access console clients.

### Get Gateway LoadBalancer Address

```shell
# Get the external address
kubectl get svc confluent-gateway-lb -n confluent

# Wait for EXTERNAL-IP to be assigned (may take a few minutes)
# Example output:
# NAME                    TYPE           EXTERNAL-IP       PORT(S)
# confluent-gateway-lb    LoadBalancer   a1b2c3.elb...     9595:31234/TCP,...
```

Use the `EXTERNAL-IP` value as your bootstrap server address.

### Console Client Examples

All examples use the primary route at the gateway LoadBalancer address.

**Create a Topic**
```bash
kafka-topics --bootstrap-server <GATEWAY-EXTERNAL-IP>:9595 \
  --create --topic test-topic \
  --partitions 1 \
  --replication-factor 1
```

**Produce Messages**
```bash
kafka-console-producer --bootstrap-server <GATEWAY-EXTERNAL-IP>:9595 \
  --topic test-topic
```

**Consume Messages**
```bash
kafka-console-consumer --bootstrap-server <GATEWAY-EXTERNAL-IP>:9595 \
  --topic test-topic \
  --from-beginning
```

**Using Alternative Routes**

You can connect to any of the 4 configured routes:
```bash
# Connect via route 2 (port 9596)
kafka-console-producer --bootstrap-server <GATEWAY-EXTERNAL-IP>:9596 \
  --topic test-topic

# Connect via route 3 (port 9597)
kafka-console-consumer --bootstrap-server <GATEWAY-EXTERNAL-IP>:9597 \
  --topic test-topic
```

---

## Exposed Ports

The Gateway LoadBalancer service exposes the following ports:

| Port  | Service                      | Description                                      |
|-------|------------------------------|--------------------------------------------------|
| 9595  | Gateway - passthrough-route  | Primary Gateway route (used in examples)         |
| 9596  | Gateway - passthrough-route-2| Additional Gateway route #2                      |
| 9597  | Gateway - passthrough-route-3| Additional Gateway route #3                      |
| 9598  | Gateway - passthrough-route-4| Additional Gateway route #4                      |
| 9190  | Gateway - Admin/Metrics      | Gateway management and monitoring endpoint       |

---

## Monitoring and Verification

### Check Gateway Status

```shell
# Get Gateway resource status
kubectl describe gateway confluent-gateway -n confluent

# Get pod status
kubectl get pods -l app=confluent-gateway -n confluent
```

### Check Gateway Metrics

The Gateway exposes metrics at the admin endpoint:
```bash
# Port-forward to access metrics locally
kubectl port-forward svc/confluent-gateway-lb 9190:9190 -n confluent

# In another terminal, access metrics
curl http://localhost:9190/metrics
```

### View Gateway Logs
```bash
# View Gateway logs
kubectl logs -l app=confluent-gateway -n confluent

# Follow Gateway logs in real-time
kubectl logs -f -l app=confluent-gateway -n confluent

# View logs from specific pod
kubectl logs <gateway-pod-name> -n confluent
```

### Verify License Status

Check Gateway logs for license information:
```bash
kubectl logs -l app=confluent-gateway -n confluent | grep -i license
```

**Enterprise Mode Output:**
```
===> Using GATEWAY_LICENSES environment variable
===> Using licenses file at /etc/gateway/licenses.txt
```

**Trial Mode Output:**
```
===> Checking Licenses Text...
===> Starting Gateway in trial mode (max 4 routes)
```

---

## Configuration Details

### License Configuration Methods

The Gateway on Kubernetes is configured using environment variables in the Gateway custom resource.

**Enterprise Mode - Using Environment Variables with Secret Reference:**

```yaml
spec:
  replicas: 1
  podTemplate:
    envVars:
      - name: GATEWAY_LICENSES
        valueFrom:
          secretKeyRef:
            name: confluent-gateway-licenses
            key: licenses.txt
```

This method:
- References the Kubernetes secret created in Step 2
- Injects the license token(s) as the `GATEWAY_LICENSES` environment variable
- Supports multiple license tokens (one per line in the secret)

**Trial Mode (No Configuration):**

Simply omit the `envVars` configuration for `GATEWAY_LICENSES` to run in trial mode with a 4-route limit.

### Gateway Configuration Options

| Configuration Method      | Description                                          |
|---------------------------|------------------------------------------------------|
| Environment Variable with Secret | Recommended: Inject license via `GATEWAY_LICENSES` envVar from Kubernetes secret |
| Trial Mode (no config)    | Omit `GATEWAY_LICENSES` envVar for automatic trial mode with 4-route limit |

---

## Cleanup

To remove all resources created by this example:

```shell
# Delete Gateway
kubectl delete -f gateway.yaml -n confluent

# Delete license secret if created
kubectl delete secret confluent-gateway-licenses -n confluent

# (Optional) Uninstall CFK operator
helm uninstall confluent-operator -n confluent

# (Optional) Delete namespace
kubectl delete namespace confluent
```

---

## Troubleshooting

### Issue: Gateway fails to start with "route limit exceeded"

**Cause:** You're in trial mode and have configured more than 4 routes.

**Solution:**
- Reduce the number of routes in `gateway.yaml` to 4 or fewer, OR
- Create a license secret with a valid license token
- Apply the updated configuration: `kubectl apply -f gateway.yaml -n confluent`

### Issue: License token expired

**Cause:** The license token has passed its expiration date.

**Solution:**
- Contact Confluent to obtain a renewed license token
- Update the license secret:
  ```shell
  kubectl delete secret confluent-gateway-licenses -n confluent
  kubectl create secret generic confluent-gateway-licenses \
    --from-file=licenses.txt=licenses.txt -n confluent
  ```
- Restart Gateway pods:
  ```shell
  kubectl rollout restart statefulset/confluent-gateway -n confluent
  ```

### Issue: Wrong license type for deployment

**Cause:** Using CPC license for CC Gateway Addon or vice versa.

**Solution:**
- For on-premises Kafka: Use `confluentinc/cpc-gateway` image with CPC license
- For Confluent Cloud: Use `confluentinc/confluent-gateway-for-cloud` image with Cloud license
- Update the `image` field in `gateway.yaml`

### Issue: Gateway pods not starting

**Cause:** Various reasons including configuration errors, resource constraints, or invalid secrets.

**Solution:**
```shell
# Check pod events
kubectl describe pod -l app=confluent-gateway -n confluent

# Check pod logs
kubectl logs -l app=confluent-gateway -n confluent

# Check Gateway CR status
kubectl describe gateway confluent-gateway -n confluent
```

### Issue: Cannot connect to Gateway LoadBalancer

**Cause:** LoadBalancer service has not been assigned an external IP.

**Solution:**
- Verify your Kubernetes cluster supports LoadBalancer services
- Check service status: `kubectl get svc confluent-gateway-lb -n confluent`
- Consider using NodePort or port-forwarding for testing:
  ```shell
  kubectl port-forward svc/confluent-gateway-lb 9595:9595 -n confluent
  ```

---

## Notes

- For production deployments, always use licensed mode and secure credential management
- Store license tokens securely using Kubernetes secrets
- Monitor Gateway metrics and logs for operational insights
- Ensure your Kafka cluster is accessible from the Gateway pods
- Consider using network policies to secure Gateway traffic

---
