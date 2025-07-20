# MDS with OAuth+mTLS to MDS with mTLS only migration for Confluent Platform cluster

In this workflow scenario, you'll set up a RBAC enabled CP Cluster with OAuth+mTLS and then migrate it to RBAC enabled cluster with mTLS only.
Post migration, MDS has mTLS only. Kafka has custom dual auth (bearer+mTLS) listener. Connect, Schema Registry, Rest Proxy have mTLS on server. Control Center has SSO.

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/migration/MDSOAuthMtlstoMtls
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
kubectl apply -f $TUTORIAL_HOME/keycloak_deploy.yaml
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

* Component TLS Certificates

* Authentication credentials for all CP components.

* RBAC principal credentials

You can either provide your own certificates, or generate test certificates. Follow instructions
in the below `Appendix: Create your own certificates` section to see how to generate certificates
and set the appropriate SANs.


## Provide component TLS certificates

```
kubectl create secret generic tls-kraft \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kraft-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kraft-server-key.pem \
  --namespace confluent

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


## Provide authentication credentials

* Create a Kubernetes secret object for KraftController, Kafka.

This secret object contains file based properties. These files are in the
format that each respective Confluent component requires for authentication
credentials.

```
kubectl create secret generic credential \
--from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
--from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
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


## Provide OIDC authentication credentials

* Create a Kubernetes secret object for OIDC credentials

```
kubectl create -n confluent secret generic oauth-jass --from-file=oauth.txt=$TUTORIAL_HOME/oauth_jass.txt
kubectl -n confluent create secret generic oauth-jass-oidc --from-file=oidcClientSecret.txt=$TUTORIAL_HOME/oauth_jass.txt

```

## Deploy Confluent Platform

* Deploy Confluent Platform with MDS having OAuth. CP Cluster has TLS enabled, no mTLS.
```
kubectl apply -f $TUTORIAL_HOME/cp_components1.yaml
```

* Check that all Confluent Platform resources are deployed:

```
kubectl get pods -n confluent
```

## Add custommtls listener in kafka. This listener has mtls authentication.

* Triggers update in kafka to create custom listener. The custom listener will be used for all cp->kafka communication while the internal listeners update during migration.
```
kubectl apply -f $TUTORIAL_HOME/cp_components2.yaml
```

## Create rolebindings for cert principals

* In Dual auth mode, oauth credentials were used in cp->kafka communication. In next step, we will migrate all the cp components clients to mtls, then mtls cert principals will start getting used.
* Add rolebindings for cp components' tls cert principals. mtls-rolebindings contains required rolebindings for the cp components in this example cluster.
* You need to add required rolebindings for all external clients before migrating the cluster to mTLS only.
```
kubectl apply -f $TUTORIAL_HOME/mtls-rolebindings.yaml
```

## Update all cp components (SR, Connect, Rest proxy, C3) and Kafka Rest Class to enable sslClientAuthentication from client side and update their kafka dependency endpoint to communicate on the custom listener.

* Triggers update of SR, Connect, Rest proxy, C3 and Kafka Rest Class. They start communicating with kafka on the custom listener.
```
kubectl apply -f $TUTORIAL_HOME/cp_components3.yaml
```

## Remove oauth from MDS service, this will migrate MDS to mtls only. SR, RP, Connect still have dual auth (oauth+mtls) on server.

* Remove oauth from MDS to migrate MDS to mtls only. Now all S2S auth has mTLS and CP service to clients have dual(oauth+mtls) auth
* If there are any external MDS clients, migrate them to mtls before migrating MDS to mtls.
```
kubectl apply -f $TUTORIAL_HOME/cp_components4.yaml
```

## Remove oauth from SR, RP, Connect server, this will migrate all components to mtls only.

* If there are any external CP components' clients, migrate them to mtls before migrating all components to mtls.
```
kubectl apply -f $TUTORIAL_HOME/cp_components5.yaml
```

* 
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
kubectl delete -f $TUTORIAL_HOME/cp_components5.yaml -n confluent
kubectl delete secret oauth-jass oauth-jass-oidc -n confluent
kubectl delete secret mds-token -n confluent
kubectl delete secret credential -n confluent
kubectl delete secret tls-kraft tls-kafka tls-controlcenter tls-connect tls-kafkarestproxy tls-schemaregistry -n confluent
kubectl delete -f $TUTORIAL_HOME/keycloak_deploy.yaml
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
