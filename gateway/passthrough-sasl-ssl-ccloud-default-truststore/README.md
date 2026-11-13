# Gateway with Confluent Cloud: Default Truststore (No Custom CA Secret)

This example is a variant of [passthrough-sasl-ssl-ccloud](../passthrough-sasl-ssl-ccloud). It enables TLS to Confluent Cloud with an **empty `tls` block**, so you don't create a secret for the Let's Encrypt CA.

- **Authentication Mode**: Passthrough (the Confluent Cloud API key and secret provided by the client are forwarded to Confluent Cloud)
- **Routing Strategy**: Host-based routing (SNI routing)
- **Client TLS**: TLS enabled (one-way TLS)
- **Cluster TLS**: TLS enabled (one-way TLS), with no custom truststore
- **Client Authentication**: SASL/PLAIN
- **Cluster Authentication**: SASL/PLAIN
- **External Access**: LoadBalancer

## Overview

When the bootstrap server has `tls: {}`, CFK doesn't mount a truststore for the connection to Confluent Cloud. It renders the Gateway configuration with `ssl.ignoreTrust: false` and no `truststore`, so the Gateway still validates the Confluent Cloud broker certificate, using the default truststore of its Java runtime.

Use this variant when the default Java truststore trusts the CA that signs your Confluent Cloud certificates. If the connection fails with a certificate validation error, use [passthrough-sasl-ssl-ccloud](../passthrough-sasl-ssl-ccloud) or [passthrough-sasl-ssl-ccloud-pem](../passthrough-sasl-ssl-ccloud-pem) to provide the CA explicitly.

**Note:** Don't use `tls.ignoreTrustStoreConfig: true` to work around certificate errors. That setting skips certificate validation on the Gateway to Confluent Cloud connection, and isn't recommended for production.

## Deploy the Example

### Prerequisites

The prerequisites are the same as the [passthrough-sasl-ssl-ccloud](../passthrough-sasl-ssl-ccloud/README.md#prerequisites) example, except that you don't need the Let's Encrypt certificates.

### Step 1: Deploy the operator and create the client TLS secret

- Deploy the CFK operator by following [Step 1](../passthrough-sasl-ssl-ccloud/README.md#step-1-deploy-the-confluent-for-kubernetes-operator) of the main example.
- Create the client to Gateway TLS secret (`gateway-tls`) by following the [certificates guide](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/gateway/certificates/README.md).

### Step 2: Deploy gateway YAML

- Modify the `endpoint` value in the `streamingDomains` section of [gateway.yaml](./gateway.yaml) to the bootstrap endpoint of your Confluent Cloud cluster.
- If you use a domain other than `gateway.example.com`, update the `endpoint`, `pattern`, and `domain` values accordingly.
- Deploy the gateway yaml and wait for the pods to become ready.

```
kubectl apply -f gateway.yaml -n confluent
kubectl wait --for=condition=Ready pod -l app=confluent-gateway --timeout=600s -n confluent
```

### Step 3: Verify the deployment and test

Follow the verification and testing steps in the [main example](../passthrough-sasl-ssl-ccloud/README.md#step-4-verify-deployment). The client configuration is identical.

## Clean Up

```
kubectl delete -f gateway.yaml -n confluent
kubectl delete secret gateway-tls -n confluent
```
