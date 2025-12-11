# Authentication Swap - SASL/PLAIN to NONE with PLAINTEXT

This example demonstrates a Gateway configuration with authentication swap, where clients connect with SASL/PLAIN authentication and the Gateway connects to the Kafka cluster without authentication (NONE).

**NOTE**:
- The client ID extracted from the client-to-gateway SASL/PLAIN authentication is ignored.
- Additionally, `secretStore` configuration is not allowed in the route security section since there is no secret store lookup required for this authentication swap scenario.

## Configuration Overview

- **Authentication Mode**: Authentication Swap (credentials swapped by Gateway)
- **Routing Strategy**: Port-based routing
- **Client TLS**: None (PLAINTEXT)
- **Cluster TLS**: None (PLAINTEXT)
- **Client Authentication**: SASL/PLAIN
- **Cluster Authentication**: NONE (no authentication)
- **External Access**: LoadBalancer

## Deploy the Example

### Prerequisites

- Please ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites) for using the examples in this repo.
- You will also require a Kafka cluster set up with a PLAINTEXT (no authentication) listener configured.

### Step 1: Deploy the Confluent for Kubernetes Operator

- Add the Confluent Helm repository
```
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
```
- Create the `confluent` namespace in the Kubernetes cluster
```
kubectl create namespace confluent
```
- Install the CFK operator
```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes -n confluent
```
- Check that the `confluent-operator` pod comes up and is running:
```
kubectl get pods -n confluent
```

### Step 2: Setup JAAS config for client authentication

- Create JAAS config secret for client to gateway connection.
```
kubectl create secret generic client-jaas-passthrough \
  --from-literal=plain-jaas.conf='org.apache.kafka.common.security.plain.PlainLoginModule required user_alice="alice-secret";' \
  -n confluent
```

### Step 3: Deploy gateway yaml

- Modify the `streamingDomains` section in the [gateway.yaml](./gateway.yaml) to point to your Kafka cluster PLAINTEXT listener (without authentication).
- Now deploy the gateway yaml.
```
kubectl apply -f gateway.yaml -n confluent
```
- Wait for the gateway pods to become `READY`
```
kubectl wait --for=condition=Ready pod -l app=confluent-gateway --timeout=600s -n confluent
```

### Step 4: Verify Deployment

- Check all components are running:
```
kubectl get pods -n confluent
kubectl get gateway -n confluent
kubectl get svc -n confluent
```

## Testing the Configuration

1. Create a client configuration file (`client.properties`) with incoming credentials for authentication swap.
```
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
  username="alice" \
  password="alice-secret";
```

2. Test producing messages:
```
kafka-console-producer \
  --bootstrap-server gateway.example.com:9595 \
  --producer.config client.properties \
  --topic test-topic
```

3. Test consuming messages:
```
kafka-console-consumer \
  --bootstrap-server gateway.example.com:9595 \
  --consumer.config client.properties \
  --topic test-topic \
  --from-beginning
```

## Clean Up

To remove all resources created by this example:

- Delete Gateway
```
kubectl delete -f gateway.yaml -n confluent
```

- Delete Kubernetes secrets
```
kubectl delete secret client-jaas-passthrough -n confluent
```
