# Host-based Routing with SASL/PLAIN and TLS

This example demonstrates a Gateway configuration with:
- **Authentication Mode**: Passthrough (client credentials forwarded to Kafka)
- **Routing Strategy**: Host-based routing (SNI routing)
- **Client TLS**: TLS enabled (one-way TLS)
- **Cluster TLS**: TLS enabled (one-way TLS)
- **Client Authentication**: SASL/PLAIN
- **Cluster Authentication**: SASL/PLAIN
- **External Access**: LoadBalancer

## Overview

In this scenario, the Gateway uses host-based routing where different hostnames/SNI (Server Name Indication) are used to route requests to different Kafka brokers. TLS encryption is enabled for both client-to-gateway and gateway-to-Kafka connections, while using SASL/PLAIN for authentication in passthrough mode.

## Deploy the Example

### Prerequisites

- Please ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites) for using the examples in this repo.
- You will need a Kafka cluster with SASL_SSL listener configured
- OpenSSL is required for certificate generation
- `keytool` command is required for managing keystore and certificates

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
### Step 2: Create Kubernetes secrets required for enabling TLS

#### Create Client to Gateway TLS Secret

- Please follow the steps in this [guide](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/gateway/certificates/README.md) to generate the TLS certificates and create the corresponding Kubernetes secret (`gateway-tls`) required by gateway.

#### Create Gateway to Kafka TLS Secret
- Modify the values of `truststore.jks` and `jksPassword.txt` in the below command appropriately.
   - `truststore.jks` should point to the JKS truststore containing the certificates of the backing Kafka cluster.
   - `jksPassword.txt` should contain the JKS password in the following format: `jksPassword=<password_for_jks>`.
   - More details available [here](https://docs.confluent.io/operator/current/co-network-encryption.html#provide-tls-keys-and-certificates-in-java-keystore-format)
```
kubectl create secret generic kafka-tls \
  --from-file=truststore.jks=/tmp/truststore.jks \
  --from-file=jksPassword.txt=/tmp/jksPassword.txt \
  -n confluent
```
### Step 3: Deploy gateway YAML

- Modify the `streamingDomains` section in the [gateway.yaml](./gateway.yaml) to point to your Kafka cluster SASL/SSL listener.
- Now deploy the gateway yaml.

```
kubectl apply -f gateway.yaml -n confluent
```

- Wait for the gateway pods to become READY
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

1. Create a truststore for client to gateway connection.
- Modify `storepass` value if required.
```
keytool -import \                                                  
  -file cacerts.pem \
  -alias gateway-ca \
  -keystore gateway.truststore.jks \
  -storepass changeit \
  -noprompt
```
2. Create a client configuration file (`client.properties`).
- Modify the `sasl.jaas.config` section with appropriate credentials.
- Configure the values of `ssl.truststore.location` and `ssl.truststore.password` based on the previous step.

```
sasl.mechanism=PLAIN
security.protocol=SASL_SSL
group.id=console-consumer-group
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
      username="alice" \
      password="alice-secret";

ssl.truststore.location=./gateway.truststore.jks
ssl.truststore.password=changeit
```

3. Test producing messages:
```
kafka-console-producer \
  --bootstrap-server gateway.example.com:9595 \
  --producer.config client.properties \
  --topic test-topic
```

4. Test consuming messages:
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
kubectl delete secret gateway-tls -n confluent
kubectl delete secret kafka-tls -n confluent
```
