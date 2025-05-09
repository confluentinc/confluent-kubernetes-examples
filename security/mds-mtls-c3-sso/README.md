# Security setup

In this workflow scenario, you'll set up a Confluent Platform cluster with the following security:
- Full TLS network encryption with user provided certificates
- mTLS authentication on MDS Server for RBAC, along with mTLS on all cp components
- single sign-on authentication for Confluent Control Center using OpenID Connect (OIDC). OIDC is an identity layer that allows third-party applications to verify the identity of the end user.

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/mds-mtls-c3-sso
```

## Create confluent Namespace
```
kubectl create namespace confluent
```

## Deploy Confluent for Kubernetes

* Set up the Helm Chart:
```
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
```

* Install Confluent For Kubernetes using Helm:
```
helm upgrade --install operator confluentinc/confluent-for-kubernetes -n confluent
```

* Check that the Confluent for Kubernetes pod comes up and is running:
```
kubectl get pods -n confluent
```

## Deploy Keycloak

* Deploy [Keycloak](https://www.keycloak.org/) which is an open source identity and access managment solution. `keycloak.yaml` is used for an example here, this is not supported by Confluent. Therefore, please make sure to use the identity provider as per the organization requirement.
```
kubectl apply -f $TUTORIAL_HOME/keycloak.yaml
```

* Validate that Keycloak pod is running:
```
kubectl get pods -n confluent 
```

## Create TLS certificates

In this scenario, you'll configure authentication using the mTLS mechanism. With mTLS, Confluent components and clients use TLS certificates for authentication. The certificate has a CN that identifies the principal name.

Each Confluent component service should have its own TLS certificate. In this scenario, you'll
generate a server certificate for each Confluent component service. Follow [these instructions](../../assets/certs/component-certs/README.md) to generate these certificates.

## Deploy configuration secrets

You'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.

To support the above deployment scenario, you need to provide the following
credentials:

* Component TLS Certificates. The principal extracted from these certificates will be used for Authentication

* File Based User Credentials

* RBAC principal credentials

You can either provide your own certificates, or generate test certificates. Follow instructions
in the below `Appendix: Create your own certificates` section to see how to generate certificates
and set the appropriate SANs.


## Provide component TLS certificates

```
export TUTORIAL_HOME=<Tutorial directory>/mds-mtls-c3-sso

kubectl create secret generic tls-kafka \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-controlcenter \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/controlcenter-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/controlcenter-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-schemaregistry \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/schemaregistry-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/schemaregistry-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-connect \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/connect-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/connect-server-key.pem \
  --namespace confluent
  
kubectl create secret generic tls-kafkarestproxy \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafkarestproxy-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafkarestproxy-server-key.pem \
  --namespace confluent

```


## Provide OIDC authentication credentials

* Create a Kubernetes secret object for OIDC credentials

```
kubectl create secret generic oidccredential \
--from-file=oidcClientSecret.txt=$TUTORIAL_HOME/oidcClientSecret.txt \
-n confluent
```

## Provide RBAC principal credentials

* Create a Kubernetes secret object for MDS:

```
kubectl create secret generic mds-token \
--from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../assets/certs/mds-publickey.txt \
--from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../assets/certs/mds-tokenkeypair.txt \
-n confluent
```

## Deploy Confluent Platform

* Deploy Confluent Platform
```
kubectl apply -f $TUTORIAL_HOME/confluent-platform.yaml
```

* Check that all Confluent Platform resources are deployed:

```
kubectl get pods -n confluent
```

## Create RBAC Rolebindings for Control Center user

```
kubectl apply -f $TUTORIAL_HOME/controlcenter-rolebinding.yaml
```

## Validate

### Validate in Control Center

Use Control Center to monitor the Confluent Platform. You can visit the external URL you set up for Control Center, or visit the URL through a local port forwarding like below:

* Set up port forwarding to Control Center web UI from local machine:

```
kubectl port-forward controlcenter-0 9021:9021 -n confluent
```

* Set up port forwarding for Keycloak:
```
kubectl port-forward deployment/keycloak 8080:8080 -n confluent 
```

* Browse to Control Center, click on `Log in via SSO`, use the credentials user1 as user, and user1 as password to login to Control Center.
```
https://localhost:9021
```

## Tear down

```
kubectl delete confluentrolebinding --all -n confluent
kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml -n confluent
kubectl delete secret mds-token -n confluent
kubectl delete secret oidccredential -n confluent
kubectl delete secret tls-kafka tls-connect tls-schemaregistry tls-kafkarestproxy tls-controlcenter --namespace confluent
kubectl delete -f $TUTORIAL_HOME/keycloak.yaml
helm delete operator -n confluent
```
## Appendix: Create your own certificates

When testing, it's often helpful to generate your own certificates to validate the architecture and deployment. You'll want both these to be represented in the certificate SAN:

* external domain names
* internal Kubernetes domain names
* Install libraries on Mac OS

The internal Kubernetes domain name depends on the namespace you deploy to. If you deploy to confluent namespace, then the internal domain names will be:
* .kraftcontroller.confluent.svc.cluster.local
* .kafka.confluent.svc.cluster.local
* .confluent.svc.cluster.local

Create your certificates by following the steps:
* Install libraries on Mac OS
```
brew install cfssl
```
* Create Certificate Authority
```
mkdir $TUTORIAL_HOME/../../assets/certs/generated && cfssl gencert -initca $TUTORIAL_HOME/../../assets/certs/ca-csr.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/ca -
```
* Validate Certificate Authority
```
openssl x509 -in $TUTORIAL_HOME/../../assets/certs/generated/ca.pem -text -noout
```
* Create server certificates with the appropriate SANs (SANs listed in server-domain.json)
```
cfssl gencert -ca=$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
-ca-key=$TUTORIAL_HOME/../../assets/certs/generated/ca-key.pem \
-config=$TUTORIAL_HOME/../../assets/certs/ca-config.json \
-profile=server $TUTORIAL_HOME/../../assets/certs/server-domain.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/server
``` 

* Validate server certificate and SANs
```
openssl x509 -in $TUTORIAL_HOME/../../assets/certs/generated/server.pem -text -noout
```
