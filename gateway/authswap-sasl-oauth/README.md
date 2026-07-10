# Authentication Swap - OAuth to OAuth

This example demonstrates a Gateway configuration with authentication swap where clients authenticate with an OAuth access token (validated by the Gateway against the identity provider's JWKS endpoint) and the Gateway uses swapped OAuth credentials (clientId: `bob`, clientSecret: `bob-secret`) to connect to the Kafka cluster.

## Configuration Overview

- **Authentication Mode**: Authentication Swap (credentials swapped by Gateway)
- **Routing Strategy**: Port-based routing
- **Client TLS**: None (PLAINTEXT)
- **Cluster TLS**: None (PLAINTEXT)
- **Client Authentication**: OAuth (OAUTHBEARER, validated via JWKS)
- **Cluster Authentication**: OAuth (swapped credentials)
- **External Access**: LoadBalancer

## Deploy the Example

### Prerequisites

- Please ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites) for using the examples in this repo.
- You will also require a Kafka cluster set up with an OAuth listener configured.
- You will need an identity provider (IdP), such as Okta or Keycloak, that supports:
  - Issuing OAuth access tokens (JWTs) to clients, and exposing a JWKS endpoint the Gateway can use to validate them.
  - Issuing OAuth access tokens via the client credentials grant, for the swapped credentials the Gateway uses to connect to the Kafka cluster.
  - This can be the same IdP application/realm used for both legs, or two separate ones - the Gateway does not require them to match.

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
    - For the purpose of this example, we will be swapping the incoming client's identity `alice` (extracted from the `sub` claim of its access token) with credentials for user `bob`.
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

- Create the JAAS config secret used by the Gateway to validate inbound client tokens. No client credentials are needed here - the Gateway only verifies the token signature/claims against the IdP's JWKS endpoint.
```
kubectl create secret generic client-oauth-jaas \
  --from-literal=oauth-jaas.conf='org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required;' \
  -n confluent
```

- Create the JAAS template secret used by the Gateway for the swapped connection to the Kafka cluster.
```
kubectl create secret generic oauth-jaas \
  --from-literal=oauth-jaas.conf='org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="%s" clientSecret="%s";' \
  -n confluent
```

### Understanding Gateway OAuth Client Configuration

The Gateway is configured to validate OAuth access tokens on the client-facing side. Let's understand the key configuration options in the [gateway.yaml](./gateway.yaml):

```yaml
client:
  authentication:
    type: oauth
    jaasConfigPassThrough:
      secretRef: client-oauth-jaas
    oauthSettings:
      jwksEndpointUri: <client_jwks_endpoint_url>
      expectedIssuer: <client_expected_issuer>
      audience: <client_audience>
      subClaimName: sub
```

#### Configuration Parameters

**`type: oauth`**
- Enables OAuth (SASL/OAUTHBEARER) authentication where the Gateway verifies the client's access token
- Clients present a bearer token obtained from the IdP instead of a username/password

**`jwksEndpointUri`**
- The IdP endpoint the Gateway uses to fetch the public keys (JWKS) needed to verify the token's signature
- Required whenever `client.authentication.type` is `oauth` on a `swap` route

**`expectedIssuer`** (optional)
- The `iss` claim the Gateway expects in the token; tokens issued by a different issuer are rejected

**`audience`** (optional)
- The `aud` claim the Gateway expects in the token; tokens issued for a different audience are rejected

**`subClaimName`**
- The claim used to extract the principal/username from the token (defaults to `sub`)
- This extracted value (e.g. `alice`) is what the Gateway looks up in the secret store for the auth swap

#### Authentication Swap Flow

The complete authentication flow with OAuth and auth swap works as follows:

1. **Client Connection**: Client obtains an access token from the IdP and connects to the Gateway using SASL/OAUTHBEARER, presenting the token
2. **Token Validation**: Gateway validates the token's signature using the IdP's JWKS endpoint, and checks `expectedIssuer`/`audience` if configured
3. **Principal Extraction**: Gateway extracts the username from the token's `sub` claim → `alice`
4. **Credential Lookup**: Gateway looks up `alice` in the `file-store-client-credentials` secret
5. **Credential Swap**: Gateway finds mapping: `alice="bob/bob-secret"`
6. **Token Exchange**: Gateway uses the swapped credentials (clientId: `bob`, clientSecret: `bob-secret`) to request a new JWT token from the IDP's token endpoint (configured via `tokenEndpointUri`)
7. **Kafka Connection**: Gateway connects to Kafka cluster using the new JWT token via OAUTHBEARER SASL mechanism
8. **Authorization**: Kafka validates the JWT token and extracts the principal from the token

This allows you to:
- Use OAuth-based authentication on the client side, validated independently by the Gateway
- Use OAuth authentication to Kafka (modern authentication standard)
- Map client identities to different Kafka users (auth swap), even across different IdP applications or realms

### Step 4: Deploy gateway yaml

- Modify the `streamingDomains` section in the [gateway.yaml](./gateway.yaml) to point to your Kafka cluster OAuth listener.
- **Important**: Update `client.authentication.oauthSettings` under the `client` section - replace `<client_jwks_endpoint_url>`, `<client_expected_issuer>` and `<client_audience>` with the values from the IdP application used by your clients.
- **Important**: Update the `tokenEndpointUri` under `cluster.authentication.oauthSettings` in the gateway.yaml file. Replace `<cluster_token_endpoint_url>` with the OAuth token endpoint URL for the swapped credentials (e.g., `https://your-oauth-server.com/oauth2/token`).
- **Important**: Also update the `<client_jwks_endpoint_url>` and `<cluster_token_endpoint_url>` in `podTemplate.envVars` for `GATEWAY_OPTS` with the same URLs used above. This sets the `org.apache.kafka.sasl.oauthbearer.allowed.urls` JVM system property, which is required to allowlist the JWKS and token endpoints the Gateway calls out to.
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

### Step 1: Create Client Configuration

Create a client configuration file (`client.properties`) so the client obtains its own OAuth access token (as `alice`) and presents it to the Gateway:

```properties
security.protocol=SASL_PLAINTEXT
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginCallbackHandler
sasl.oauthbearer.token.endpoint.url=<client_token_endpoint_url>
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required \
  clientId="alice" \
  clientSecret="alice-secret";
```

**Important Notes:**
- `<client_token_endpoint_url>` is the IdP token endpoint the client uses to obtain its own access token - this can be the same IdP as the Gateway's `jwksEndpointUri`, but is a separate client application/credential from the swapped `bob/bob-secret` used on the cluster side
- The access token's `sub` claim must be `alice` so the Gateway can look up the swap mapping
- No OAuth credentials for `bob` are configured on the client - the swap happens entirely inside the Gateway

### Step 2: Test Producing Messages

```bash
kafka-console-producer \
  --bootstrap-server gateway.example.com:9595 \
  --producer.config client.properties \
  --topic test-topic
```

### Step 3: Test Consuming Messages

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
- Client token validation against the JWKS endpoint (principal `alice`)
- Credential swap (alice → bob)
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
kubectl delete secret file-store-config file-store-client-credentials client-oauth-jaas oauth-jaas -n confluent
```
