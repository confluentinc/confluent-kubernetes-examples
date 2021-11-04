# DataGen Source Connector
In this example, you'll setup a Confluent Platform with Connect, and install and manage the DataGen source connector plugin through the declarative `Connector` CRD.
Note: Here you'll only deploy Zookeeper, Kafka and Connect

## Set up Pre-requisites

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/connector/datagen-source-connector
```

Create namespace

```
kubectl create ns confluent
```

## Deploy Confluent for Kubernetes

This workflow scenario assumes you are using the namespace `confluent`.

Set up the Helm Chart:

```
helm repo add confluentinc https://packages.confluent.io/helm
```

Install Confluent For Kubernetes using Helm:

```
helm upgrade --install operator confluentinc/confluent-for-kubernetes -n confluent
```
  
Check that the Confluent For Kubernetes pod comes up and is running:

```
kubectl get pods -n confluent
```

## Deploy Confluent Platform

Deploy Confluent Platform:

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform.yaml
```

Check that all Confluent Platform resources are deployed:

```   
kubectl get confluent -n confluent
```

Check that zookeeper, kafka and connect resources are deployed:

```   
kubectl get confluent -n confluent
```

## Create Topic
Create topic `pageviews`
```
kubectl apply -f $TUTORIAL_HOME/topic.yaml
```
Check topic 
```
kubectl get topic -n confluent
```

## Create Connector
Create connector 
```
kubectl apply -f $TUTORIAL_HOME/connector.yaml
```
Check connector 
```
kubectl get connector -n confluent
```

## Validation
Exec into one of the kafka pod
```
kubectl exec kafka-0 -it bash -n confluent
```
Run below command:
```
kafka-console-consumer --from-beginning --topic pageviews --bootstrap-server  kafka.confluent.svc.cluster.local:9071
```

## Tear down

```
kubectl delete -f $TUTORIAL_HOME/connector.yaml
kubectl delete -f $TUTORIAL_HOME/topic.yaml
kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml
```