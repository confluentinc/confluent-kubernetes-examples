# Gateway with Confluent Cloud: Host-based Routing, SASL/PLAIN Passthrough, and TLS

This example demonstrates a Gateway configuration, deployed with Confluent for Kubernetes (CFK), that routes client traffic to a **Confluent Cloud** Kafka cluster:
- **Authentication Mode**: Passthrough (the Confluent Cloud API key and secret provided by the client are forwarded to Confluent Cloud)
- **Routing Strategy**: Host-based routing (SNI routing)
- **Client TLS**: TLS enabled (one-way TLS)
- **Cluster TLS**: TLS enabled (one-way TLS), trusting the Let's Encrypt root CAs
- **Client Authentication**: SASL/PLAIN
- **Cluster Authentication**: SASL/PLAIN
- **External Access**: LoadBalancer

## Overview

The other examples in this repository connect the Gateway to a Confluent Platform cluster whose certificates you generate and control. Confluent Cloud is different: the Kafka cluster presents a certificate signed by the [Let's Encrypt](https://letsencrypt.org/certificates/) certificate authority. The Gateway must trust that CA when it connects to Confluent Cloud, so you need to create a Kubernetes secret that contains the Let's Encrypt root certificates and reference it in the `tls.secretRef` field of the Confluent Cloud bootstrap server in the Gateway custom resource (CR).

Clients connect to the Gateway over TLS using the certificate that you generate in [Step 2](#step-2-create-kubernetes-secrets-required-for-enabling-tls), and authenticate with a Confluent Cloud API key and secret. The Gateway forwards those credentials to Confluent Cloud.

## Variants

| Example | Gateway to Confluent Cloud TLS | Client authentication |
| --- | --- | --- |
| This example | JKS truststore secret with the Let's Encrypt root CAs | API key and secret (SASL/PLAIN) |
| [passthrough-sasl-ssl-ccloud-pem](../passthrough-sasl-ssl-ccloud-pem) | PEM secret (`cacerts.pem`) with the Let's Encrypt root CAs | API key and secret (SASL/PLAIN) |
| [passthrough-sasl-ssl-ccloud-default-truststore](../passthrough-sasl-ssl-ccloud-default-truststore) | No secret (empty `tls` block, default Java truststore) | API key and secret (SASL/PLAIN) |
| [passthrough-oauth-ssl-ccloud](../passthrough-oauth-ssl-ccloud) | JKS or PEM secret | OAuth (SASL/OAUTHBEARER) |

## Deploy the Example

### Prerequisites

- Please ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites) for using the examples in this repo.
- You will need a Confluent Cloud Kafka cluster that is reachable from your Kubernetes cluster, for example, a cluster with public endpoints.
- You will need a Confluent Cloud [API key and secret](https://docs.confluent.io/cloud/current/security/authenticate/workload-identities/service-accounts/api-keys/manage-api-keys.html) for the cluster, and a topic to test with.
- OpenSSL is required for certificate generation.
- `keytool` command is required for managing keystore and certificates.
- `curl` is required to download the Let's Encrypt root certificates.

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
- The `gateway.example.com` domain and the `*.gateway.example.com` wildcard in the guide match the `endpoint` and `pattern` values in [gateway.yaml](./gateway.yaml). If you use a different domain, update the certificate SANs and `gateway.yaml` to match.

#### Create Gateway to Confluent Cloud TLS Secret

Confluent Cloud brokers present certificates signed by Let's Encrypt. Create a truststore that contains the Let's Encrypt root CAs, and store it in a Kubernetes secret (`ccloud-tls`).

1. Download the Let's Encrypt root certificates, ISRG Root X1 and ISRG Root X2. For the latest list of root certificates, see the [Let's Encrypt certificate list](https://letsencrypt.org/certificates/).
```
curl -fsSO https://letsencrypt.org/certs/isrgrootx1.pem
curl -fsSO https://letsencrypt.org/certs/isrg-root-x2.pem
```

2. Create a JKS truststore that contains both certificates.
- Modify the `-storepass` value if required.
```
keytool -import -noprompt -trustcacerts \
  -alias isrgrootx1 \
  -file isrgrootx1.pem \
  -keystore truststore.jks \
  -storepass changeit

keytool -import -noprompt -trustcacerts \
  -alias isrg-root-x2 \
  -file isrg-root-x2.pem \
  -keystore truststore.jks \
  -storepass changeit
```

3. Verify the truststore. The output should list two `trustedCertEntry` entries.
```
keytool -list -keystore truststore.jks -storepass changeit
```

4. Create the JKS password file. The password must match the `-storepass` value that you used above, and use the following format: `jksPassword=<password_for_jks>`.
   - More details available [here](https://docs.confluent.io/operator/current/co-network-encryption.html#provide-tls-keys-and-certificates-in-java-keystore-format)
```
echo "jksPassword=changeit" > jksPassword.txt
```

5. Create the Kubernetes secret.
```
kubectl create secret generic ccloud-tls \
  --from-file=truststore.jks=truststore.jks \
  --from-file=jksPassword.txt=jksPassword.txt \
  -n confluent
```

**Note:** Do not set `ignoreTrustStoreConfig: true` on the bootstrap server to skip the truststore. Use the secret above to establish trust with Confluent Cloud.

### Step 3: Deploy gateway YAML

- Modify the `endpoint` value in the `streamingDomains` section of [gateway.yaml](./gateway.yaml) to the bootstrap endpoint of your Confluent Cloud cluster, for example, `SASL_SSL://pkc-xxxxx.us-west-2.aws.confluent.cloud:9092`.
   - You can find the endpoint in the Confluent Cloud Console under **Cluster Settings** > **Endpoints**.
- If you use a domain other than `gateway.example.com`, update the `endpoint`, `pattern`, and `domain` values accordingly.
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

- Get the external IP address or hostname of the Gateway load balancer.
```
kubectl get svc -n confluent
```

- Create DNS records so that clients can resolve the Gateway bootstrap host and the broker hosts to the load balancer. For example, create a record for `gateway.example.com` and a wildcard record for `*.gateway.example.com`. For testing, you can instead add entries to `/etc/hosts` on the client machine.

## Testing the Configuration

1. Create a truststore for client to gateway connection.
- This truststore contains the CA that signed the **Gateway** certificate (`cacerts.pem` from the certificates guide), not the Let's Encrypt CA.
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
- Set `username` to your Confluent Cloud API key and `password` to your Confluent Cloud API secret.
- Configure the values of `ssl.truststore.location` and `ssl.truststore.password` based on the previous step.

```
sasl.mechanism=PLAIN
security.protocol=SASL_SSL
group.id=console-consumer-group
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
      username="<CCLOUD_API_KEY>" \
      password="<CCLOUD_API_SECRET>";

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

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Client reports a TLS handshake error or `PKIX path building failed` when connecting to the Gateway | The client truststore does not contain the CA that signed the Gateway certificate, or the Gateway certificate SANs do not cover the Gateway hostnames. |
| Client reports `Disconnected while requesting ApiVersion` or a similar transport failure, and the Gateway logs show an over-sized frame or an unexpected TLS handshake | The client is connecting without TLS. Make sure the client uses `security.protocol=SASL_SSL`, because the route enables client TLS. |
| Gateway logs show an SSL handshake or certificate validation error when connecting to Confluent Cloud | The `ccloud-tls` secret is missing, or it does not contain the CA that signed the Confluent Cloud certificate. Confirm the secret contents and the `jksPassword` value. |
| Authentication fails | The API key or secret is incorrect, or the key does not have access to the cluster or topic. |

**Note:** The Gateway doesn't hot-reload TLS certificates. If you update the `ccloud-tls` or `gateway-tls` secret, trigger a reconciliation of the Gateway CR, for example by editing its `spec`, so the pods restart and load the new certificates.

## Clean Up

To remove all resources created by this example:

- Delete Gateway
```
kubectl delete -f gateway.yaml -n confluent
```

- Delete Kubernetes secrets
```
kubectl delete secret gateway-tls -n confluent
kubectl delete secret ccloud-tls -n confluent
```
