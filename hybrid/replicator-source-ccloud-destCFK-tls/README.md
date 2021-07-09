# Replicator

## Set up Pre-requisites

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/replicator-source-ccloud-destCFK-tls
```

Create namespace,  for the destination cluster.

```
kubectl create ns destination
```


```
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes \
  --namespace destination
```


## Prep the Confluent Cloud user password and endpoint

Search and replace the following: 

```
<ccloud-key>
  hybrid/replicator-source-ccloud-destCFK-tls/creds-client-kafka-sasl-user.txt:
  hybrid/replicator-source-ccloud-destCFK-tls/README.md

<ccloud-pass>
  hybrid/replicator-source-ccloud-destCFK-tls/creds-client-kafka-sasl-user.txt
  hybrid/replicator-source-ccloud-destCFK-tls/README.md

<ccloud-endpoint:9092>
  hybrid/replicator-source-ccloud-destCFK-tls/README.md
  hybrid/replicator-source-ccloud-destCFK-tls/components-destination.yaml
```

## Deploy source and destination clusters, including Replicator


Deploy destination cluster.

```
::

kubectl create secret generic kafka-tls \
  --from-file=fullchain.pem=$TUTORIAL_HOME/certs/server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/certs/ca.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/certs/server-key.pem \
  --namespace destination

::


:: 

  kubectl create secret generic cloud-plain \
  --from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
  --namespace destination

::
kubectl apply -f $TUTORIAL_HOME/components-destination.yaml
```

In `$TUTORIAL_HOME/components-destination.yaml`, note that the `Connect` CRD is used to define a 
custom resource for Confluent Replicator.

```
```

## Create topic in source cluster


### Produce data to topic in source cluster

Create the kafka.properties file in $TUTORIAL_HOME. Add the above endpoint and the credentials as follows:

```
bootstrap.servers=kafka.source.svc.cluster.local:9071
sasl.jaas.config= org.apache.kafka.common.security.plain.PlainLoginModule required username="<ccloud-key>" password="<ccloud-pass>";
sasl.mechanism=PLAIN
security.protocol=SASL_SSL
ssl.truststore.location=/mnt/sslcerts/kafka-tls/truststore.p12
ssl.truststore.password=mystorepassword
```

# Create a configuration secret for client applications to use
kubectl create secret generic kafka-client-config-secure \
  --from-file=$TUTORIAL_HOME/kafka.properties -n destination
```

Deploy a producer application that produces messages to the topic `topic-in-source`:

```
kubectl apply -f $TUTORIAL_HOME/secure-producer-app-data.yaml
```



```
 kafka-topics --bootstrap-server <ccloud-endpoint:9092> \
--command-config  ~/kafkaexample/ccloud-team/client.properties \
--create \
--partitions 3 \
--replication-factor 3 \
--topic moshe-topic-in-source
```


Create messages  


```
seq 1000  | kafka-console-producer --broker-list  <ccloud-endpoint:9092> \
--producer.config  ~/kafkaexample/ccloud-team/client.properties \
--topic moshe-topic-in-source
```




## Configure Replicator in destination cluster

Confluent Replicator requires the configuration to be provided as a file in the running Docker container.
You'll then interact with it through the REST API, to set the configuration.

```
# SSH into the `replicator-0` pod
kubectl -n destination exec -it replicator-0 -- bash

# Define the configuration as a file in the pod
cat <<EOF > replicator.json
 {
 "name": "replicator",
 "config": {
     "connector.class":  "io.confluent.connect.replicator.ReplicatorSourceConnector",
     "src.kafka.sasl.jaas.config": "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"<ccloud-key>\" password=\"<ccloud-pass>\";",
     "confluent.license": "",
     "confluent.topic.replication.factor": "3",
     "confluent.topic.security.protocol": "SSL",
     "confluent.topic.ssl.truststore.location":"/mnt/sslcerts/kafka-tls/truststore.p12",
     "confluent.topic.ssl.truststore.password":"mystorepassword",
     "confluent.topic.ssl.truststore.type": "PKCS12",
     "dest.kafka.bootstrap.servers": "kafka.destination.svc.cluster.local:9071",
     "dest.kafka.security.protocol": "SSL",
     "dest.kafka.ssl.keystore.type": "PKCS12",
     "dest.kafka.ssl.truststore.location": "/mnt/sslcerts/kafka-tls/truststore.p12",
     "dest.kafka.ssl.truststore.password": "mystorepassword",
     "dest.kafka.ssl.truststore.type": "PKCS12",
     "key.converter": "io.confluent.connect.replicator.util.ByteArrayConverter",
     "src.kafka.bootstrap.servers": "<ccloud-endpoint:9092>",
     "src.kafka.sasl.mechanism": "PLAIN",
     "src.kafka.security.protocol": "SASL_SSL",
     "src.kafka.ssl.keystore.type": "PKCS12",
     "src.kafka.ssl.truststore.location": "/mnt/sslcerts/kafka-tls/truststore.p12",
     "src.kafka.ssl.truststore.password": "mystorepassword",
     "src.kafka.ssl.truststore.type": "PKCS12",
     "tasks.max": "4",
     "topic.whitelist": "moshe-topic-in-source",
      "topic.rename.format": "\${topic}_replica",
     "value.converter": "io.confluent.connect.replicator.util.ByteArrayConverter"
   }
 }
EOF

# Instantiate the Replicator Connector instance through the REST interface
curl -XPOST -H "Content-Type: application/json" --data @replicator.json https://localhost:8083/connectors -k

# Check the status of the Replicator Connector instance
curl -XGET -H "Content-Type: application/json" https://localhost:8083/connectors -k

curl -XGET -H "Content-Type: application/json" https://localhost:8083/connectors/replicator/status -k

```

To delete: 

```
curl -XDELETE -H "Content-Type: application/json" https://localhost:8083/connectors/replicator -k
```

## Validate that it works

### View in Control Center
```
  kubectl port-forward controlcenter-0 9021:9021
```
Open Confluent Control Center.

```
kubectl confluent dashboard controlcenter -n destination
```

```
seq 1000  | kafka-console-producer --broker-list  <ccloud-endpoint:9092> \
--producer.config  ~/kafkaexample/ccloud-team/client.properties \
--topic moshe-topic-in-source
```


tear down 


kubectl --namespace destination delete -f $TUTORIAL_HOME/components-destination.yaml           
kubectl --namespace destination delete secrets cloud-plain kafka-tls 

