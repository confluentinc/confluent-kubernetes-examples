# HTTP sink Connector

In this example, you'll setup the followings:  
* nodejs as an API server 
* Confluent Platform with Connect and http sink connector.  

You will install and manage the https sink connector and plugin jars through the declarative `Connector` CRD.  
In this scenario, we deploy the a Confluent cluster without security.  

This setup uses a custom built nodejs API server which take `POST/GET` calls.  
When the connector sends a message from a topic to the server the server log the request to a file and able to serve get requests from this file (command included later on).


## Set up Pre-requisites

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/connector/http-sink-connector
```

Create a namespace:  
```
kubectl create ns confluent
```

Deploy Confluent for Kubernetes (CFK): 

```
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes \
  --namespace confluent
```

## Deploy nodejs API server   

```
kubectl --namespace confluent apply -f $TUTORIAL_HOME/nodejs.yaml
```

Check that all components were created: 

```
kubectl --namespace confluent get pods -l app=my-backend-api

NAME                             READY   STATUS    RESTARTS   AGE
my-backend-api-589cb6bdf-jn96w   1/1     Running   0          48s
```

## Deploy Confluent Cluster Components

```
kubectl --namespace confluent apply -f $TUTORIAL_HOME/confluent-platform.yaml
```
Check that zookeeper, kafka and connect cluster are deployed:

```   
kubectl --namespace confluent get confluent
```

Notice that the connect pod might take a bit longer to create since it's downloading the connector jars from Confluent Hub.  

## Create secret, topic, and producer

Once the Kafka cluster is ready create the secret, topic, and producer, all within one YAML file:    
```
kubectl --namespace confluent apply -f $TUTORIAL_HOME/producer-app-data.yaml
```  

Check topic 
```
kubectl --namespace confluent get topic
```

## Create Connector

Create connector 
```
kubectl --namespace confluent apply -f $TUTORIAL_HOME/httpsinkconnector.yaml
```
Check connector 
```
kubectl --namespace confluent get connector
```

Wait for the `CONNECTORSTATUS` to show `RUNNING` status. 

## Validate the connector

Messages are sent to topic `http-messages` using console producer and the connector consumes from the topic and sends it to the API endpoint.

Bash into the  `connect` pod:  
```
kubectl --namespace confluent exec connect-0  -it -- bash                              
```

Consume the messages: 

```
kafka-console-consumer --from-beginning --bootstrap-server kafka:9071 --topic http-messages
```

Check the API endpoint to see that the messages are accepted, you should see the same messages from the above:

```
curl  http://my-backend-api/messagesfromtopic  
``` 

For example:  
```
{"f1":"value19062"}
{"f1":"value19063"}
{"f1":"value19064"}
{"f1":"value19065"}
```

Exit the pod.

## Validation

You can review the node js pod log to see progress as well:  
```
export POD_NAME=$(kubectl --namespace confluent get pods -l app=my-backend-api -o jsonpath="{.items[0].metadata.name}")
kubectl --namespace confluent logs $POD_NAME
```  

## Tear down

```
kubectl --namespace confluent delete -f $TUTORIAL_HOME/httpsinkconnector.yaml
kubectl --namespace confluent delete -f $TUTORIAL_HOME/producer-app-data.yaml
kubectl --namespace confluent delete -f $TUTORIAL_HOME/confluent-platform.yaml
kubectl --namespace confluent delete -f $TUTORIAL_HOME/nodejs.yaml
helm --namespace confluent delete confluent-operator
```

## Notes 

If you would like to produce some messages to the endpoint directly: 

```
export POD_NAME=$(kubectl --namespace confluent get pods -l app=my-backend-api -o jsonpath="{.items[0].metadata.name}")
kubectl --namespace confluent exec $POD_NAME -it -- bash          
curl -X POST -H "Content-Type: application/json" -d '{"name" :"Don Draper"}' http://localhost/messages 
```

Check the messages: 
```
curl  http://localhost/messagesfromtopic         
```

To produce new messages to the topic:  
```
export POD_NAME=$(kubectl --namespace confluent get pods -l app=connect -o jsonpath="{.items[0].metadata.name}")
kubectl --namespace confluent exec $POD_NAME -it -- bash          
for i in `seq 5000 5300`; do echo '{"f1": "value'$i'"'};done  | kafka-console-producer \
            --bootstrap-server kafka:9071 \
            --topic http-messages
```

