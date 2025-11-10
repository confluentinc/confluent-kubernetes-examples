# Authentication Swap - mTLS to OAuth

This example demonstrates a Gateway configuration with authentication swap where clients authenticate with tls certificate and the Gateway uses swapped credentials (`bob/bob-secret`) to connect to the Kafka cluster.

## Configuration Overview

- **Authentication Mode**: Authentication Swap (credentials swapped by Gateway)
- **Routing Strategy**: Port-based routing
- **Client TLS**: mTLS
- **Cluster TLS**: TLS
- **Client Authentication**: mTLS
- **Cluster Authentication**: OAuth (swapped credentials)
- **External Access**: LoadBalancer

## Deploy the Example

### Prerequisites

- Please ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites) for using the examples in this repo.
- You will also require a Kafka cluster set up with an OAuth listener configured.

### Client Certificate Setup

For mTLS authentication, clients need to present certificates to the Gateway. Follow the certificate generation guide to create the required certificates:

- See [Gateway Certificate Generation Guide](../certificates/README.md) for complete instructions
- You will need to complete:
  - **Step 1-5**: Gateway server certificates (required)
  - **Step 6**: Client truststore (required for TLS)
  - **Step 7-8**: Client certificate and keystore (required for mTLS)

**Important Notes:**
- The client certificate's Common Name (CN) must match the username used in the auth swap mapping
- For example, if mapping `alice` to `bob`, your client certificate should have `CN=alice`
- The Gateway will extract the username from the certificate CN and look it up in the file-store secret

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
    - For the purpose of this example, we will be swapping incoming credentials for user `alice` with credentials for user `bob`.
    - Please change the outgoing swapped credentials in the below command (`bob/bob-secret`) appropriately based on your Kafka cluster setup.
    - In this OAuth configuration, `bob` is the OAuth clientId and `bob-secret` is the OAuth clientSecret.
```
kubectl create secret generic file-store-client-credentials \
  --from-literal=alice="bob/bob-secret" \
  -n confluent
```

- Create Kubernetes secret for file store config
```
kubectl create secret generic file-store-config --from-literal=separator="/" -n confluent
```

### Step 3: Setup JAAS configs

- Create JAAS template secret for gateway to Kafka cluster connection.
```
kubectl create secret generic oauth-jaas \
  --from-literal=oauth-jaas.conf='org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="%s" clientSecret="%s";' \
  -n confluent
```

### Understanding Gateway mTLS Configuration

The Gateway is configured to use mTLS authentication on the client-facing side. Let's understand the key configuration options in the [gateway.yaml](./gateway.yaml):

```yaml
client:
  authentication:
    type: mtls
    mtls:
      principalMappingRules: ["DEFAULT"]
      sslClientAuthentication: "required"
```

#### Configuration Parameters

**`type: mtls`**
- Enables mutual TLS authentication where the Gateway verifies client certificates
- Clients must present a valid certificate signed by the trusted CA

**`principalMappingRules`**
- Defines how to extract the username (principal) from the client certificate
- `["DEFAULT"]` uses the certificate's Common Name (CN) as the username
- Alternative formats:
  - `["RULE:pattern/replacement/"]` for custom mapping using regex
  - `["RULE:^CN=([^,]+).*$/$1/"]` explicitly extracts CN value
- Example: If client certificate has `CN=alice,OU=Engineering,O=Confluent`, the extracted username is `alice`

**`sslClientAuthentication: "required"`**
- Enforces client certificate validation
- Options:
  - `"required"` - Clients MUST present valid certificates (recommended for production)
  - `"requested"` - Clients are asked for certificates but can connect without them
  - `"none"` - Client certificates are not requested

#### Authentication Swap Flow

The complete authentication flow with mTLS and auth swap works as follows:

1. **Client Connection**: Client initiates TLS connection and presents certificate (e.g., `CN=alice`)
2. **Certificate Validation**: Gateway validates the client certificate against the CA
3. **Principal Extraction**: Gateway extracts username from certificate using `principalMappingRules` → `alice`
4. **Credential Lookup**: Gateway looks up `alice` in the `file-store-client-credentials` secret
5. **Credential Swap**: Gateway finds mapping: `alice="bob/bob-secret"`
6. **Kafka Connection**: Gateway connects to Kafka cluster using swapped OAuth credentials (clientId: `bob`, clientSecret: `bob-secret`)
7. **Authorization**: Kafka sees the request coming from user `bob`, not `alice`

This allows you to:
- Use certificate-based authentication on the client side (more secure, no passwords)
- Use OAuth authentication to Kafka (modern authentication standard)
- Map client identities to different Kafka users (auth swap)

### Step 4: Create Gateway TLS Secret

The Gateway needs TLS certificates to enable client connections over TLS/mTLS. Create the `gateway-tls` secret using the certificates you generated in the "Client Certificate Setup" section:

```bash
kubectl create secret generic gateway-tls \
    --from-file=fullchain.pem=fullchain.pem \
    --from-file=cacerts.pem=cacerts.pem \
    --from-file=privkey.pem=privkey.pem \
    --namespace confluent
```

See [Step 5 in the Certificate Guide](../certificates/README.md#step-5-create-kubernetes-secret) for details.

### Step 5: Deploy gateway yaml

- Modify the `streamingDomains` section in the [gateway.yaml](./gateway.yaml) to point to your Kafka cluster OAuth listener.
- **Important**: Update the `tokenEndpointUri` under `cluster.authentication.oauthSettings` in the gateway.yaml file. Replace `<endpoint_url>` with your actual OAuth token endpoint URL (e.g., `https://your-oauth-server.com/oauth2/token`).
- Now deploy the gateway yaml.
```
kubectl apply -f gateway.yaml -n confluent
```
- Wait for the gateway pods to become `READY`
```
kubectl wait --for=condition=Ready pod -l app=confluent-gateway --timeout=600s -n confluent
```

### Step 6: Verify Deployment

- Check all components are running:
```
kubectl get pods -n confluent
kubectl get gateway -n confluent
kubectl get svc -n confluent
```

## Testing the Configuration

### Step 1: Create Client Certificates

Before testing, ensure you have created the client certificates following the [Gateway Certificate Generation Guide](../certificates/README.md):

- Client truststore: `client-truststore.jks` (to verify Gateway's certificate)
- Client keystore: `client-keystore.jks` (containing client certificate with CN=alice)

### Step 2: Create Client Configuration

Create a client configuration file (`client.properties`) with mTLS configuration:

```properties
security.protocol=SSL

# SSL Configuration for mTLS
ssl.truststore.location=/path/to/client-truststore.jks
ssl.truststore.password=clienttrustpass
ssl.keystore.location=/path/to/client-keystore.jks
ssl.keystore.password=clientkeypass
ssl.key.password=clientkeypass
```

**Important Notes:**
- No OAuth or SASL configuration is needed on the client side - authentication is via client certificate only
- OAuth is used only for Gateway-to-Kafka authentication, not for client-to-Gateway authentication
- Update the paths to match where you stored your keystore and truststore files
- The client certificate CN (e.g., `CN=alice`) is used for authentication
- The Gateway will swap this identity to OAuth credentials (`bob`) when connecting to Kafka

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

### Verification

To verify the auth swap is working:

1. Check Gateway logs:
```bash
kubectl logs -n confluent -l app=confluent-gateway --tail=50
```

You should see:
- Client certificate validation (CN=alice)
- Credential swap (alice → bob)
- Connection to Kafka with OAuth credentials for user bob

2. Check Kafka logs or ACLs - all operations should appear as user `bob`, not `alice`

## Clean Up

To remove all resources created by this example:

- Delete Gateway
```
kubectl delete -f gateway.yaml -n confluent
```

- Delete Kubernetes secrets
```
kubectl delete secret file-store-config file-store-client-credentials oauth-jaas gateway-tls -n confluent
```

- Delete client certificates (if created locally)
```
rm -f client-key.pem client-cert.pem client-keystore.p12 client-keystore.jks client-truststore.jks
rm -f client.properties
```

