# Replicator

In this tutorial you will set a CFK destination cluster with replicator encrypted by TLS using Confluent Cloud as a source topic. 

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

Deploy CFK: 

```
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes \
  --namespace destination
```

## Prep the Confluent Cloud user password and endpoint

Search and replace the following: 

```
<ccloud-key> - with your Confluent Cloud Key


<ccloud-pass> - with your Confluent Cloud pass


<ccloud-endpoint:9092> - with your Confluent Cloud Cluster endpoint
```

You can use a commands like these, or just use the editor. 
```
sed -i '' -e 's/<ccloud-key>/mylongkeyhere/g' $(find $TUTORIAL_HOME -type f -not -path "$TUTORIAL_HOME/certs/*")
sed -i '' -e 's/<ccloud-pass>/mylongpasshere/g' $(find $TUTORIAL_HOME -type f -not -path "$TUTORIAL_HOME/certs/*")
sed -i '' -e 's/<ccloud-endpoint:9092>/somedomainhere.aws.confluent.cloud:9092/g' $(find $TUTORIAL_HOME -type f -not -path "$TUTORIAL_HOME/certs/*")
```

## Deploy destination cluster, including Replicator

Create TLS secrets (included in the ca and server pem are the 2 letsencrypt ccloud certs):  

```
kubectl create secret generic kafka-tls \
--from-file=fullchain.pem=$TUTORIAL_HOME/certs/server.pem \
--from-file=cacerts.pem=$TUTORIAL_HOME/certs/ca.pem \
--from-file=privkey.pem=$TUTORIAL_HOME/certs/server-key.pem \
--namespace destination
```

Create secret with ccloud user/pass for Control Center:  

```
kubectl create secret generic cloud-plain \
--from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
--namespace destination
```

Deploy destination cluster:  

```
kubectl apply -f $TUTORIAL_HOME/components-destination.yaml --namespace destination
```

In `$TUTORIAL_HOME/components-destination.yaml`, note that the `Connect` CRD is used to define a 
custom resource for Confluent Replicator.

## Produce data to topic in source cluster

Create the kafka.properties file in $TUTORIAL_HOME. Add the above endpoint and the credentials as follows:

```
bootstrap.servers=<ccloud-endpoint:9092>
security.protocol=SASL_SSL
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="<ccloud-key>" password="<ccloud-pass>";
ssl.endpoint.identification.algorithm=https
sasl.mechanism=PLAIN
```

There is no need for TLS here as it's part of the image. 


### Create a configuration secret for client applications to use

```
kubectl create secret generic kafka-client-config-secure \
  --from-file=$TUTORIAL_HOME/kafka.properties --namespace destination
```

### Create a topic named `topic-in-source`  
```
kubectl --namespace destination apply -f $TUTORIAL_HOME/cloudtopic.yaml
```


### Deploy a producer application that produces messages to the topic `topic-in-source`:

```
kubectl --namespace destination apply -f $TUTORIAL_HOME/cloudproducer.yaml
```

## Configure Replicator in destination cluster

There are two ways to deploy replicator connector:

1) Declaratively creating replicator connector
2) Using REST API endpoint to deploy the replicator connector

### 1) Declaratively creating replicator connector

Starting in Confluent for Kubernetes (CFK) 2.1.0, you can [declaratively](https://docs.confluent.io/operator/2.5.0/co-manage-connectors.html#co-manage-connectors) manage connectors in Kubernetes using the Connector custom resource definition (CRD).

#### Create replicator connector
```
kubectl apply -f $TUTORIAL_HOME/connector.yaml
```
#### Check connector
```
kubectl get connector -n destination
```

### 2) Using REST API endpoint to deploy the replicator connector
Confluent Replicator requires the configuration to be provided as a file in the running Docker container. You'll then interact with it through the REST API, to set the configuration.

### SSH into the `replicator-0` pod

```
kubectl --namespace destination exec -it replicator-0 -- bash
```

#### Define the configuration as a file in the pod

```
cat <<EOF > replicator.json
 {
 "name": "replicator",
 "config": {
     "connector.class":  "io.confluent.connect.replicator.ReplicatorSourceConnector",
     "confluent.license": "",
     "confluent.topic.replication.factor": "3",
     "confluent.topic.security.protocol": "SSL",
     "confluent.topic.ssl.truststore.location":"/mnt/sslcerts/kafka-tls/truststore.p12",
     "confluent.topic.ssl.truststore.password":"mystorepassword",
     "confluent.topic.bootstrap.servers": "kafka.destination.svc.cluster.local:9071",
     "dest.kafka.bootstrap.servers": "kafka.destination.svc.cluster.local:9071",
     "dest.kafka.security.protocol": "SSL",
     "dest.kafka.ssl.truststore.location": "/mnt/sslcerts/kafka-tls/truststore.p12",
     "dest.kafka.ssl.truststore.password": "mystorepassword",
     "key.converter": "io.confluent.connect.replicator.util.ByteArrayConverter",
     "src.consumer.confluent.monitoring.interceptor.bootstrap.servers": "<ccloud-endpoint:9092>",
     "src.consumer.confluent.monitoring.interceptor.sasl.jaas.config": "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"<ccloud-key>\" password=\"<ccloud-pass>\";",
     "src.consumer.confluent.monitoring.interceptor.sasl.mechanism": "PLAIN",
     "src.consumer.confluent.monitoring.interceptor.security.protocol": "SASL_SSL",
     "src.consumer.confluent.monitoring.interceptor.ssl.truststore.location": "/mnt/sslcerts/kafka-tls/truststore.p12",
     "src.consumer.confluent.monitoring.interceptor.ssl.truststore.password": "mystorepassword",
     "src.consumer.group.id": "replicator",
     "src.consumer.interceptor.classes": "io.confluent.monitoring.clients.interceptor.MonitoringConsumerInterceptor",
     "src.kafka.bootstrap.servers": "<ccloud-endpoint:9092>",
     "src.kafka.sasl.jaas.config": "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"<ccloud-key>\" password=\"<ccloud-pass>\";",
     "src.kafka.sasl.mechanism": "PLAIN",
     "src.kafka.security.protocol": "SASL_SSL",
     "src.kafka.ssl.truststore.location": "/mnt/sslcerts/kafka-tls/truststore.p12",
     "src.kafka.ssl.truststore.password": "mystorepassword",
     "tasks.max": "4",
     "topic.rename.format": "\${topic}_replica",
     "topic.whitelist": "topic-in-source",
     "value.converter": "io.confluent.connect.replicator.util.ByteArrayConverter"
   }
 }
EOF
``` 

#### Instantiate the Replicator Connector instance through the REST interface

```
curl -XPOST -H "Content-Type: application/json" --data @replicator.json https://localhost:8083/connectors -k
```
#### Check the status of the Replicator Connector instance
```
curl -XGET -H "Content-Type: application/json" https://localhost:8083/connectors -k

curl -XGET -H "Content-Type: application/json" https://localhost:8083/connectors/replicator/status -k
```

#### To delete the connector: 

```
curl -XDELETE -H "Content-Type: application/json" https://localhost:8083/connectors/replicator -k
```

### View in Control Center  

```
  kubectl port-forward controlcenter-0 9021:9021 --namespace destination
```
Open Confluent Control Center.


### Validate that it works

Open Control center, select destination cluster, topic `${topic}_replica` where $topic is the name of the approved topic (whitelist). 
You should start seeing messages flowing into the destination topic. 

##  Tear down 

```
kubectl --namespace destination delete -f $TUTORIAL_HOME/components-destination.yaml           
kubectl --namespace destination delete secrets cloud-plain kafka-tls kafka-client-config-secure
kubectl --namespace destination delete -f $TUTORIAL_HOME/cloudtopic.yaml
kubectl --namespace destination delete -f $TUTORIAL_HOME/cloudproducer.yaml
helm --namespace destination delete confluent-operator
```
Stop port-forward which was started earlier.


#### Appendix: Create your own certificates

When testing, it's often helpful to generate your own certificates to validate the architecture and deployment.

You'll want both these to be represented in the certificate SAN:
```
- external domain names
- internal Kubernetes domain names
```
The internal Kubernetes domain name depends on the namespace you deploy to. If you deploy to `confluent` namespace, 
then the internal domain names will be: 

```
- *.kafka.destination.svc.cluster.local
- *.zookeeper.destination.svc.cluster.local
- *.replicator.destination.svc.cluster.local
- *.destination.svc.cluster.local
```

##### Install libraries on Mac OS
```
  brew install cfssl
```
##### Create Certificate Authority
  
```
  mkdir $TUTORIAL_HOME/../../assets/certs/generated && cfssl gencert -initca $TUTORIAL_HOME/../../assets/certs/ca-csr.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/ca -
```

##### Validate Certificate Authority

```
  openssl x509 -in $TUTORIAL_HOME/../../assets/certs/generated/ca.pem -text -noout
```
##### Create server certificates with the appropriate SANs (SANs listed in server-domain.json)

```
  cfssl gencert -ca=$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
  -ca-key=$TUTORIAL_HOME/../../assets/certs/generated/ca-key.pem \
  -config=$TUTORIAL_HOME/../../assets/certs/ca-config.json \
  -profile=server $TUTORIAL_HOME/../../assets/certs/server-domain.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/server
```

##### Validate server certificate and SANs

```  
  openssl x509 -in $TUTORIAL_HOME/../../assets/certs/generated/server.pem -text -noout
```

At this point you need to include the letsencrypt root certificates in the CA and server pem files.

The block to copy paste is located in the hybrid/replicator-source-ccloud-destCFK-tls/certs/cloudchain.pem file. 
All you need is to combine the files: 


```
cat $TUTORIAL_HOME/../../assets/certs/generated/ca.pem $TUTORIAL_HOME/certs/cloudchain.pem > ca.pem
cat $TUTORIAL_HOME/../../assets/certs/generated/server.pem $TUTORIAL_HOME/certs/cloudchain.pem > server.pem
```

Use the above files when creating the secret. 













