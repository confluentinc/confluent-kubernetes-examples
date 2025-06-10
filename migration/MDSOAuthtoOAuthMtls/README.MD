# LDAP RBAC to RBAC with LDAP+mTLS migration for Confluent Platform cluster

In this workflow scenario, you'll set up a RBAC enabled CP Cluster with LDAP user store and then migrate it to RBAC with LDAP user store and mTLS.
Post migration, MDS has both LDAP and mTLS. Kafka has custom dual auth (bearer+mTLS) listener. Connect, Schema Registry, Rest Proxy have basic auth + mTLS on server.

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/migration/MDSLdaptoLdapMtls
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

## Deploy OpenLDAP

This repo includes a Helm chart for [OpenLdap](https://github.com/osixia/docker-openldap). The chart ``values.yaml`` includes the set of principal definitions that Confluent Platform needs for RBAC.

* Deploy OpenLdap
```
helm upgrade --install -f $TUTORIAL_HOME/../../assets/openldap/ldaps-rbac.yaml test-ldap $TUTORIAL_HOME/../../assets/openldap --namespace confluent
```

* Validate that OpenLDAP is running:
```
kubectl get pods -n confluent
```

* Log in to the LDAP pod:
```
kubectl -n confluent exec -it ldap-0 -- bash
``` 

* Run the LDAP search command:

```
ldapsearch -LLL -x -H ldap://ldap.confluent.svc.cluster.local:389 -b 'dc=test,dc=com' -D "cn=mds,dc=test,dc=com" -w 'Developer!'
```

* Exit out of the LDAP pod:
```
exit 
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
--from-file=ldap.txt=$TUTORIAL_HOME/ldap.txt \
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
* Create Kafka RBAC credential
```
kubectl create secret generic mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
-n confluent
``` 
* Create RBAC client credentials for other components
```
kubectl create secret generic c3-mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/c3-client.txt \
-n confluent

kubectl create secret generic connect-mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/connect-client.txt \
-n confluent

kubectl create secret generic sr-mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/sr-client.txt \
-n confluent

kubectl create secret generic krp-mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/krp-client.txt \
-n confluent

```

* Create Kafka REST credential
```
kubectl create secret generic rest-credential \
--from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
--from-file=basic.txt=$TUTORIAL_HOME/bearer.txt \
-n confluent
```

## Deploy Confluent Platform

* Deploy Confluent Platform with MDS having LDAP user store. CP Cluster has TLS enabled, no mTLS.
```
kubectl apply -f $TUTORIAL_HOME/cp_components1.yaml
```

* Check that all Confluent Platform resources are deployed:

```
kubectl get pods -n confluent
```

## Add custombearer listener in kafka. This listener has bearer + mtls authentication.

* Triggers update in kafka to create custom listener. The custom listener will be used for all cp->kafka communication while the internal listeners update during migration.
```
kubectl apply -f $TUTORIAL_HOME/cp_components2.yaml
```

## Update all cp components (SR, Connect, Rest proxy, C3) and Kafka Rest Class to enable sslClientAuthentication from client side and update their kafka dependency endpoint to communicate on the custom listener.

* Triggers update of SR, Connect, Rest proxy, C3 and Kafka Rest Class. They start communicating with kafka on the custom listener.
```
kubectl apply -f $TUTORIAL_HOME/cp_components3.yaml
```

## Add mtls provider in MDS service, this will be added in parallel to already existing ldap provider. Also add mTLS on SR, RP, Connect server.

* Before enabling mTLS on MDS, SR, Connect, RP, You need to enable client side TLS in all external clients of these components.
* If all external clients are migrated, Enable dual auth (Ldap + mTLS) on MDS, SR, RP, Connect.
```
kubectl apply -f $TUTORIAL_HOME/cp_components4.yaml
```

* 
## Validate

### Validate in Control Center

Use Control Center to monitor the Confluent Platform. You can visit the external URL you set up for Control Center, or visit the URL through a local port forwarding like below:

* Set up port forwarding to Control Center web UI from local machine:

```
kubectl port-forward controlcenter-0 9021:9021 -n confluent
```

* Browse to Control Center, use the credentials c3 as user, and c3-secret as password to login to Control Center.
```
https://localhost:9021
```

## Tear down

```
kubectl delete confluentrolebinding --all -n confluent
kubectl delete -f $TUTORIAL_HOME/cp_components4.yaml -n confluent
kubectl delete secret rest-credential c3-mds-client connect-mds-client sr-mds-client krp-mds-client -n confluent
kubectl delete secret mds-token -n confluent
kubectl delete secret credential -n confluent
kubectl delete secret tls-kraft tls-kafka tls-controlcenter tls-connect tls-kafkarestproxy tls-schemaregistry -n confluent
helm delete test-ldap -n confluent
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
