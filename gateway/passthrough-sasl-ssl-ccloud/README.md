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
- You will need a Confluent Cloud [API key and secret](https://docs.confluent.io/cloud/current/security/authenticate/workload-identities/service-accounts/api-keys/manage-api-keys.html) for the cluster.
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
- In the guide, use `gateway.localhost` for the domain. This matches the `endpoint`, `pattern`, and `domain` values in [gateway.yaml](./gateway.yaml):
  - In the certificate signing request, set `CN=gateway.localhost`.
  - In the certificate extensions, set `subjectAltName=DNS:gateway.localhost,DNS:*.gateway.localhost`.

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

- Forward the Gateway port to your machine. Keep this command running while you test.
```
kubectl port-forward svc/confluent-gateway-bootstrap-lb 9595:9595 -n confluent
```
  Many systems, including macOS, resolve any `*.localhost` name to `127.0.0.1`. So the bootstrap host `gateway.localhost` and all broker hosts, for example `broker100.gateway.localhost`, reach the Gateway through this port-forward. If your system doesn't resolve `*.localhost`, use DNS records as described in [Production deployment](#production-deployment).

### Step 5: Create the test topic

Create a topic named `test-topic` in your Confluent Cloud cluster, for example, in the Confluent Cloud Console or with `confluent kafka topic create test-topic --cluster <cluster-id>`.

**Note:** Confluent Cloud doesn't create topics automatically.

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
  --bootstrap-server gateway.localhost:9595 \
  --producer.config client.properties \
  --topic test-topic
```

4. Test consuming messages:
```
kafka-console-consumer \
  --bootstrap-server gateway.localhost:9595 \
  --consumer.config client.properties \
  --topic test-topic \
  --from-beginning
```

**Note:** On Kafka 4.2 and later, `--producer.config` and `--consumer.config` are deprecated. You can use `--command-config` instead.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Client reports a TLS handshake error or `PKIX path building failed` when connecting to the Gateway | The client truststore does not contain the CA that signed the Gateway certificate, or the Gateway certificate SANs do not cover the Gateway hostnames. |
| Client reports `Disconnected while requesting ApiVersion` or a similar transport failure, and the Gateway logs show an over-sized frame or an unexpected TLS handshake | The client is connecting without TLS. Make sure the client uses `security.protocol=SASL_SSL`, because the route enables client TLS. |
| Gateway logs show an SSL handshake or certificate validation error when connecting to Confluent Cloud | The `ccloud-tls` secret is missing, or it does not contain the CA that signed the Confluent Cloud certificate. Confirm the secret contents and the `jksPassword` value. |
| Authentication fails | The API key or secret is incorrect, or the key does not have access to the cluster or topic. |
**Note:** The Gateway doesn't hot-reload TLS certificates. If you update the `ccloud-tls` or `gateway-tls` secret, trigger a reconciliation of the Gateway CR, for example by editing its `spec`, so the pods restart and load the new certificates.

## Production deployment

This example uses `gateway.localhost` and a port-forward for a local test. For a production deployment:

- Use your own domain, for example `gateway.mycompany.com`, in the `endpoint`, `pattern`, and `domain` values in [gateway.yaml](./gateway.yaml).
- Issue the Gateway certificate for that domain, with the domain and a wildcard (for example `*.gateway.mycompany.com`) as SANs. The wildcard is necessary because the Gateway advertises one hostname for each Confluent Cloud broker, and the broker IDs are not known in advance.
- Get the external address of the Gateway load balancer with `kubectl get svc -n confluent`, and create a DNS record for the domain and a wildcard record that point to it. For more information, see [Route endpoint DNS records](https://docs.confluent.io/operator/current/gateway/co-gateway-deploy.html#route-endpoint-dns-records).

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
