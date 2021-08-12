## Use Cert Manager to provide certificates for use

[Cert-manager](https://cert-manager.io/) builds on top of Kubernetes to provide X.509 
certificates and issuers as first-class resource types.

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

For the purpose of this scenario worklow, use this step to install Cert-manager:

```
kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.0.2/cert-manager.yaml
```


<b>Note</b>: Use one of the Issuer describe below    
     
## Use CA Issuer

```
kubectl -k cert-manager/ca apply
```
    
If you need to change the certificate SAN or secret names please changes `cert-manager/ca/certificate.yaml`. Current `certificate.yaml` is 
configured with namespace `operator` and opinionated name of CP platform.

- Check issuers: `kubectl get issuers`

```
$ kubectl get issuers
NAME        READY   AGE
ca-issuer   True    7d19h
```

- Check Certificates: `kubectl get certificates`

```
$ kubectl get certificate
NAME                READY   SECRET                      AGE
ca-c3-cert          True    controlcenter-tls-group3    7d19h
ca-kafka-cert       True    kafka-tls-group3            7d19h
ca-ksql-cert        True    ksql-tls-group3             7d19h
ca-sr-cert          True    schemaregistry-tls-group3   7d19h
ca-zookeeper-cert   True    zookeeper-tls-group3        7d19h
```

The example uses certificate for each CP component. The user can create one secret
to work for all CP component by using the right SAN information.

## Cert-Manager with Self-Signed Issuer

```
kubectl -k $TUTORIAL_HOME/cert-manager/self-signed apply
```

If you need to change the certificate SAN or secret names please changes `cert-manager/self-signed/certificate.yaml`. Current `certificate.yaml` is configured with namespace `operator` and opinionated name of CP platform. 

- Check issuers: `kubectl -n operator get issuers`
- Check Certificates: `kubectl -n operator get certificates`

## Cert-Manager with Let's Encrypt Issuer

For this, look on the cert-manager and create the kustomize bundle by looking on the example in cert-manager/ folder. More information here https://cert-manager.io/docs/configuration/acme/

## Deploy CP platform

Before applying following commands make sure all the secrets objects are created by running
`kubectl -n operator get secrets`. The secret name can be checked with output of `kubectl -n operator get certificates` 

The `resources/platform.yaml` is using these generate secrets through cert-manager to run in the TLS mode. The `platform.yaml` is not configured with any authentication.

- `kubectl apply -f resources/` 

# Validation

## Status

Status section provides information to use the Component like endpoints, internal topics etc

- `kubectl -n operator get kafka -oyaml`
- `kubectl -n operator get zookeeper -oyaml`
- `kubectl -n operator get schemaregistry -oyaml`
- `kubectl -n operator get ksqldb -oyaml`
- `kubectl -n operator get connect -oyaml`
- `kubectl -n operator get controlcenter -oyaml`

### ControlCenter UI

- `kubectl -n operator port-forward controlcenter-0 9021:9021`

Now, open your browser and run https://localhost:9021

<b>Note</b>: The example uses self-signed certs that might have issue in chrome browser, use other browsers if issue encountered; use firefox or safari.

## Create A Kafka Topic

If you want to create kafka topic through Confluent operator then run follow commands

- `kubectl apply -f ../../../config/samples/kafkatopic/topic.yaml`

## Delete CP platform

- `kubectl delete -f resources/`


## Reference

To enable this capability, the following field is added in each CP CR. Take a looks on the `resources/platform.yaml` file.

```yaml
...
spec:
 tls:
   secretName: <name-of-secert-created-by-cert-manager>
 ...
```

