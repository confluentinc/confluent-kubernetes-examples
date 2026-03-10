# Authentication Swap - SASL/SCRAM to OAuth

This example demonstrates a Gateway configuration with authentication swap where clients authenticate using SASL/SCRAM-SHA-256 credentials (`alice/alice-secret`) and the Gateway uses swapped credentials (`bob/bob-secret`) to connect to the Kafka cluster using OAuth.

## Configuration Overview

- **Authentication Mode**: Authentication Swap (credentials swapped by Gateway)
- **Routing Strategy**: Port-based routing
- **Client TLS**: None (PLAINTEXT)
- **Cluster TLS**: None (PLAINTEXT)
- **Client Authentication**: SASL/SCRAM-SHA-256
- **Cluster Authentication**: OAuth (swapped credentials)
- **External Access**: LoadBalancer

## Deploy the Example

### Prerequisites

- Please ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites) for using the examples in this repo.
- You will also require a Kafka cluster set up with an OAuth listener configured.

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

### Step 2: Setup Vault Secret Store

- This example uses HashiCorp Vault as the secret store for credential mapping.
   - For the purpose of this example, we will be swapping incoming credentials for user `alice` with credentials for user `bob`.
   - In this OAuth configuration, `bob` is the OAuth clientId and `bob-secret` is the OAuth clientSecret.
   - Please change the Vault address and swapped credentials appropriately based on your setup.

- Create Kubernetes secret for Vault authentication token
```
kubectl create secret generic vault-config \
  --from-literal=address=http://vault:8200 \
  --from-literal=authToken=vault-plaintext-root-token \
  --from-literal=prefixPath=secret/ \
  --from-literal=separator=/ \
  -n confluent
```

- Store swapped credentials in Vault. For each user that needs auth swap, create a secret in Vault:
```
vault kv put secret/alice password=bob/bob-secret
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

### Step 4: Setup JAAS configs

- Create JAAS template secret for gateway to Kafka cluster connection.
```
kubectl create secret generic oauth-jaas \
  --from-literal=oauth-jaas.conf='org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="%s" clientSecret="%s";' \
  -n confluent
```

### Understanding Gateway SASL/SCRAM Configuration

The Gateway is configured to use SASL/SCRAM-SHA-256 authentication on the client-facing side. Let's understand the key configuration options in the [gateway.yaml](./gateway.yaml):

```yaml
client:
  authentication:
    type: scram
    scram:
      alterScramCredentials: true
      adminCredentialSecretRef: scram-admin-credentials
```

#### Configuration Parameters

**`type: scram`**
- Enables SASL/SCRAM-SHA-256 authentication where the Gateway verifies client credentials
- Clients authenticate using username and password with SCRAM mechanism

**`alterScramCredentials: true`**
- Allows the Gateway to dynamically manage SCRAM credentials
- The Gateway uses admin credentials to create and update SCRAM user credentials

**`adminCredentialSecretRef`**
- References a Kubernetes secret containing admin credentials (`username` and `password`)
- The admin credentials are used to manage SCRAM credentials via the Kafka `AlterUserScramCredentials` API

#### Authentication Swap Flow

The complete authentication flow with SASL/SCRAM and auth swap works as follows:

1. **Client Connection**: Client connects to Gateway with SCRAM credentials (e.g., `alice/alice-secret`)
2. **SCRAM Authentication**: Gateway authenticates the client using SASL/SCRAM-SHA-256
3. **Credential Lookup**: Gateway looks up `alice` in the Vault secret store
4. **Credential Swap**: Gateway retrieves swapped credentials (`bob/bob-secret` as clientId/clientSecret) from Vault
5. **JAAS Template Population**: Gateway populates the OAuth JAAS template with swapped credentials (`bob`, `bob-secret`)
6. **Token Exchange**: Gateway uses the OAuth token endpoint to exchange clientId/clientSecret for an access token
7. **Kafka Connection**: Gateway connects to Kafka cluster using the OAuth access token
8. **Authorization**: Kafka sees the request coming from OAuth user `bob`, not `alice`

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

Create a client configuration file (`client.properties`) with SCRAM credentials for authentication swap:

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

### Verification

To verify the auth swap is working:

1. Check Gateway logs:
```bash
kubectl logs -n confluent -l app=confluent-gateway --tail=50
```

You should see:
- SCRAM authentication for user `alice`
- Credential swap (alice -> bob)
- OAuth token exchange with swapped credentials
- Connection to Kafka with OAuth credentials for user `bob`

2. Check Kafka logs or ACLs - all operations should appear as user `bob`, not `alice`

## Clean Up

To remove all resources created by this example:

- Delete Gateway
```
kubectl delete -f gateway.yaml -n confluent
```

- Delete Kubernetes secrets
```
kubectl delete secret vault-config scram-admin-credentials oauth-jaas -n confluent
```
