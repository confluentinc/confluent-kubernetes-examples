# Use Cert Manager to provide certificates

[Cert-manager](https://cert-manager.io/) builds on top of Kubernetes to provide X.509 
certificates and issuers as first-class resource types.

Note: Confluent does not provide or support Cert Manager. It is part of the Kubernetes ecosystem. 
In this scenario workflow document, you'll see how to use Cert Manager to manage certificates 
used by Confluent components.

In this document, you'll see how to:

- Set up Cert-manager
- Create server certificates
- Configure Confluent for Kubernetes to use those server certificates.

Before continuing with the scenario, ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites).

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/using-cert-manager
```

## Deploy Confluent for Kubernetes

Set up the Helm Chart:

```
helm repo add confluentinc https://packages.confluent.io/helm
```

Install Confluent For Kubernetes using Helm:

```
helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace confluent
```
  
Check that the Confluent For Kubernetes pod comes up and is running:

```
kubectl get pods --namespace confluent
```

## Deploy Cert-manager

To comprehensively understand how to install cert manager using Helm, see these docs: https://cert-manager.io/docs/installation/kubernetes/

For the purpose of this scenario workflow, use this step to install Cert-manager:

```
kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.0.2/cert-manager.yaml
```


## Configure a Certificate Authority Issuer

When you provide TLS certificates, CFK takes the provided files and configures Confluent components accordingly.

For each component, the following TLS certificate information should be provided:
- The certificate authorities for the component to trust, including the authorities used to issue server certificates for any Confluent component cluster. These are required so that peer-to-peer communication (e.g. between Kafka Brokers) and communication between components (e.g. from Connect workers to Kafka) will work.
- The component’s server certificate (public key)
- The component’s server private key

Cert Manager supports different modes for certificate authorities:
- Using a CA Issuer - https://cert-manager.io/docs/configuration/ca/
- Using a Self-Signed Issuer - https://cert-manager.io/docs/configuration/selfsigned/
- Using a Let's Encrypt Issuer - https://cert-manager.io/docs/configuration/acme/

You should choose one of these modes. See below for an illustration on how to configure each mode.
     
### Using a CA Issuer

```
kubectl -k $TUTORIAL_HOME/cert-manager/ca apply
```

If you need to change the certificate SAN or secret names, change the file `cert-manager/ca/certificate.yaml`. 
The provided `certificate.yaml` is configured  with namespace `confluent` and an opinionated name choices for Confluent Platform.

Check issuers: `kubectl -n confluent get issuers`

```
$ kubectl -n confluent get issuers
NAME        READY   AGE
ca-issuer   True    90s
```

Check certificates: `kubectl -n confluent get certificates`

```
$ kubectl -n confluent get certificate
NAME                READY   SECRET               AGE
ca-c3-cert          True    controlcenter-tls    118s
ca-connect-cert     True    connect-tls          118s
ca-kafka-cert       True    kafka-tls            118s
ca-ksql-cert        True    ksqldb-tls           117s
ca-sr-cert          True    schemaregistry-tls   117s
ca-zookeeper-cert   True    zookeeper-tls        117s
```

This example uses a separate certificate for each Confluent Platform component.  You can choose to create one secret for 
all Confluent Platform components, and do so by putting all required SANs in to the `certificate.spec.dnsNames` in 
`certificate.yaml`.

### Using a Self-Signed Issuer

```
kubectl -k $TUTORIAL_HOME/cert-manager/self-signed apply
```

If you need to change the certificate SAN or secret names, change the file `cert-manager/self-signed/certificate.yaml`. 
The provided `certificate.yaml` is configured  with namespace `confluent` and an opinionated name choices for Confluent Platform.

Check issuers: `kubectl -n confluent get issuers`

Check certificates: `kubectl -n confluent get certificates`

### Cert-Manager with Let's Encrypt Issuer

Follow the instructions in https://cert-manager.io/docs/configuration/acme/ to set this up with your account for Let's Encrypt.

Once that is set up, you'll need to modify and use the Kustomize bundle in `$TUTORIAL_HOME/cert-manager/ca`.

## Deploy CP platform

Before deploying the Confluent Platform components, make sure all the secrets objects are created by running
`kubectl -n confluent get secrets`. 

The secret names can be checked with output of `kubectl -n confluent get certificates`.

The Confluent Platform spec in `$TUTORIAL_HOME/resources/confluent-platform.yaml` is using these generated secrets 
through cert-manager to configure TLS encryption for all network communication. In this example spec, no authentication 
is configured.

```
kubectl apply -n confluent -f $TUTORIAL_HOME/resources/confluent-platform.yaml
```

## Validate

### Status

Use the status section to get information about the component, such as endpoints, internal topics, etc. Here, you'll see 
that each component endpoint is TLS enabled.

```
kubectl -n confluent get kafka -oyaml
```

```
kubectl -n confluent get zookeeper -oyaml
kubectl -n confluent get schemaregistry -oyaml
kubectl -n confluent get ksqldb -oyaml
kubectl -n confluent get connect -oyaml
kubectl -n confluent get controlcenter -oyaml
```

### Control Center UI

Start a port forwarding to the Control Center UI:

```
kubectl -n confluent port-forward controlcenter-0 9021:9021
```

Now, open your browser and run https://localhost:9021.

The example uses self-signed certs that might have issues with Chrome browser. Try other browsers like Firefox or Safari 
if you encounter such an issue.


## Clean up

Delete CP platform

```
kubectl delete -f $TUTORIAL_HOME/resources/
```

Delete the Cert Manager resources

```
kubectl delete -k  $TUTORIAL_HOME/cert-manager/ca
kubectl delete -k  $TUTORIAL_HOME/cert-manager/self-signed

kubectl delete -f https://github.com/jetstack/cert-manager/releases/download/v1.0.2/cert-manager.yaml
```


## Reference

To enable this capability, the following field is added in each Confluent Platform component CR. 
See the `$TUTORIAL_HOME/resources/confluent-platform.yaml` file.

```yaml
...
spec:
 tls:
   secretName: <name-of-secert-created-by-cert-manager>
 ...
```

