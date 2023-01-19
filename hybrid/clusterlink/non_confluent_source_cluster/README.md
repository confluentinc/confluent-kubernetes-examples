## ClusterLink Setup

### Kafka Cluster with Mutual TLS Authentication
In this example, source is running opensource kafka without any security and destination Confluent Server run in mutual TLS mode.

## Set up Pre-requisites
Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```
export TUTORIAL_HOME=$PWD/hybrid/clusterlink/non_confluent_source_cluster
```

```
kubectl create ns destination
```

Deploy Confluent for Kubernetes (CFK) in cluster mode, so that the one CFK instance can manage Confluent deployments in multiple namespaces. Here, CFk is deployed to the `default` namespace.

```
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes \
  --namespace default --set namespaced=false
```

### Source Cluster Deployment  
```
kubectl -n destination apply -f $TUTORIAL_HOME/zk-kafka-source.yaml
```

#### Create a topic on the source cluster and produce some data

```
kubectl -n destination exec -it notcflt  -- bash
/opt/kafka_2.13-3.3.1/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --partitions 3 --replication-factor 1  --topic demo
seq 1000 | /opt/kafka_2.13-3.3.1/bin/kafka-console-producer.sh --broker-list localhost:9092 --topic demo
```

You will need to keep the cluster ID from the source cluster:  
```
 grep cluster /tmp/kafka-logs/meta.properties | cut -d "=" -f 2
```  

Use the above value in the field `clusterID` line 13 in file `$TUTORIAL_HOME/clusterlink.yaml`.  

### Destination Cluster Deployment

### Create required secrets  

```
kubectl -n destination create secret generic credential \
    --from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
    --from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
    --from-file=basic.txt=$TUTORIAL_HOME/creds-basic-users.txt
```

Generate a CA pair to use in this tutorial:
```
openssl genrsa -out $TUTORIAL_HOME/ca-key.pem 2048
openssl req -new -key $TUTORIAL_HOME/ca-key.pem -x509 \
  -days 1000 \
  -out $TUTORIAL_HOME/ca.pem \
  -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA"
```
Then, provide the certificate authority as a Kubernetes secret ca-pair-sslcerts  
```
kubectl -n destination create secret tls ca-pair-sslcerts \
    --cert=$TUTORIAL_HOME/ca.pem \
    --key=$TUTORIAL_HOME/ca-key.pem   
```

```
kubectl -n destination create secret generic destination-tls-zk1 \
    --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/zookeeper-server.pem \
    --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
    --from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/zookeeper-server-key.pem

kubectl -n destination create secret generic destination-tls-group1 \
    --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/kafka-server.pem \
    --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
    --from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/kafka-server-key.pem
    
kubectl -n destination create secret generic rest-credential \
    --from-file=basic.txt=$TUTORIAL_HOME/rest-credential.txt
    
kubectl -n destination create secret generic password-encoder-secret \
    --from-file=password-encoder.txt=$TUTORIAL_HOME/password-encoder-secret.txt
 
```
#### Deploy destination zookeeper and kafka cluster in namespace `destination`

```
kubectl apply -f $TUTORIAL_HOME/zk-kafka-destination.yaml
```

After the Kafka cluster is in running state, create cluster link between source and destination. Cluster link will be created in the destination cluster.

```
kubectl -n destination get pods     
```

#### Create clusterlink between source and destination
```
kubectl apply -f $TUTORIAL_HOME/clusterlink.yaml
kubectl -n destination get cl     
```

### Run test

#### Open a new terminal and exec into destination kafka pod
```
kubectl -n destination exec kafka-0 -it -- bash
```

#### Create kafka.properties for destination kafka cluster

```
cat <<EOF > /tmp/kafka.properties
bootstrap.servers=kafka.destination.svc.cluster.local:9071
security.protocol=SSL
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
ssl.keystore.location=/mnt/sslcerts/keystore.p12
ssl.keystore.password=mystorepassword
EOF
```

#### Validate topic is created in destination kafka cluster

```
kafka-topics --describe --topic demo --bootstrap-server kafka.destination.svc.cluster.local:9071 --command-config /tmp/kafka.properties
```

#### Consume in destination kafka cluster and confirm message delivery in destination cluster

```
kafka-console-consumer --from-beginning --topic demo --bootstrap-server kafka.destination.svc.cluster.local:9071  --consumer.config /tmp/kafka.properties
```

### Commands to be used on the Confluent server if needed  
```
kubectl -n destination exec kafka-0 -it -- bash
cat <<EOF > /tmp/kafka.properties
bootstrap.servers=kafka.destination.svc.cluster.local:9071
security.protocol=SSL
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
ssl.keystore.location=/mnt/sslcerts/keystore.p12
ssl.keystore.password=mystorepassword
EOF
kafka-cluster-links --bootstrap-server kafka.destination.svc.cluster.local:9071 --command-config /tmp/kafka.properties --list
kafka-cluster-links --bootstrap-server kafka.destination.svc.cluster.local:9071 --command-config /tmp/kafka.properties --list --link clusterlink-cflt --include-topics
kafka-replica-status --bootstrap-server kafka.destination.svc.cluster.local:9071 --admin.config /tmp/kafka.properties --topics demo --include-mirror
kafka-mirrors --describe --topics demo  --bootstrap-server kafka.destination.svc.cluster.local:9071 --command-config /tmp/kafka.properties
```

Check it's a read only:  
```
kafka-console-producer --topic demo --bootstrap-server kafka.destination.svc.cluster.local:9071 --producer.config /tmp/kafka.properties
>test
>[2023-01-18 11:10:59,329] ERROR Error when sending message to topic demo with key: null, value: 3 bytes with error: (org.apache.kafka.clients.producer.internals.ErrorLoggingCallback)
org.apache.kafka.common.errors.InvalidRequestException: Cannot append records to read-only mirror topic 'demo'
```
### Filter using

Create a set of topics (filterdemo 1-5):  
```
kubectl -n destination exec -it notcflt  -- bash
for i in {1..5}; do /opt/kafka_2.13-3.3.1/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --partitions 3 --replication-factor 1  --topic filterdemo$i; done
for i in {1..5}; do seq 1000 | /opt/kafka_2.13-3.3.1/bin/kafka-console-producer.sh --broker-list localhost:9092 --topic filterdemo$i; done
```
Verify that there are messages in the source topic: 
```
/opt/kafka_2.13-3.3.1/bin/kafka-console-consumer.sh --from-beginning --topic filterdemo5 --bootstrap-server localhost:9092 
```  
First create a Cluster Link with autoCreateTopics disabled:

```
  mirrorTopicOptions:
    autoCreateTopics: 
      enabled: false
      topicFilters: 
        - filterType: INCLUDE
          name: filterdemo
          patternType: PREFIXED
    prefix: "dest-"
```

```
kubectl -n destination apply -f $TUTORIAL_HOME/clusterlinkfilter-disabled.yaml
kubectl -n destination get cl
```

Notice that nothing is being created.
Now change to `enabled: true`, wait 5 minutes ([default metadata duration](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/topic-data-sharing.html#change-the-source-topics-partitions)): 
```
kubectl -n destination apply -f $TUTORIAL_HOME/clusterlinkfilter-enabled.yaml
```
Check for the topics on the destination cluster: 
```
kafka-topics --bootstrap-server kafka.destination.svc.cluster.local:9071 --command-config /tmp/kafka.properties --list
```
Once the topics are there, consume from the destination topics:  
```
kafka-console-consumer --from-beginning --topic dest-filterdemo5  --bootstrap-server kafka.destination.svc.cluster.local:9071  --consumer.config /tmp/kafka.properties
```

## Filter and topic list together 

### With prefix 
If you're using `prefix` you must include `sourceTopicName` as well. 

```
  mirrorTopics:
  - name: merge-dest-atopic # must match prefix as a name https://docs.confluent.io/operator/current/co-link-clusters.html#create-a-mirror-topic
    sourceTopicName: atopic
```

Create a set of topics (newfilterdemo 1-5):  
```
kubectl -n destination exec -it notcflt  -- bash
for i in {1..5}; do /opt/kafka_2.13-3.3.1/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --partitions 3 --replication-factor 1 --topic newfilterdemo$i; done
for i in {1..5}; do seq 1000 | /opt/kafka_2.13-3.3.1/bin/kafka-console-producer.sh --broker-list localhost:9092 --topic newfilterdemo$i; done

/opt/kafka_2.13-3.3.1/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --partitions 3 --replication-factor 1 --topic atopic
seq 1000 | /opt/kafka_2.13-3.3.1/bin/kafka-console-producer.sh --broker-list localhost:9092 --topic atopic

```
Verify that there are messages in the source topic: 
```
/opt/kafka_2.13-3.3.1/bin/kafka-console-consumer.sh --from-beginning --topic newfilterdemo1 --bootstrap-server localhost:9092 
```

Apply the cluster link: 
```
kubectl -n destination apply -f $TUTORIAL_HOME/clusterlinkfilter-enabled-and-list-prefix.yaml
```
Check the topics on the destination cluster. 

### Without prefix

If you're **NOT** using `prefix` pass the change like so: 

```
  mirrorTopics:
  - name: nopffilterdemo
```
Create a set of topics (newfilterdemo 1-5):  
```
kubectl -n destination exec -it notcflt  -- bash
for i in {1..5}; do /opt/kafka_2.13-3.3.1/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --partitions 3 --replication-factor 1 --topic nopffilterdemo$i; done
for i in {1..5}; do seq 1000 | /opt/kafka_2.13-3.3.1/bin/kafka-console-producer.sh --broker-list localhost:9092 --topic nopffilterdemo$i; done

/opt/kafka_2.13-3.3.1/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --partitions 3 --replication-factor 1 --topic npfatopic
seq 1000 | /opt/kafka_2.13-3.3.1/bin/kafka-console-producer.sh --broker-list localhost:9092 --topic npfatopic

```
Verify that there are messages in the source topic: 
```
/opt/kafka_2.13-3.3.1/bin/kafka-console-consumer.sh --from-beginning --topic nopffilterdemo5 --bootstrap-server localhost:9092 
```

Apply the cluster link: 
```
kubectl -n destination apply -f $TUTORIAL_HOME/clusterlinkfilter-enabled-and-list-noprefix.yaml
```
Check the topics on the destination cluster. 


### Tear down 

```
kubectl -n destination delete -f $TUTORIAL_HOME/clusterlink.yaml
kubectl -n destination delete -f $TUTORIAL_HOME/clusterlinkfilter-enabled.yaml
kubectl -n destination delete -f $TUTORIAL_HOME/clusterlinkfilter-enabled-and-list-prefix.yaml
kubectl -n destination delete -f $TUTORIAL_HOME/clusterlinkfilter-enabled-and-list-noprefix.yaml
kubectl -n destination delete -f $TUTORIAL_HOME/zk-kafka-destination.yaml
kubectl -n destination delete secret password-encoder-secret
kubectl -n destination delete secret rest-credential
kubectl -n destination delete secret destination-tls-group1
kubectl -n destination delete secret destination-tls-zk1
kubectl -n destination delete secret ca-pair-sslcerts
kubectl -n destination delete secret credential
kubectl -n destination delete -f $TUTORIAL_HOME/zk-kafka-source.yaml
kubectl delete ns destination
helm -n default delete confluent-operator
```