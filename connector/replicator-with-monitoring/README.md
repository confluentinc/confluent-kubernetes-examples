# Replicator

Confluent Replicator allows you to easily and reliably replicate topics from one Kafka cluster to another. In addition to copying the messages, Replicator will create topics as needed preserving the topic configuration in the source cluster. This includes preserving the number of partitions, the replication factor, and any configuration overrides specified for individual topics. Replicator is implemented as a connector.

In this scenario example, you'll deploy two Confluent clusters. One is the source cluster, and one is the destination cluster.  
You will also deploy a Connect cluster.  You'll deploy Confluent Replicator on the Connect cluster, where it will copy topic messages from the source cluster and write to the destination cluster.

Note: You can deploy Replicator near the destination cluster or the source cluster, and it will work either way. However, a best practice is to deploy Replicator closer to the destination cluster for reliability and performance over networks.

This scenario example document describes how to configure and deploy Confluent Replicator in one configuration scenario through Confluent for Kubernetes. To read more about the use cases, architectures and various configuration scenarios, please see the [Confluent Replicator documentation](https://docs.confluent.io/platform/current/multi-dc-deployments/replicator/index.html#replicator-detail).

## Set up Pre-requisites

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/connector/replicator-with-monitoring
```

Create two namespaces, one for the source cluster and one for the destination cluster.

```
kubectl create ns source
kubectl create ns destination
```

Deploy Confluent for Kubernetes (CFK) in cluster mode, so that the one CFK instance can manage Confluent deployments in multiple namespaces. Here, CFk is deployed to the `default` namespace.

```
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes \
  --namespace default \
  --set namespaced=false
```

Confluent For Kubernetes provides auto-generated certificates for Confluent Platform components to use for inter-component TLS. You'll need to generate and provide a Root Certificate Authority (CA).

Generate a CA pair to use in this tutorial:

```
openssl genrsa -out $TUTORIAL_HOME/ca-key.pem 2048
openssl req -new -key $TUTORIAL_HOME/ca-key.pem -x509 \
  -days 1000 \
  -out $TUTORIAL_HOME/ca.pem \
  -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA"
```

Then, provide the certificate authority as a Kubernetes secret `ca-pair-sslcerts` to be used to 
generate the auto-generated certs, in both the source and destination namespaces:

```
kubectl create secret tls ca-pair-sslcerts \
  --cert=$TUTORIAL_HOME/ca.pem \
  --key=$TUTORIAL_HOME/ca-key.pem \
  -n source

kubectl create secret tls ca-pair-sslcerts \
  --cert=$TUTORIAL_HOME/ca.pem \
  --key=$TUTORIAL_HOME/ca-key.pem \
  -n destination
```

## Create credentials secrets  

In this step you will be creating secrets to be used to authenticate the clusters.  

```
# Specify the credentials required by the source and destination cluster. To understand how these
# credentials are configured, see 
# https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/security/secure-authn-encrypt-deploy

kubectl create secret generic credential -n source \
--from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
--from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
--from-file=basic.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt

kubectl create secret generic credential -n destination \
--from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
--from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt
```

## Deploy source and destination clusters, including Connect Worker

Deploy the source and destination cluster.  
```
# Deploy Zookeeper and Kafka to `source` namespace, to represent the source cluster
kubectl apply -f $TUTORIAL_HOME/components-source.yaml

# Deploy Zookeeper, Kafka, Connect, Control Center to `destination` namespace, 
# to represent the destination cluster
kubectl apply -f $TUTORIAL_HOME/components-destination.yaml
kubectl apply -f $TUTORIAL_HOME/controlcenter.yaml
```

In `$TUTORIAL_HOME/components-destination.yaml`, note that the `Connect` CRD is used to define a custom resource for the Connect Worker and pull Confluent Replicator connector from [Confluent Hub](https://www.confluent.io/hub/confluentinc/kafka-connect-replicator).  

## Create topic in source cluster

Wait for the Kafka component to be ready on the source cluster:  

```
 kubectl -n source get pods 
```
Apply the the `kafkaTopic` CRD to define a topic:  
```
kubectl apply -f $TUTORIAL_HOME/source-topic.yaml
kubectl -n source get topics
```

## Configure Replicator in destination cluster


Confluent Replicator is configured via CRD.  
```
 kubectl apply -f $TUTORIAL_HOME/connector.yaml   
 kubectl -n destination get connectors      
```

## Validate that it works

### Produce data to topic in source cluster

Create the kafka.properties file in $TUTORIAL_HOME. Add the above endpoint and the credentials as follows:

```
bootstrap.servers=kafka.source.svc.cluster.local:9071
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=kafka password=kafka-secret;
sasl.mechanism=PLAIN
security.protocol=SASL_SSL
ssl.truststore.location=/mnt/sslcerts/truststore.jks
ssl.truststore.password=mystorepassword
```

Create a configuration secret for client applications to use:  

```
kubectl create secret generic kafka-client-config-secure \
  --from-file=$TUTORIAL_HOME/kafka.properties \
  -n source
```

Deploy a producer application that produces messages to the topic `topic-in-source`:  
```
kubectl apply -f $TUTORIAL_HOME/secure-producer-app-data.yaml
```

### View in Control Center


Create a `port-forward`:  
```
kubectl --namespace destination port-forward controlcenter-0 9021:9021 
```

Open Confluent Control Center:  
https://localhost:9021/  

Verify that topic `topic-in-source_replica` was created and traffic is flowing.  

## Tear down

```
kubectl delete -f $TUTORIAL_HOME/secure-producer-app-data.yaml
kubectl delete -f $TUTORIAL_HOME/connector.yaml   
kubectl delete -f $TUTORIAL_HOME/source-topic.yaml
kubectl delete -f $TUTORIAL_HOME/controlcenter.yaml
kubectl delete -f $TUTORIAL_HOME/components-destination.yaml
kubectl delete -f $TUTORIAL_HOME/components-source.yaml

kubectl delete -n destination secret credential ca-pair-sslcerts
kubectl delete -n source secret credential kafka-client-config-secure ca-pair-sslcerts

kubectl delete ns source
kubectl delete ns destination
helm delete confluent-operator
```