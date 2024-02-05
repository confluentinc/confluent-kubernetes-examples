# Single sign-on authentication for Confluent Control Center

In this workflow scenario, you'll set up single sign-on authentication for Confluent Control Center using OpenID Connect (OIDC). OIDC is an identity layer that allows third-party applications to verify the identity of the end user.

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/control-center-sso
```

## Deploy Confluent for Kubernetes

* Set up the Helm Chart:
```
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
```

* Install Confluent For Kubernetes using Helm:
```
helm upgrade --install operator confluentinc/confluent-for-kubernetes --set kRaftEnabled=true -n confluent
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

## Deploy Keycloak

* Deploy [Keycloak](https://www.keycloak.org/) which is an open source identity and access managment solution. `keycloak.yaml` is used for an example here, this is not supported by Confluent. Therefore, please make sure to use the identity provider as per the organization requirement.
```
kubectl apply -f keycloak.yaml
```

* Validate that Keycloak pod is running:
```
kubectl get pods -n confluent 
```

## Deploy configuration secrets

You'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.

To support the above deployment scenario, you need to provide the following
credentials:

* Component TLS Certificates

* Authentication credentials for KraftController, Kafka, Control Center, remaining CP components, if any.

* RBAC principal credentials

You can either provide your own certificates, or generate test certificates. Follow instructions
in the below `Appendix: Create your own certificates` section to see how to generate certificates
and set the appropriate SANs.


## Provide component TLS certificates

```
kubectl create secret generic tls-group1 \
--from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/generated/server.pem \
--from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
--from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/generated/server-key.pem \
-n confluent
```


## Provide authentication credentials

* Create a Kubernetes secret object for KraftController, Kafka, and Control Center.

This secret object contains file based properties. These files are in the
format that each respective Confluent component requires for authentication
credentials.

```
kubectl create secret generic credential \
--from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
--from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
--from-file=ldap.txt=$TUTORIAL_HOME/ldap.txt \
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
* Create Kafka RBAC credential
```
kubectl create secret generic mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
-n confluent
``` 
* Create Control Center RBAC credential
```
kubectl create secret generic c3-mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/c3-mds-client.txt \
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
kubectl apply -f controlcenter-rolebinding.yaml
```

## Validate

### Validate in Control Center

Use Control Center to monitor the Confluent Platform. You can visit the external URL you set up for Control Center, or visit the URL through a local port forwarding like below:

* Set up port forwarding to Control Center web UI from local machine:

```
kubectl port-forward controlcenter-0 9021:9021 -n confluent
```

* Set up port frowarding for Keyclok:
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
kubectl delete secret rest-credential c3-mds-client mds-client tls-group1 -n confluent
kubectl delete secret mds-token -n confluent
kubectl delete secret credential -n confluent
kubectl delete secret tls-group1 -n confluent
kubectl delete -f keycloak.yaml
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







