# Authentication Swap - SASL/SCRAM to NONE with mTLS to Kafka

This example demonstrates a Gateway configuration with authentication swap, where clients connect with SASL/SCRAM-SHA-256 authentication and the Gateway connects to the Kafka cluster without authentication (NONE). The Gateway-to-Kafka connection is secured using mTLS (mutual TLS), requiring both a keystore and truststore.

**NOTE**:
- The client identity extracted from the client-to-gateway SASL/SCRAM authentication is not forwarded to the Kafka cluster since cluster authentication is NONE.
- `secretStore` configuration is not required in the route security section since there is no credential lookup needed for this authentication swap scenario.

## Configuration Overview

- **Authentication Mode**: Authentication Swap (credentials swapped by Gateway)
- **Routing Strategy**: Port-based routing
- **Client TLS**: None (PLAINTEXT)
- **Cluster TLS**: mTLS (mutual TLS with keystore and truststore)
- **Client Authentication**: SASL/SCRAM-SHA-256
- **Cluster Authentication**: NONE (no authentication)
- **External Access**: LoadBalancer

## Deploy the Example

### Prerequisites

- Please ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites) for using the examples in this repo.
- You will also require a Kafka cluster set up with a TLS listener configured for mTLS (no SASL authentication).

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

### Step 2: Create Gateway to Kafka mTLS Secret

- Create a Kubernetes secret containing the keystore and truststore for the Gateway-to-Kafka mTLS connection.
  - `keystore.jks` should contain the Gateway's client certificate and private key for mTLS authentication to the Kafka cluster.
  - `truststore.jks` should contain the CA certificates of the backing Kafka cluster.
  - `jksPassword.txt` should contain the JKS password in the following format: `jksPassword=<password_for_jks>`.
  - More details available [here](https://docs.confluent.io/operator/current/co-network-encryption.html#provide-tls-keys-and-certificates-in-java-keystore-format)
```
kubectl create secret generic kafka-tls \
  --from-file=keystore.jks=/tmp/keystore.jks \
  --from-file=truststore.jks=/tmp/truststore.jks \
  --from-file=jksPassword.txt=/tmp/jksPassword.txt \
  -n confluent
```

### Step 3: Setup SCRAM Admin Credentials

- Create Kubernetes secret with admin credentials for SCRAM credential management.
  - The Gateway uses these admin credentials to dynamically manage SCRAM credentials via the `alterScramCredentials` mechanism.
  - Please change the admin credentials appropriately based on your setup.
```
kubectl create secret generic scram-admin-credentials \
  --from-literal=username=admin-user \
  --from-literal=password=admin-password \
  -n confluent
```

### Step 4: Deploy gateway yaml

- Modify the `streamingDomains` section in the [gateway.yaml](./gateway.yaml) to point to your Kafka cluster TLS listener (without SASL authentication).
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

### Step 1: Register SCRAM Credentials

Before testing, register SCRAM credentials for the test user through the Gateway using admin credentials:

- Create an admin client configuration file (`admin-client.properties`):
```properties
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-256
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required \
  username="admin-user" \
  password="admin-password";
```

- Register SCRAM credentials for the test user:
```bash
kafka-configs \
  --bootstrap-server gateway.example.com:9595 \
  --command-config admin-client.properties \
  --alter \
  --add-config "SCRAM-SHA-256=[iterations=8192,password=alice-secret]" \
  --entity-type users \
  --entity-name alice
```

### Step 2: Create Client Configuration

Create a client configuration file (`client.properties`) with SCRAM credentials:

```properties
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-256
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required \
  username="alice" \
  password="alice-secret";
```

### Step 3: Test Producing Messages

```bash
kafka-console-producer \
  --bootstrap-server gateway.example.com:9595 \
  --producer.config client.properties \
  --topic test-topic
```

### Step 4: Test Consuming Messages

```bash
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
kubectl delete secret kafka-tls scram-admin-credentials -n confluent
```
