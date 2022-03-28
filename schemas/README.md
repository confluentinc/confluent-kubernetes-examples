# Schemas
Confluent for Kubernetes (CFK) provides the Schema custom resource definition (CRD). With the Schema CRD, you can declaratively create, read, and delete schemas as Schema custom resources (CRs) in Kubernetes.

In this example, you'll set up a Confluent Platform with Schema registry, and create and register a schema for a new subject name by creating a new Schema CR. To create a Schema CR, you'll first create a configmap resource containing the schema, and later, create the schema CR. 

To complete this scenario, you'll follow these steps:

1. Set the current tutorial directory
2. Deploy Confluent for Kubernetes
3. Deploy Confluent Platform
4. Create Schema CR 
5. Validation
6. Tear down Confluent Platform

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/schemas
```

## Deploy Confluent for Kubernetes

This workflow scenario assumes you are using the namespace `confluent`, otherwise you can create it by running ``kubectl create namespace confluent``. 

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

Check that zookeeper, kafka and schema registry pods come up and are running:

```   
kubectl get pods -n confluent
```

## Create Schema CR 
Deploy the ConfigMap resource containing the schema: 
```
kubectl apply -f $TUTORIAL_HOME/schema-config.yaml
```

Deploy the Schema CR: 
```
kubectl apply -f $TUTORIAL_HOME/schema.yaml 
```

Check that schema config and schema CR are deployed: 
```
kubectl get configmap -n confluent 
kubectl get schema -n confluent
```

## Validation

Exec into one of the schema registry pod:
```
kubectl exec schemaregistry-0 -it bash -n confluent
```

Get the registered subjects:
```
curl http://schemaregistry.confluent.svc.cluster.local:8081/subjects
```

Get a list of versions registered under the subject `payment-value`: 
```
curl http://schemaregistry.confluent.svc.cluster.local:8081/subjects/payment-value/versions
```

Get the schema for the specified version of the subject `payment-value`: 
```
curl http://schemaregistry.confluent.svc.cluster.local:8081/subjects/payment-value/versions/1/schema
```

## Tear down Confluent Platform

```
kubectl delete -f $TUTORIAL_HOME/schema.yaml
kubectl delete -f $TUTORIAL_HOME/schema-config.yaml
kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml
helm delete operator -n confluent
```
