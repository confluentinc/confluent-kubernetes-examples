# Gateway with Confluent Cloud: SASL/OAUTHBEARER Passthrough

This example is a variant of [passthrough-sasl-ssl-ccloud](../passthrough-sasl-ssl-ccloud) for clients that authenticate to Confluent Cloud with **OAuth** (SASL/OAUTHBEARER) instead of an API key.

- **Authentication Mode**: Passthrough (the OAuth token request from the client is forwarded to Confluent Cloud)
- **Routing Strategy**: Host-based routing (SNI routing)
- **Client TLS**: TLS enabled (one-way TLS)
- **Cluster TLS**: TLS enabled (one-way TLS), trusting the Let's Encrypt root CAs
- **Client Authentication**: SASL/OAUTHBEARER
- **Cluster Authentication**: SASL/OAUTHBEARER
- **External Access**: LoadBalancer

## Overview

The Gateway doesn't validate or exchange the OAuth token in passthrough mode. The client gets a token from your identity provider and the Gateway relays the SASL/OAUTHBEARER exchange to Confluent Cloud.

This example uses `extensionHeaders` to add the Confluent Cloud logical cluster ID (`lkc-...`) to the client's OAUTHBEARER handshake. Because the Gateway sets the logical cluster, you don't have to configure it in every client, and you can change it centrally, for example, after a failover to another cluster. The `extensionHeaders` setting can only be used with `auth: passthrough` on the cluster entry, and when `security.client.authentication.type` is `oauth`.

## Deploy the Example

### Prerequisites

- The prerequisites are the same as the [passthrough-sasl-ssl-ccloud](../passthrough-sasl-ssl-ccloud/README.md#prerequisites) example, except that you don't need an API key.
- You will need an OAuth identity provider that is configured in Confluent Cloud, and an [identity pool](https://docs.confluent.io/cloud/current/security/authenticate/workload-identities/identity-providers/oauth/identity-pools.html) that grants access to your cluster.
- You will need the logical cluster ID (`lkc-...`) of your Confluent Cloud cluster.

### Step 1: Deploy the operator and create the Kubernetes secrets

- Deploy the CFK operator by following [Step 1](../passthrough-sasl-ssl-ccloud/README.md#step-1-deploy-the-confluent-for-kubernetes-operator) of the main example.
- Create the client to Gateway TLS secret (`gateway-tls`) by following the [certificates guide](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/gateway/certificates/README.md).
- Create the Gateway to Confluent Cloud TLS secret (`ccloud-tls`) by following the [steps in the main example](../passthrough-sasl-ssl-ccloud/README.md#create-gateway-to-confluent-cloud-tls-secret). You can also use the [PEM secret](../passthrough-sasl-ssl-ccloud-pem/README.md) instead.

### Step 2: Deploy gateway YAML

- Modify the `endpoint` value in the `streamingDomains` section of [gateway.yaml](./gateway.yaml) to the bootstrap endpoint of your Confluent Cloud cluster.
- Modify the `logicalCluster` value under `extensionHeaders` to your logical cluster ID.
- If you use a domain other than `gateway.example.com`, update the `endpoint`, `pattern`, and `domain` values accordingly.
- Deploy the gateway yaml and wait for the pods to become ready.

```
kubectl apply -f gateway.yaml -n confluent
kubectl wait --for=condition=Ready pod -l app=confluent-gateway --timeout=600s -n confluent
```

### Step 3: Verify the deployment

Follow the [verification steps](../passthrough-sasl-ssl-ccloud/README.md#step-4-verify-deployment) of the main example, including the DNS setup.

## Testing the Configuration

1. Create a truststore for the client to Gateway connection, as in the [main example](../passthrough-sasl-ssl-ccloud/README.md#testing-the-configuration).

2. Create a client configuration file (`client-oauth.properties`).
- Replace the placeholders with the values for your identity provider and identity pool.
- You don't need to set `extension_logicalCluster`, because the Gateway adds it.

```
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler
sasl.oauthbearer.token.endpoint.url=<IDP_TOKEN_ENDPOINT_URL>
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required \
      clientId="<CLIENT_ID>" \
      clientSecret="<CLIENT_SECRET>" \
      extension_identityPoolId="<IDENTITY_POOL_ID>";

ssl.truststore.location=./gateway.truststore.jks
ssl.truststore.password=changeit
```

3. Produce and consume messages:
```
kafka-console-producer \
  --bootstrap-server gateway.example.com:9595 \
  --producer.config client-oauth.properties \
  --topic test-topic

kafka-console-consumer \
  --bootstrap-server gateway.example.com:9595 \
  --consumer.config client-oauth.properties \
  --topic test-topic \
  --from-beginning
```

## Clean Up

```
kubectl delete -f gateway.yaml -n confluent
kubectl delete secret gateway-tls -n confluent
kubectl delete secret ccloud-tls -n confluent
```
