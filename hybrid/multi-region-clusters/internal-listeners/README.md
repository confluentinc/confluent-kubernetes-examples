# MRC with Internal Listeners

## Setup - Networking

Depending on your environment, set up Kubernetes networking between the different clusters.

[Example for Azure Kubernetes Service](networking/aks/networking-AKS-README.md)

[Example for Elastic Kubernetes Engine](networking/eks/networking-EKS-README.md)

[Example for Google Kubernetes Engine](networking/gke/networking-GKE-README.md)

## MRC Deployment

In the remaining steps in this README, you'll set up a comprehensive Confluent for Kubernetes deployment with:
- Authentication
- RBAC granular authorization
- TLS network encryption
- External access via Load balancer

To set up a simpler Confluent Platform deployment with no security settings, follow [our basic configuration](README-basic.md)

For this comprehensive deployment, you can either follow the steps in this README to create an MRC deployment or run the

`setup.sh` script to fully deploy MRC with a single command as follows:

```
./setup.sh
```

## Setup - Deploy Confluent for Kubernetes

`export TUTORIAL_HOME=confluent-kubernetes-examples/hybrid/multi-region-clusters/internal-listeners`

Deploy Confluent for Kubernetes to each Kubernetes cluster.

```
# Set up the Helm Chart
helm repo add confluentinc https://packages.confluent.io/helm

# Install Confluent For Kubernetes
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n central --kube-context mrc-central
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n east --kube-context mrc-east
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n west --kube-context mrc-west
```

## Setup - External DNS (Optional)

If external access is needed, you can automatically create DNS records in your DNS provider using external-dns.
Example below demonstrates setting up external-dns to manage records in Google Cloud DNS. Please update the `domainFilters` in `external-dns-values.yaml` to match your domain. More information on external-dns can be
found here: https://github.com/kubernetes-sigs/external-dns

```
# Setup the Helm chart
helm repo add bitnami https://charts.bitnami.com/bitnami

# Install External DNS
helm install external-dns -f $TUTORIAL_HOME/external-dns-values.yaml --set namespace=central,txtOwnerId=mrc-central bitnami/external-dns -n central --kube-context mrc-central
helm install external-dns -f $TUTORIAL_HOME/external-dns-values.yaml --set namespace=east,txtOwnerId=mrc-east bitnami/external-dns -n east --kube-context mrc-east
helm install external-dns -f $TUTORIAL_HOME/external-dns-values.yaml --set namespace=west,txtOwnerId=mrc-west bitnami/external-dns -n west --kube-context mrc-west
```

## Setup - OpenLDAP

This repo includes a Helm chart for `OpenLDAP
<https://github.com/osixia/docker-openldap>`. The chart ``values.yaml``
includes the set of principal definitions that Confluent Platform needs for
RBAC.

```
# Deploy OpenLDAP
helm upgrade --install -f $TUTORIAL_HOME/../../../assets/openldap/ldaps-rbac.yaml open-ldap $TUTORIAL_HOME/../../../assets/openldap -n central --kube-context mrc-central

# Validate that OpenLDAP is running:
kubectl get pods -n central --context mrc-central

# Log in to the LDAP pod:
kubectl exec -it ldap-0 -n central --context mrc-central -- bash

# Run the LDAP search command:
ldapsearch -LLL -x -H ldap://ldap-0:389 -b 'dc=test,dc=com' -D "cn=mds,dc=test,dc=com" -w 'Developer!'

# Exit out of the LDAP pod:
exit
```

## Set up - Deploy Confluent Platform

### Deploy configuration secrets
You'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating) can be done outside the Confluent For Kubernetes.
You define the configuration secret and then tell Confluent For Kubernetes where to find the configuration.

To support this deployment scenario, you need to provide the following credentials:

- Certificate authority - private key and certificate
- Authentication credentials for Zookeeper, Kafka, Control Center, SchemaRegistry
- RBAC principal credentials

For the purposes of this example, we will use CFKs auto-generated certs feature.

#### Provide operator CA TLS certificates for auto generating certs
```
kubectl create secret tls ca-pair-sslcerts \
  --cert=$TUTORIAL_HOME/../../../assets/certs/generated/ca.pem \
  --key=$TUTORIAL_HOME/../../../assets/certs/generated/ca-key.pem \
  -n central --context mrc-central

kubectl create secret tls ca-pair-sslcerts \
  --cert=$TUTORIAL_HOME/../../../assets/certs/generated/ca.pem \
  --key=$TUTORIAL_HOME/../../../assets/certs/generated/ca-key.pem \
  -n east --context mrc-east
  
kubectl create secret tls ca-pair-sslcerts \
  --cert=$TUTORIAL_HOME/../../../assets/certs/generated/ca.pem \
  --key=$TUTORIAL_HOME/../../../assets/certs/generated/ca-key.pem \
  -n west --context mrc-west
```

### Configure service account

In order for rack awareness to be configured, you'll need to use a service account that is configured with a clusterrole/role that provides get/list access to both the pods and nodes resources. This is required as Kafka pods will curl kubernetes api for the node it is scheduled on using the mounted serviceAccountToken.
```
kubectl apply -f $TUTORIAL_HOME/confluent-platform/rack-awareness/service-account-rolebinding-central.yaml --context mrc-central
kubectl apply -f $TUTORIAL_HOME/confluent-platform/rack-awareness/service-account-rolebinding-east.yaml --context mrc-east
kubectl apply -f $TUTORIAL_HOME/confluent-platform/rack-awareness/service-account-rolebinding-west.yaml --context mrc-west
```

### Configure credentials for Authentication and Authorization

In this step you'll configure the credentials required for setting up authentication and authorization:
- Zookeeper - digest
- Kafka - SASL/Plain
- Schema Registry - basic
- Control Center - bearer

```
kubectl create secret generic credential \
  --from-file=digest-users.json=$TUTORIAL_HOME/confluent-platform/credentials/zk-users-server.json \
  --from-file=digest.txt=$TUTORIAL_HOME/confluent-platform/credentials/zk-users-client.txt \
  --from-file=plain-users.json=$TUTORIAL_HOME/confluent-platform/credentials/kafka-users-server.json \
  --from-file=plain.txt=$TUTORIAL_HOME/confluent-platform/credentials/kafka-users-client.txt \
  --from-file=ldap.txt=$TUTORIAL_HOME/confluent-platform/credentials/ldap-client.txt \
  -n central --context mrc-central
  
kubectl create secret generic credential \
  --from-file=digest-users.json=$TUTORIAL_HOME/confluent-platform/credentials/zk-users-server.json \
  --from-file=digest.txt=$TUTORIAL_HOME/confluent-platform/credentials/zk-users-client.txt \
  --from-file=plain-users.json=$TUTORIAL_HOME/confluent-platform/credentials/kafka-users-server.json \
  --from-file=plain.txt=$TUTORIAL_HOME/confluent-platform/credentials/kafka-users-client.txt \
  --from-file=ldap.txt=$TUTORIAL_HOME/confluent-platform/credentials/ldap-client.txt \
  -n east --context mrc-east
  
kubectl create secret generic credential \
  --from-file=digest-users.json=$TUTORIAL_HOME/confluent-platform/credentials/zk-users-server.json \
  --from-file=digest.txt=$TUTORIAL_HOME/confluent-platform/credentials/zk-users-client.txt \
  --from-file=plain-users.json=$TUTORIAL_HOME/confluent-platform/credentials/kafka-users-server.json \
  --from-file=plain.txt=$TUTORIAL_HOME/confluent-platform/credentials/kafka-users-client.txt \
  --from-file=ldap.txt=$TUTORIAL_HOME/confluent-platform/credentials/ldap-client.txt \
  -n west --context mrc-west
```

### Provide RBAC principal credentials and role bindings
#### Kubernetes secret object for MDS:
```
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../../assets/certs/mds-publickey.txt \
  --from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../../assets/certs/mds-tokenkeypair.txt \
  -n central --context mrc-central
  
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../../assets/certs/mds-publickey.txt \
  --from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../../assets/certs/mds-tokenkeypair.txt \
  -n east --context mrc-east
  
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../../assets/certs/mds-publickey.txt \
  --from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../../assets/certs/mds-tokenkeypair.txt \
  -n west --context mrc-west
```
#### Kafka RBAC credential
```
kubectl create secret generic mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/confluent-platform/credentials/mds-client.txt \
  -n central --context mrc-central
  
kubectl create secret generic mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/confluent-platform/credentials/mds-client.txt \
  -n east --context mrc-east
  
kubectl create secret generic mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/confluent-platform/credentials/mds-client.txt \
  -n west --context mrc-west
```
#### Schema Registry RBAC credential
```
kubectl create secret generic sr-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/confluent-platform/credentials/sr-mds-client.txt \
  -n central --context mrc-central
  
kubectl create secret generic sr-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/confluent-platform/credentials/sr-mds-client.txt \
  -n east --context mrc-east
  
kubectl create secret generic sr-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/confluent-platform/credentials/sr-mds-client.txt \
  -n west --context mrc-west
```
#### Control Center RBAC credential
```
kubectl create secret generic c3-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/confluent-platform/credentials/c3-mds-client.txt \
  -n central --context mrc-central
```
#### Kafka REST credential
```
kubectl create secret generic kafka-rest-credential \
  --from-file=bearer.txt=$TUTORIAL_HOME/confluent-platform/credentials/mds-client.txt \
  -n central --context mrc-central
  
kubectl create secret generic kafka-rest-credential \
  --from-file=bearer.txt=$TUTORIAL_HOME/confluent-platform/credentials/mds-client.txt \
  -n east --context mrc-east
  
kubectl create secret generic kafka-rest-credential \
  --from-file=bearer.txt=$TUTORIAL_HOME/confluent-platform/credentials/mds-client.txt \
  -n west --context mrc-west
```
#### Rolebindings for Schema Registry and Control Center
We need to create resource owner rolebindings for the topic and group id used for Schema Registry.
```
kubectl apply -f $TUTORIAL_HOME/confluent-platform/rolebindings/mrc-rolebindings.yaml -n central --context mrc-central
kubectl apply -f $TUTORIAL_HOME/confluent-platform/rolebindings/mrc-rolebindings.yaml -n east --context mrc-east
kubectl apply -f $TUTORIAL_HOME/confluent-platform/rolebindings/mrc-rolebindings.yaml -n west --context mrc-west

kubectl apply -f $TUTORIAL_HOME/confluent-platform/rolebindings/c3-rolebindings.yaml --context mrc-central
```

### Deploy ZK and Kafka clusters
Here, you'll deploy a 3 node Zookeeper cluster - one node each in the `central`, `east` and `west` regions.
You'll deploy 1 Kafka cluster with 6 brokers - two in `central`, two in `east` and two in `west` regions.
```
kubectl apply -f $TUTORIAL_HOME/confluent-platform/zookeeper/zookeeper-central.yaml --context mrc-central
kubectl apply -f $TUTORIAL_HOME/confluent-platform/zookeeper/zookeeper-east.yaml --context mrc-east
kubectl apply -f $TUTORIAL_HOME/confluent-platform/zookeeper/zookeeper-west.yaml --context mrc-west

kubectl apply -f $TUTORIAL_HOME/confluent-platform/kafka/kafka-central.yaml --context mrc-central
kubectl apply -f $TUTORIAL_HOME/confluent-platform/kafka/kafka-east.yaml --context mrc-east
kubectl apply -f $TUTORIAL_HOME/confluent-platform/kafka/kafka-west.yaml --context mrc-west
```

### Create Kafka REST class
```
kubectl apply -f $TUTORIAL_HOME/confluent-platform/kafkarestclass.yaml -n central --context mrc-central
kubectl apply -f $TUTORIAL_HOME/confluent-platform/kafkarestclass.yaml -n east --context mrc-east
kubectl apply -f $TUTORIAL_HOME/confluent-platform/kafkarestclass.yaml -n west --context mrc-west
```

### Deploy Schema Registry and Control Center
Now, you'll deploy a 5 node Schema Registry cluster - 1 replica in `central`, 2 in `east` and 2 in the `west` regions; 
and a single instance of Control Center running in the `central` region. 
```
kubectl apply -f $TUTORIAL_HOME/confluent-platform/schemaregistry/schemaregistry-central.yaml --context mrc-central
kubectl apply -f $TUTORIAL_HOME/confluent-platform/schemaregistry/schemaregistry-east.yaml --context mrc-east
kubectl apply -f $TUTORIAL_HOME/confluent-platform/schemaregistry/schemaregistry-west.yaml --context mrc-west

kubectl apply -f $TUTORIAL_HOME/confluent-platform/controlcenter.yaml --context mrc-central
```

## Check Deployment
You can log in to Control Center by running:
```
kubectl confluent dashboard controlcenter
```
The credentials required for logging in are `c3:c3-secret`.

You should see a single cluster with 6 brokers with broker ids: `0, 1, 10, 11, 20, 21`

Under the `Topics` section, you should also see a single topic `_schemas_mrc` created for the stretch schema registry deployment.
The connection to schema registry is validated if you see the `Schemas` tab under any of the topics.

## Tear down
You can either follow the steps in this README to teardown the MRC deployment or run the `teardown.sh` to fully destroy the MRC deployment with a single command as follows:

```
./teardown.sh
```

```
# Destroy Control Center
kubectl delete -f $TUTORIAL_HOME/confluent-platform/controlcenter.yaml --context mrc-central

# Destroy Schema Registry
kubectl delete -f $TUTORIAL_HOME/confluent-platform/schemaregistry/schemaregistry-west.yaml --context mrc-west
kubectl delete -f $TUTORIAL_HOME/confluent-platform/schemaregistry/schemaregistry-east.yaml --context mrc-east
kubectl delete -f $TUTORIAL_HOME/confluent-platform/schemaregistry/schemaregistry-central.yaml --context mrc-central

# Delete Control Center role bindings
kubectl delete -f $TUTORIAL_HOME/confluent-platform/rolebindings/c3-rolebindings.yaml --context mrc-central

# Delete Schema Registry role bindings
kubectl delete -f $TUTORIAL_HOME/confluent-platform/rolebindings/mrc-rolebindings.yaml -n west --context mrc-west
kubectl delete -f $TUTORIAL_HOME/confluent-platform/rolebindings/mrc-rolebindings.yaml -n east --context mrc-east
kubectl delete -f $TUTORIAL_HOME/confluent-platform/rolebindings/mrc-rolebindings.yaml -n central --context mrc-central

# Delete Kafka REST class
kubectl delete -f $TUTORIAL_HOME/confluent-platform/kafkarestclass.yaml -n west --context mrc-west
kubectl delete -f $TUTORIAL_HOME/confluent-platform/kafkarestclass.yaml -n east --context mrc-east
kubectl delete -f $TUTORIAL_HOME/confluent-platform/kafkarestclass.yaml -n central --context mrc-central

# Destroy Kafka
kubectl delete -f $TUTORIAL_HOME/confluent-platform/kafka/kafka-west.yaml --context mrc-west
kubectl delete -f $TUTORIAL_HOME/confluent-platform/kafka/kafka-east.yaml --context mrc-east
kubectl delete -f $TUTORIAL_HOME/confluent-platform/kafka/kafka-central.yaml --context mrc-central

# Destroy Zookeeper
kubectl delete -f $TUTORIAL_HOME/confluent-platform/zookeeper/zookeeper-west.yaml --context mrc-west
kubectl delete -f $TUTORIAL_HOME/confluent-platform/zookeeper/zookeeper-east.yaml --context mrc-east
kubectl delete -f $TUTORIAL_HOME/confluent-platform/zookeeper/zookeeper-central.yaml --context mrc-central

# Delete Kafka REST credential
kubectl delete secret kafka-rest-credential -n west --context mrc-west
kubectl delete secret kafka-rest-credential -n east --context mrc-east
kubectl delete secret kafka-rest-credential -n central --context mrc-central

# Delete Control Center RBAC credential
kubectl delete secret c3-mds-client -n central --context mrc-central

# Delete Schema Registry RBAC credential
kubectl delete secret sr-mds-client -n west --context mrc-west
kubectl delete secret sr-mds-client -n east --context mrc-east
kubectl delete secret sr-mds-client -n central --context mrc-central

# Delete Kafka RBAC credential
kubectl delete secret mds-client -n west --context mrc-west
kubectl delete secret mds-client -n east --context mrc-east
kubectl delete secret mds-client -n central --context mrc-central

# Delete Kubernetes secret object for MDS:
kubectl delete secret mds-token -n west --context mrc-west
kubectl delete secret mds-token -n east --context mrc-east
kubectl delete secret mds-token -n central --context mrc-central

# Delete credentials for Authentication and Authorization
kubectl delete secret credential -n west --context mrc-west
kubectl delete secret credential -n east --context mrc-east
kubectl delete secret credential -n central --context mrc-central

# Delete CFK CA TLS certificates for auto generating certs
kubectl delete secret ca-pair-sslcerts -n west --context mrc-west
kubectl delete secret ca-pair-sslcerts -n east --context mrc-east
kubectl delete secret ca-pair-sslcerts -n central --context mrc-central

# Delete service account
kubectl delete -f $TUTORIAL_HOME/confluent-platform/rack-awareness/service-account-rolebinding-west.yaml --context mrc-west
kubectl delete -f $TUTORIAL_HOME/confluent-platform/rack-awareness/service-account-rolebinding-east.yaml --context mrc-east
kubectl delete -f $TUTORIAL_HOME/confluent-platform/rack-awareness/service-account-rolebinding-central.yaml --context mrc-central

# Uninstall Open LDAP
helm uninstall open-ldap -n central --kube-context mrc-central

# Uninstall external-dns (if needed)
# Allow 1-2 mins for external-dns to clean up DNS records
helm uninstall external-dns -n west --kube-context mrc-west
helm uninstall external-dns -n east --kube-context mrc-east
helm uninstall external-dns -n central --kube-context mrc-central

# Uninstall CFK
helm uninstall cfk-operator -n west --kube-context mrc-west
helm uninstall cfk-operator -n east --kube-context mrc-east
helm uninstall cfk-operator -n central --kube-context mrc-central

# Delete namespace
kubectl delete ns west --context mrc-west
kubectl delete ns east --context mrc-east
kubectl delete ns central --context mrc-central
```

## Troubleshooting

### Check that Kafka is using the Zookeeper deployments

Look at the ZK nodes.

```
$ kubectl exec -it zookeeper-0 -n central -c zookeeper --context mrc-central -- bash

bash-4.4$ zookeeper-shell 127.0.0.1:2181

ls /mrc/brokers/ids
[0, 1, 10, 11, 20, 21]

# You should see 6 brokers ^
```