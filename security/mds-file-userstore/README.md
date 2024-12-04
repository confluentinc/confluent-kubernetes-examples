# Security setup

In this workflow scenario, you'll set up a Confluent Platform cluster with the following security:
- File Based User Store in MDS for storing all users
- SASL plain for kafka client authentication
- Full TLS network encryption

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/mds-file-userstore
```

## Create confluent Namespace
```
kubectl create namespace confluent
```

## Deploy Confluent for Kubernetes

#. Set up the Helm Chart:

```
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
```

#. Install Confluent For Kubernetes using Helm:

```
helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace confluent
```

#. Check that the Confluent For Kubernetes pod comes up and is running:

```
kubectl get pods --namespace confluent
```

## Deploy configuration secrets

You'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.

To support the above deployment scenario, you need to provide the following
credentials:

* Component TLS Certificates

* Authentication credentials for Kraft, Kafka, Control Center, remaining CP components

* RBAC principal credentials

You can either provide your own certificates, or generate test certificates.

## Provide TLS certificates

```
    kubectl create secret generic tls-group1 \
      --from-file=fullchain.pem=$TUTORIAL_HOME/../assets/certs/generated/server.pem \
      --from-file=cacerts.pem=$TUTORIAL_HOME/../assets/certs/generated/cacerts.pem \
      --from-file=privkey.pem=$TUTORIAL_HOME/../assets/certs/generated/server-key.pem \
      --namespace confluent
```

## Provide authentication credentials

#. Create a Kubernetes secret object for Kraft and Kafka.

This secret object contains file based properties. These files are in the
format that each respective Confluent component requires for authentication
credentials.
```
     kubectl create secret generic credential \
       --from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
       --from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
       --namespace confluent
```

## Provide file based credentials

* Create a Kubernetes secret object for file based user store.

This secret object contains file based username/password. They kubernetes secret should have key "userstore.txt"
The users must be added in the format <username>:<password>

```
kubectl create secret generic file-secret \
--from-file=userstore.txt=$TUTORIAL_HOME/fileUserPassword.txt \
-n confluent
```

## Provide RBAC principal credentials

#. Create a Kubernetes secret object for MDS:

```
     kubectl create secret generic mds-token \
       --from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../assets/certs/mds-publickey.txt \
       --from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../assets/certs/mds-tokenkeypair.txt \
       --namespace confluent
```

#. Create Kubernetes secret objects for MDS clients:
```
     # Kafka RBAC credential
     kubectl create secret generic mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
       --namespace confluent
     # Control Center RBAC credential
     kubectl create secret generic c3-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/c3-mds-client.txt \
       --namespace confluent
     # Connect RBAC credential
     kubectl create secret generic connect-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/connect-mds-client.txt \
       --namespace confluent
     # Schema Registry RBAC credential
     kubectl create secret generic sr-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/sr-mds-client.txt \
       --namespace confluent
     # ksqlDB RBAC credential
     kubectl create secret generic ksqldb-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/ksqldb-mds-client.txt \
       --namespace confluent
     # Kafka Rest Proxy RBAC credential
     kubectl create secret generic krp-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/krp-mds-client.txt \
       --namespace confluent
     # Kafka REST credential
     kubectl create secret generic rest-credential \
       --from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
       --from-file=basic.txt=$TUTORIAL_HOME/bearer.txt \
       --namespace confluent
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

* Browse to Control Center, use the credentials testuser1 as user, and password1 as password to login to Control Center.
```
https://localhost:9021
```

## Tear down

```
kubectl delete confluentrolebinding --all -n confluent
kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml -n confluent
kubectl delete secret mds-token mds-client c3-mds-client connect-mds-client krp-mds-client sr-mds-client ksqldb-mds-client rest-credential credential -n confluent
kubectl delete secret file-secret -n confluent
kubectl delete secret tls-group1 --namespace confluent
helm delete operator -n confluent
```

