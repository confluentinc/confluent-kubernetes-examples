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
`````
kubectl get pods -n confluent
```

### Step 2: Generate TLS Certificates

- Create certificates for TLS encryption. This example uses JKS format.

```bash
# Run the certificate generation script
./create-certs.sh

# This will create:
# - CA certificate and key
# - Server certificates for Gateway
# - Client truststore and keystore in JKS format
# - Kubernetes secrets with the certificates
```

The script creates the following certificate structure:
- **CA Certificate**: Self-signed root CA for this example
- **Gateway Server Certificate**: With SANs for all broker hostnames
- **JKS Keystores**: For Java client compatibility

### Step 3: Create Authentication Secrets

Create SASL/PLAIN authentication credentials:

```bash
# Create SASL credentials secret
kubectl create secret generic kafka-sasl-jaas -n confluent \
  --from-literal=plain.txt="username=kafka\npassword=kafka-secret" \
  --from-literal=plain-users.json='{"kafka":"kafka-secret","client":"client-secret"}'
```

### Step 4: Deploy the Gateway

Modify the `gateway.yaml` file to point to your Kafka cluster's SASL_SSL endpoint:

```bash
# Edit gateway.yaml and update:
# - streamingDomains.kafkaCluster.bootstrapServers endpoint
# - Your actual Kafka broker hostnames

# Deploy the Gateway
kubectl apply -f gateway.yaml -n confluent

# Wait for Gateway to be ready
kubectl wait --for=condition=Ready pod -l app=confluent-gateway --timeout=600s -n confluent
```

### Step 5: Verify Deployment

Check all components are running:

```bash
kubectl get pods -n confluent
kubectl get gateway -n confluent
kubectl get svc -n confluent
kubectl get secrets -n confluent | grep -E "(tls|sasl)"
```

## Testing the Configuration

### Option 1: Using External LoadBalancer

If your cluster supports LoadBalancer services:

```bash
# Get the LoadBalancer external IP/hostname
kubectl get svc confluent-gateway-lb -n confluent

# Update your /etc/hosts or DNS to point broker hostnames to the LoadBalancer IP:
# <LB-IP> broker0.gateway.example.com
# <LB-IP> broker1.gateway.example.com
# <LB-IP> broker2.gateway.example.com
# <LB-IP> gateway.example.com
```

### Option 2: Using Port Forwarding

For local testing:

```bash
# Port-forward the Gateway service
kubectl port-forward svc/confluent-gateway 9092:9092 -n confluent

# Add to /etc/hosts:
# 127.0.0.1 broker0.gateway.example.com
# 127.0.0.1 broker1.gateway.example.com
# 127.0.0.1 broker2.gateway.example.com
# 127.0.0.1 gateway.example.com
```

### Client Configuration

Create a client configuration file (`client.properties`):

```properties
bootstrap.servers=gateway.example.com:9092
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
  username="kafka" \
  password="kafka-secret";

# TLS Configuration
ssl.truststore.location=/path/to/client.truststore.jks
ssl.truststore.password=mystorepassword
```

### Test Commands

```bash
# List topics
kafka-topics --bootstrap-server gateway.example.com:9092 \
  --command-config client.properties \
  --list

# Create a topic
kafka-topics --bootstrap-server gateway.example.com:9092 \
  --command-config client.properties \
  --create --topic test-topic \
  --partitions 3 --replication-factor 1

# Produce messages
kafka-console-producer \
  --bootstrap-server gateway.example.com:9092 \
  --producer.config client.properties \
  --topic test-topic

# Consume messages
kafka-console-consumer \
  --bootstrap-server gateway.example.com:9092 \
  --consumer.config client.properties \
  --topic test-topic \
  --from-beginning
```

## Configuration Details

### Host-based Routing

The Gateway uses SNI (Server Name Indication) to route requests to specific Kafka brokers:

- Client connects to `broker0.gateway.example.com` → Routes to Kafka broker 0
- Client connects to `broker1.gateway.example.com` → Routes to Kafka broker 1
- Client connects to `broker2.gateway.example.com` → Routes to Kafka broker 2

The bootstrap connection uses `gateway.example.com` which returns the per-broker hostnames in metadata.

### TLS Configuration

**Client-to-Gateway TLS:**
- One-way TLS (server authentication only)
- Gateway presents server certificate
- Clients validate using truststore

**Gateway-to-Kafka TLS:**
- One-way TLS to Kafka cluster
- Gateway validates Kafka certificates
- Uses JKS format for Java compatibility

### SASL/PLAIN Passthrough

- Client credentials are passed through unchanged
- Gateway does not perform authentication itself
- Kafka cluster validates the credentials

## Troubleshooting

### Common Issues

1. **TLS Handshake Failed**
   ```bash
   # Check certificate validity
   openssl s_client -connect gateway.example.com:9092 -servername gateway.example.com
   
   # Verify certificate SANs
   kubectl get secret gateway-tls -n confluent -o jsonpath='{.data.tls\.crt}' | \
     base64 -d | openssl x509 -text -noout | grep -A1 "Subject Alternative Name"
   ```

2. **Hostname Resolution Issues**
   ```bash
   # Verify DNS/hosts file entries
   nslookup broker0.gateway.example.com
   ping gateway.example.com
   
   # Check Gateway service endpoints
   kubectl get endpoints confluent-gateway -n confluent
   ```

3. **Authentication Failed**
   ```bash
   # Check Gateway logs
   kubectl logs -l app=confluent-gateway -n confluent --tail=50
   
   # Verify SASL credentials
   kubectl get secret kafka-sasl-jaas -n confluent -o yaml
   ```

4. **Routing Not Working**
   ```bash
   # Check Gateway configuration
   kubectl get gateway confluent-gateway -n confluent -o yaml
   
   # Verify SNI routing configuration
   kubectl describe gateway confluent-gateway -n confluent
   ```

### Debug Commands

```bash
# View Gateway status
kubectl get gateway confluent-gateway -n confluent -o yaml

# Check Gateway logs
kubectl logs -f deployment/confluent-gateway -n confluent

# Test TLS connectivity
openssl s_client -connect gateway.example.com:9092 \
  -servername broker0.gateway.example.com -showcerts

# Verify certificate secret
kubectl describe secret gateway-tls -n confluent
kubectl describe secret kafka-tls -n confluent

# Check SASL secret
kubectl get secret kafka-sasl-jaas -n confluent -o jsonpath='{.data.plain\.txt}' | base64 -d
```

## Security Considerations

1. **Certificate Management**
   - Use proper CA-signed certificates in production
   - Implement certificate rotation policies
   - Store certificates securely

2. **Network Security**
   - Restrict network access using NetworkPolicies
   - Use private endpoints where possible
   - Enable audit logging

3. **Authentication**
   - Use strong passwords
   - Consider using mTLS or OAuth instead of PLAIN in production
   - Implement credential rotation

4. **Monitoring**
   - Monitor TLS certificate expiry
   - Track authentication failures
   - Alert on routing anomalies

## Clean Up

To remove all resources:

```bash
# Delete Gateway
kubectl delete -f gateway.yaml -n confluent

# Delete secrets
kubectl delete secret gateway-tls kafka-tls kafka-sasl-jaas -n confluent

# Remove generated certificates (local)
rm -rf generated/
```

## Additional Notes

- This example uses self-signed certificates suitable for testing
- For production, use certificates from a trusted CA
- Host-based routing requires proper DNS configuration or hosts file entries
- Consider using cert-manager for automated certificate management
- Gateway metrics can be scraped for monitoring

## Next Steps

- Enable mTLS for stronger authentication: See [host-routing-mtls](../host-routing-mtls)
- Implement auth-swap with OAuth: See [host-routing-authswap-oauth](../host-routing-authswap-oauth)
- Add RBAC authorization: See [host-routing-rbac](../host-routing-rbac)
