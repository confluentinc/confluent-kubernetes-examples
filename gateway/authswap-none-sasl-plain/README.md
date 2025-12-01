# Authentication Swap - NONE to SASL/PLAIN with PLAINTEXT

This example demonstrates a Gateway configuration with authentication swap, where clients connect without authentication (NONE) and the Gateway uses swapped credentials to connect to the Kafka cluster with SASL/PLAIN authentication.

**NOTE**: All unauthenticated clients are treated as anonymous users with the client ID `ANONYMOUS`. The swapped credentials corresponding to the `ANONYMOUS` principal must be configured in the specified secret store.

## Configuration Overview

- **Authentication Mode**: Authentication Swap (credentials swapped by Gateway)
- **Routing Strategy**: Port-based routing
- **Client TLS**: None (PLAINTEXT)
- **Cluster TLS**: None (PLAINTEXT)
- **Client Authentication**: NONE
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

- Create Kubernetes secret with user credentials for auth swap.
   - Since all unauthenticated clients are treated as `ANONYMOUS`, we need to configure swapped credentials for the `ANONYMOUS` user.
   - Please change the outgoing swapped credentials in the below command (`bob/bob-secret`) appropriately based on your Kafka cluster setup.
```
kubectl create secret generic file-store-noauth-credentials \
  --from-literal=ANONYMOUS="bob/bob-secret" \
  -n confluent
```

- Create Kubernetes secret for file store config
```
kubectl create secret generic file-store-config --from-literal=separator="/" -n confluent
```

### Step 3: Setup JAAS config

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
- Wait for the gateway pods to become `READY`
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

1. Test producing messages:
```
kafka-console-producer \
  --bootstrap-server gateway.example.com:9595 \
  --topic test-topic
```

2. Test consuming messages:
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

- Delete Kubernetes secrets
```
kubectl delete secret file-store-config file-store-noauth-credentials plain-jaas -n confluent
```
