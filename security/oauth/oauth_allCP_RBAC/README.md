# Security setup

In this workflow scenario, you'll set up a Confluent Platform cluster with the following security:
- oauth authentication with RBAC
- Full TLS network encryption using auto-generated certs

Before continuing with the scenario, ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites).

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/oauth/oauth_allCP_RBAC
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

## Provide a Certificate Authority

Confluent For Kubernetes provides auto-generated certificates for Confluent Platform components to use for TLS network encryption. You'll need to generate and provide a Certificate Authority (CA).

Generate a CA pair to use:

```
openssl genrsa -out $TUTORIAL_HOME/ca-key.pem 2048

openssl req -new -key $TUTORIAL_HOME/ca-key.pem -x509 \
  -days 1000 \
  -out $TUTORIAL_HOME/ca.pem \
  -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA"
```

Create a Kubernetes secret for the certificate authority:

```
kubectl create secret tls ca-pair-sslcerts \
  --cert=$TUTORIAL_HOME/ca.pem \
  --key=$TUTORIAL_HOME/ca-key.pem -n confluent
```

## Deploy Keycloak

* Deploy [Keycloak](https://www.keycloak.org/) which is an open source identity and access managment solution. `keycloak.yaml` is used for an example here, this is not supported by Confluent. Therefore, please make sure to use the identity provider as per the organization requirement.
```
kubectl apply -f $TUTORIAL_HOME/../keycloak/keycloak_deploy.yaml
```

* Validate that Keycloak pod is running:
```
kubectl get pods -n confluent 
```

## Create authentication credentials
```
kubectl create -n confluent secret generic oauth-jaas --from-file=oauth.txt=oauth_jaas.txt
kubectl create -n confluent secret generic oauth-jaas-oidc --from-file=oidcClientSecret.txt=oauth_jass.txt
```

## Create a Kubernetes secret object for MDS
```
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../../assets/certs/mds-publickey.txt \
  --from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../../assets/certs/mds-tokenkeypair.txt \
  -n confluent
```

## Deploy Confluent Platform

Deploy Confluent Platform:

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform.yaml -n confluent
```

Check that all Confluent Platform resources are deployed:

```
kubectl get pods --namespace confluent
```

## Create RBAC Rolebindings for Control Center user

Create Control Center Role Binding for a Control Center testuser1 user. In the `controlcenter-testuser1-rolebindings.yaml` file, `163ee8e8-04f8-4de2-ba22-daf394eea8f1` value is used for corresponding sub from keycloak against testuser1

```
kubectl apply -f $TUTORIAL_HOME/controlcenter-testuser1-rolebindings.yaml -n confluent
```

## Validate

### Validate using CLI: 

* Copy kafka.properties in /tmp directory in one of the kafka pods: 
```
kubectl cp kafka.properties  kafka-0:/tmp/kafka.properties -n confluent 
```
* Exec into one of the kafka pods
```
kubectl exec kafka-0 -it bash -n confluent
```
* Run topic command
```
kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 --topic test-topic --create --replication-factor 3 --command-config /tmp/kafka.properties
```

### Validate in Control Center

Use Control Center to monitor the Confluent Platform, and access the created topic, data, and Confluent Platform component. You can visit the external URL you set up for Control Center, or visit the URL
through a local port forwarding like below:

* Set up port forwarding to Control Center web UI from local machine:

```
kubectl port-forward controlcenter-0 9021:9021 --namespace confluent
```
* Set up port frowarding for Keyclok:
```
kubectl port-forward deployment/keycloak 8080:8080 -n confluent 
```

Browse to Control Center, click on Log in via SSO, use the credentials testuser1 as user, and testuser1 as password to login to Control Center.
```
https://localhost:9021
```

## Tear down

```
kubectl delete -f $TUTORIAL_HOME/controlcenter-testuser1-rolebindings.yaml -n confluent
kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml --namespace confluent
kubectl delete -f $TUTORIAL_HOME/../kecloak/keycloak_deploy.yaml
kubectl delete secret mds-token oauth-jaas oauth-jaas-oidc ca-pair-sslcerts -n confluent
helm delete operator -n confluent
```

