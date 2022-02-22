# Replicator

In this workflow scenario you will be able to replicate data from one source Confluent Cloud cluster to a destination Confluent Cloud cluster, using Confluent Replicator.  
You'll be able to monitor the end to end architecture through a single view in Confluent Control Center -> the source cluster, destination cluster, and the replication service.  
The Confluent Replicator Monitoring Extension allows for detailed metrics from Replicator tasks to be collected using an exposed REST API. 

You will set the following components:
 - Connect worker with Confluent Replicator and Monitoring Extension using Confluent Cloud as a source and destination.  
 - Control Center bootstrapping the destination Confluent Cloud cluster and monitoring the source Confluent Cloud cluster, you will be able to view both via the UI.  

## Set up Pre-requisites

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/replicator-cloud2cloud
```

Create namespace,  for the destination cluster.

```
kubectl create ns destination
```

## Deploy Confluent for Kubernetes  

###  Set up the Helm Chart:  

```
helm repo add confluentinc https://packages.confluent.io/helm
```

### Install Confluent For Kubernetes using Helm: 

```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --namespace destination
```

### Check that the Confluent For Kubernetes pod comes up and is running: 
```
kubectl --namespace destination get pods
```

## Prep the Confluent Cloud user, password and endpoint

Search and replace the following: 

```
<destination-ccloud-key> - with your destination Confluent Cloud Key
<destination-ccloud-pass> - with your destination Confluent Cloud pass
<destination-ccloud-endpoint:9092> - with your destination Confluent Cloud Cluster endpoint

<source-ccloud-key> - with your source Confluent Cloud Key
<source-ccloud-pass> - with your source Confluent Cloud pass
<source-ccloud-endpoint:9092> - with your source Confluent Cloud Cluster endpoint

<destination-api-key-SR>  - with your destination Confluent Cloud Schema Registry Key
<destination-api-secret-SR> - with your destination Confluent Cloud Schema Registry  pass
<destination-cloudSR_url>  - with your destination Confluent Cloud  Schema Registry endpoint
```

You can use a commands like these, or just use the editor. 
```
sed -i '' -e 's/destination-ccloud-key/mylongkeyhere/g' $(find $TUTORIAL_HOME -type f)
sed -i '' -e 's/<destination-ccloud-pass>/mylongpasshere/g' $(find $TUTORIAL_HOME -type f)
sed -i '' -e 's/<destination-ccloud-endpoint:9092>/somedomainhere.aws.confluent.cloud:9092/g' $(find $TUTORIAL_HOME -type f)
```

## Create Secrets 

Create a Kubernetes secret object for the **destination** Confluent Cloud Kafka access.  
This secret object contains file based properties.  
These files are in the format that each respective Confluent component requires for authentication credentials.

```
  kubectl create secret generic destination-cloud-plain \
  --from-file=plain.txt=$TUTORIAL_HOME/destination-creds-client-kafka-sasl-user.txt \
  --namespace destination
```

```
  kubectl create secret generic destination-cloud-sr-access \
  --from-file=basic.txt=$TUTORIAL_HOME/destination-creds-schemaRegistry-user.txt \
  --namespace destination
```

```
  kubectl create secret generic control-center-user \
  --from-file=basic.txt=$TUTORIAL_HOME/creds-control-center-users.txt \
  --namespace destination
```

Create a Kubernetes secret object for the **source** Confluent Cloud Kafka access.

```
  kubectl create secret generic source-cloud-plain \
  --from-file=plain.txt=$TUTORIAL_HOME/source-creds-client-kafka-sasl-user.txt \
  --namespace destination
```


## Deploy destination components: Control Center and Replicator

Deploy destination cluster:  

```
kubectl apply -f $TUTORIAL_HOME/components-destination.yaml \
--namespace destination
```

```
kubectl apply -f $TUTORIAL_HOME/controlcenter.yaml \
--namespace destination
```

```
kubectl get pods --namespace destination
```  


## Produce data to topic in source cluster

Create the `source-kafka.properties` file in `$TUTORIAL_HOME`.  
Add the above endpoint and the credentials as follows:

```
bootstrap.servers=<source-ccloud-endpoint:9092> 
security.protocol=SASL_SSL
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="<source-ccloud-key>" password="<source-ccloud-pass>";
ssl.endpoint.identification.algorithm=https
sasl.mechanism=PLAIN
```

There is no need for TLS here as it's part of the image. 


### Create a configuration secret for client applications to use

```
kubectl create secret generic source-kafka-client-config-secure \
  --from-file=$TUTORIAL_HOME/source-kafka.properties \
  --namespace destination
```

### Create a topic named `source-topic`  
```
kubectl --namespace destination apply -f $TUTORIAL_HOME/cloudtopic.yaml
```

Verify that the pods has completed:  
```
kubectl get pods --namespace destination
```  



### Deploy a producer application that produces messages to the topic `source-topic`:

```
kubectl --namespace destination apply -f $TUTORIAL_HOME/cloudproducer.yaml
```


## Configure Replicator in destination cluster

Confluent Replicator requires the configuration to be provided as a file in the running Docker container.  
You'll then interact with it through the REST API, to set the configuration.  

### SSH into the `replicator-0` pod

```
kubectl --namespace destination exec -it replicator-0 -- bash
```

#### Define the configuration as a file in the pod

```
cat <<EOF > /tmp/replicator.json
 {
 "name": "replicator",
 "config": {
     "connector.class":  "io.confluent.connect.replicator.ReplicatorSourceConnector",
     "confluent.license": "",
     "confluent.topic.replication.factor": "3",
     "confluent.topic.bootstrap.servers": "<destination-ccloud-endpoint:9092>",
     "confluent.topic.sasl.jaas.config": "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"<destination-ccloud-key>\" password=\"<destination-ccloud-pass>\";",
     "confluent.topic.sasl.mechanism": "PLAIN",
     "confluent.topic.security.protocol": "SASL_SSL",
     "dest.kafka.bootstrap.servers": "<destination-ccloud-endpoint:9092>",
     "dest.kafka.sasl.jaas.config": "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"<destination-ccloud-key>\" password=\"<destination-ccloud-pass>\";",
     "dest.kafka.sasl.mechanism": "PLAIN",
     "dest.kafka.security.protocol": "SASL_SSL",
     "key.converter": "io.confluent.connect.replicator.util.ByteArrayConverter",
     "src.consumer.confluent.monitoring.interceptor.bootstrap.servers": "<source-ccloud-endpoint:9092> ",
     "src.consumer.confluent.monitoring.interceptor.sasl.jaas.config": "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"<source-ccloud-key>\" password=\"<source-ccloud-pass>\";",
     "src.consumer.confluent.monitoring.interceptor.sasl.mechanism": "PLAIN",
     "src.consumer.confluent.monitoring.interceptor.security.protocol": "SASL_SSL",
     "src.consumer.group.id": "replicator",
     "src.consumer.interceptor.classes": "io.confluent.monitoring.clients.interceptor.MonitoringConsumerInterceptor",
     "src.kafka.bootstrap.servers": "<source-ccloud-endpoint:9092> ",
     "src.kafka.sasl.jaas.config": "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"<source-ccloud-key>\" password=\"<source-ccloud-pass>\";",
     "src.kafka.sasl.mechanism": "PLAIN",
     "src.kafka.security.protocol": "SASL_SSL",
     "tasks.max": "4",
     "topic.rename.format": "\${topic}_replica",
     "topic.whitelist": "source-topic",
     "value.converter": "io.confluent.connect.replicator.util.ByteArrayConverter"
   }
 }
EOF
``` 

#### Instantiate the Replicator Connector instance through the REST interface

```
curl -XPOST -H "Content-Type: application/json" --data @/tmp/replicator.json http://localhost:8083/connectors
```
#### Check the status of the Replicator Connector instance
```
curl -XGET -H "Content-Type: application/json" http://localhost:8083/connectors 

curl -XGET -H "Content-Type: application/json" http://localhost:8083/connectors/replicator/status 
```

##### To delete the connector: 

```
curl -XDELETE -H "Content-Type: application/json" http://localhost:8083/connectors/replicator 
```

### View in Control Center  

```
kubectl port-forward controlcenter-0 9021:9021 --namespace destination
```  

Open Confluent Control Center: http://0.0.0.0:9021/  
Log in with user `admin` and password `Developer1`.    


### Validate that it works

Open Control center, select destination cluster, topic `${topic}_replica` where $topic is the name of the approved topic (whitelist).   
You should start seeing messages flowing into the destination topic. 
You can check the replicator tab as well as the connect tab.  

##  Tear down 

```
kubectl --namespace destination delete -f $TUTORIAL_HOME/components-destination.yaml  
kubectl --namespace destination delete -f $TUTORIAL_HOME/controlcenter.yaml         
kubectl --namespace destination delete -f $TUTORIAL_HOME/cloudtopic.yaml
kubectl --namespace destination delete -f $TUTORIAL_HOME/cloudproducer.yaml
kubectl --namespace destination delete secrets destination-cloud-plain destination-cloud-sr-access control-center-user source-kafka-client-config-secure source-cloud-plain
helm --namespace destination delete confluent-operator
```

Stop port-forward which was started earlier.










