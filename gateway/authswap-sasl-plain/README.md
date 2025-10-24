# Authentication Swap - SASL/PLAIN to SASL/PLAIN with PLAINTEXT

This example demonstrates a Gateway configuration with authentication swap where clients authenticate with one set of credentials (alice/alice-secret) and the Gateway uses swapped credentials (bob/bob-secret) to connect to the Kafka cluster.

## Configuration Overview

- **Authentication Mode**: Authentication Swap (credentials swapped by Gateway)
- **Routing Strategy**: Port-based routing
- **Client TLS**: None (PLAINTEXT)
- **Cluster TLS**: None (PLAINTEXT)
- **Client Authentication**: SASL/PLAIN
- **Cluster Authentication**: SASL/PLAIN (swapped credentials)
- **External Access**: LoadBalancer

## Deploy the Example

### Prerequisites

- Please ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites) for using the examples in this repo.
- You will also require a Kafka cluster set up with a SASL/PLAIN listener configured.

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

### Step 2: Setup File Secret Store

- Create Kubernetes secret for config
```
kubectl create secret generic file-store-config --from-literal=separator="/" -n confluent
```

- Create Kubernetes secret with user credentials for auth swap.
   - For the purpose of this example, we will be swapping incoming credentials for user `alice` with credentials for user `bob`.
   - Change the outgoing authentication swap credentials in the below command `bob/bob-secret` appropriately based on your Kafka cluster setup.
```
kubectl create secret generic file-store-client-credentials \
  --from-literal=alice="bob/bob-secret" \
  -n confluent
```

### Step 3: Setup JAAS configs

- Create JAAS config secret for client to gateway connection.
```
kubectl create secret generic client-jaas-passthrough \
  --from-literal=plain-jaas.conf='org.apache.kafka.common.security.plain.PlainLoginModule required user_alice="alice-secret" user_admin="admin-secret";' \
  -n confluent
```

- Create JAAS template secret for gateway to Kafka cluster connection.
```
kubectl create secret generic plain-jaas \
  --from-literal=plain-jaas.conf='org.apache.kafka.common.security.plain.PlainLoginModule required username="%s" password="%s";' \
  -n confluent
```

### Step 4: Deploy gateway yaml

- Modify the `streamingDomains` section in the [gateway.yaml](./gateway.yaml) to point to your Kafka cluster SASL/PLAIN listener.
- Now deploy the gateway yaml.
```
kubectl apply -f gateway.yaml -n confluent
```
- Wait for the gateway pods to become READY
```
kubectl wait --for=condition=Ready pod -l app=confluent-gateway --timeout=600s -n confluent
```

### Step 5: Verify Deployment

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
kubectl delete secret file-store-config file-store-client-credentials client-jaas-passthrough plain-jaas -n confluent
```