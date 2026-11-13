# Gateway with Confluent Cloud: Let's Encrypt CA in a PEM Secret

This example is a variant of [passthrough-sasl-ssl-ccloud](../passthrough-sasl-ssl-ccloud). It shows how to give the Gateway the Let's Encrypt root CAs as a **PEM** file, instead of a JKS truststore, so that the Gateway trusts the Confluent Cloud certificate.

- **Authentication Mode**: Passthrough (the Confluent Cloud API key and secret provided by the client are forwarded to Confluent Cloud)
- **Routing Strategy**: Host-based routing (SNI routing)
- **Client TLS**: TLS enabled (one-way TLS)
- **Cluster TLS**: TLS enabled (one-way TLS), with a PEM secret (`cacerts.pem`) that holds the Let's Encrypt root CAs
- **Client Authentication**: SASL/PLAIN
- **Cluster Authentication**: SASL/PLAIN
- **External Access**: LoadBalancer

Use this variant if you prefer PEM files over Java keystores. CFK converts the PEM file into a truststore for the Gateway, so you don't need `keytool` or a `jksPassword.txt` file for the Confluent Cloud secret.

## Deploy the Example

### Prerequisites

The prerequisites are the same as the [passthrough-sasl-ssl-ccloud](../passthrough-sasl-ssl-ccloud/README.md#prerequisites) example. `keytool` is only needed for the client truststore in the testing steps.

### Step 1: Deploy the operator and create the Kubernetes secrets

- Deploy the CFK operator by following [Step 1](../passthrough-sasl-ssl-ccloud/README.md#step-1-deploy-the-confluent-for-kubernetes-operator) of the main example.
- Create the client to Gateway TLS secret (`gateway-tls`) by following the [certificates guide](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/gateway/certificates/README.md).
- Create the Gateway to Confluent Cloud TLS secret (`ccloud-tls`):

1. Download the Let's Encrypt root certificates, ISRG Root X1 and ISRG Root X2. For the latest list of root certificates, see the [Let's Encrypt certificate list](https://letsencrypt.org/certificates/).
```
curl -fsSO https://letsencrypt.org/certs/isrgrootx1.pem
curl -fsSO https://letsencrypt.org/certs/isrg-root-x2.pem
```

2. Concatenate the certificates into a single PEM file.
```
cat isrgrootx1.pem isrg-root-x2.pem > ccloud-cacerts.pem
```

3. Create the Kubernetes secret. The key name in the secret must be `cacerts.pem`.
```
kubectl create secret generic ccloud-tls \
  --from-file=cacerts.pem=ccloud-cacerts.pem \
  -n confluent
```

### Step 2: Deploy gateway YAML

- Modify the `endpoint` value in the `streamingDomains` section of [gateway.yaml](./gateway.yaml) to the bootstrap endpoint of your Confluent Cloud cluster.
- If you use a domain other than `gateway.example.com`, update the `endpoint`, `pattern`, and `domain` values accordingly.
- Deploy the gateway yaml and wait for the pods to become ready.

```
kubectl apply -f gateway.yaml -n confluent
kubectl wait --for=condition=Ready pod -l app=confluent-gateway --timeout=600s -n confluent
```

### Step 3: Verify the deployment and test

Follow the verification and testing steps in the [main example](../passthrough-sasl-ssl-ccloud/README.md#step-4-verify-deployment). The client configuration is identical, because only the Gateway to Confluent Cloud leg is different.

## Clean Up

```
kubectl delete -f gateway.yaml -n confluent
kubectl delete secret gateway-tls -n confluent
kubectl delete secret ccloud-tls -n confluent
```
