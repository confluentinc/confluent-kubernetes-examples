# MRC with External Access

## MRC Deployment

In the remaining steps in this README, you'll set up a comprehensive Confluent for Kubernetes deployment with:
- Authentication
- RBAC granular authorization
- TLS network encryption
- External access via Load balancer

For this comprehensive deployment, you can either follow the steps in this README to create an MRC deployment or run the

`setup.sh` script to fully deploy MRC with a single command as follows:

```
./setup.sh
```

**This tutorial uses the external access domain `platformops.dev.gcp.devel.cpdev.cloud`. If using a different domain, then change this value in the `domain`, `endpoint`, and `bootstrapEndpoint` fields in the YAML files under `/confluent-platform`.**

## Kafka External Access Options

In this tutorial, the configurations will be using LoadBalancer for all external access. To use a different external access type, look at the tutorial [here](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/networking) and the details below.

If RBAC is enabled, the `kafka.spec.listeners.replication.externalAccess` field will also be used to create a token listener. This is handled differently in each of the external access types (expected URLs can also be seen in the status under token/replication listener) -

### NodePort
With an offset of 30000 and replicas = 3, the bootstrap services will use ports 30000/30001 for replication and token. Then the ports will alternate betwen replication/token. So replication listener is on 30002/30004/30006, and token listener is on 30003/30005/30007.

### StaticForPortBasedRouting
Similar to node port, with an offset of 9094 and replicas = 3, the bootstrap service will use port 9093. Then the ports will alternate between replication/token. So replication listener is on 9094/9096/9098, and token listener is on 9095/9097/9099.

Rules for the Ingress resource should look similar to this, **note that we only need the token listener on the bootstrap service**.

```
  rules:
    - host: kafka-central.platformops.dev.gcp.devel.cpdev.cloud
      http:
        paths:
          - pathType: ImplementationSpecific
            backend:
              service:
                name: kafka-0-internal
                port:
                  number: 9072
          - pathType: ImplementationSpecific
            backend:
              service:
                name: kafka-0-internal
                port:
                  number: 9073
          - pathType: ImplementationSpecific
            backend:
              service:
                name: kafka-bootstrap
                port:
                  number: 9073
```

### Route
Separate routes will be created for replication listeners and token listeners. Token listener will use the domain `[brokerPrefix]-token[replica].[domain]` instead of the usual `[brokerPrefix][replica].[domain]`

For example, if the domain is `example.com` and the brokerPrefix is default `b`, then the replication listener domains will be `b0.example.com, b1.example.com, b2.example.com`
The token listener domains will be `b-token0.example.com, b-token1.example.com, b-token2.example.com`

### StaticForHostBasedRouting
Similar to routes, separate routes will be created for replication listeners and token listeners. Token listener will use the domain `[brokerPrefix]-token[replica].[domain]` instead of the usual `[brokerPrefix][replica].[domain]`

For example, if the domain is `example.com` and the brokerPrefix is default `b`, then the replication listener domains will be `b0.example.com, b1.example.com, b2.example.com`
The token listener domains will be `b-token0.example.com, b-token1.example.com, b-token2.example.com`

As a result, the Ingress resource should include rules that look something like this, using a different host for token and replication listeners:

```
  rules:
    - host: b0.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kafka-0-internal
                port:
                  number: 9072
    - host: b-token0.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kafka-0-internal
                port:
                  number: 9073
```

## Schema Registry Options

Schema registry can be deployed in either active-passive mode or not. In active-passive, the schema registries in different regions need to communicate with each other so they can forward requests to the leader.

To deploy in active-passive mode, the following requirements have to be met:

1. Communication between schema registries done through external listener
  - Set the server configOverride `inter.instance.listener.name=EXTERNAL`

2. External access has to be defined on the external listener, and must be using loadBalancer. **Other methods not supported because active-passive schema registry forces port 8081**
  - Set up `spec.listeners.external.externalAccess` to use a load balancer

3. Schema registry is able to elect a leader
  - Set the server configOverride `leader.eligibility=false` on passive cluster which shouldn't include the leader, and `true` on at least one (default `true`)

## Setup - Deploy Confluent for Kubernetes

`export TUTORIAL_HOME=confluent-kubernetes-examples/hybrid/multi-region-clusters/external-access`

Deploy Confluent for Kubernetes to each Kubernetes cluster.

The deployment will be done with a custom `values.yaml` file which includes a SAN on the auto-generated certs for your domain `*.platformops.dev.gcp.devel.cpdev.cloud`. **If you are using a different domain, modify this file first**

```

# Set up the Helm Chart
helm repo add confluentinc https://packages.confluent.io/helm

# Install Confluent For Kubernetes
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n central --values $TUTORIAL_HOME/values.yaml --kube-context mrc-central
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n east --values $TUTORIAL_HOME/values.yaml --kube-context mrc-east
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n west --values $TUTORIAL_HOME/values.yaml --kube-context mrc-west
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

### Create loadbalancer for LDAP on central region
```
kubectl apply -f $TUTORIAL_HOME/ldap-loadbalancer.yaml -n central --context mrc-central
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
  --key=$TUTORIAL_HOME/../../assets/certs/generated/ca-key.pem \
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

#### Kafka metric reporter credential (using replication listener credentials)
```
kubectl create secret generic metric-creds \
  --from-file=plain.txt=$TUTORIAL_HOME/confluent-platform/credentials/metric-users-client.txt \
  -n central --context mrc-central

kubectl create secret generic metric-creds \
  --from-file=plain.txt=$TUTORIAL_HOME/confluent-platform/credentials/metric-users-client.txt \
  -n east --context mrc-east

kubectl create secret generic metric-creds \
  --from-file=plain.txt=$TUTORIAL_HOME/confluent-platform/credentials/metric-users-client.txt \
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

# Delete credentials for metric reporter using replication listener
kubectl delete secret metric-creds -n west --context mrc-west
kubectl delete secret metric-creds -n east --context mrc-east
kubectl delete secret metric-creds -n central --context mrc-central

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

### Kafka not starting up

If you see in the ZK logs

```
org.apache.zookeeper.server.NettyServerCnxnFactory exceptionCaught - Exception caught
java.lang.NullPointerException
```

or

```
Have smaller server identifier, so dropping the connection
```

Try to restart the Zookeeper leader (by deleting that pod) and wait for it to come up again.

The root cause of this error is likely to be https://issues.apache.org/jira/browse/ZOOKEEPER-3988 which is fixed in Zookeeper 3.6.4 and 3.7.1/3. Upgrading to Confluent for Kubernetes 2.6.1 and Confluent Platform 7.4.1 is recommended.

### Check that Kafka is using the Zookeeper deployments

Look at the ZK nodes.

```
$ kubectl exec -it zookeeper-0 -n central -c zookeeper --context mrc-central -- bash

bash-4.4$ zookeeper-shell 127.0.0.1:2181

ls /mrc/brokers/ids
[0, 1, 10, 11, 20, 21]

# You should see 6 brokers ^
```