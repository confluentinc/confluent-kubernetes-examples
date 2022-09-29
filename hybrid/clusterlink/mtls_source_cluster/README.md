## ClusterLink Setup

### Kafka Cluster with Mutual TLS Authentication
In this example, both source and destination kafka are run in mutual TLS mode, source cluster and destination cluster use tls group1

## Set up Pre-requisites
Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/clusterlink/mtls_source_cluster
```

Create two namespaces, one for the source cluster components and one for the destination cluster components.
Note:: in this example, only deploy zookeeper and kafka for source and zookeeper, kafka and connect for destination

```
kubectl create ns source
kubectl create ns destination
```

Deploy Confluent for Kubernetes (CFK) in cluster mode, so that the one CFK instance can manage Confluent deployments in multiple namespaces. Here, CFk is deployed to the `default` namespace.

```
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes \
  --namespace default --set namespaced=false
```

### create required secrets
```
kubectl -n source create secret generic credential \
    --from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
    --from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
    --from-file=basic.txt=$TUTORIAL_HOME/creds-basic-users.txt

kubectl -n destination create secret generic credential \
    --from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
    --from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
    --from-file=basic.txt=$TUTORIAL_HOME/creds-basic-users.txt
```

### Source Cluster Deployment
### create required secrets
```
kubectl -n source create secret generic source-tls-zk1 \
    --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/zookeeper-server.pem \
    --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
    --from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/zookeeper-server-key.pem

kubectl -n source create secret generic source-tls-group1 \
    --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/kafka-server.pem \
    --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
    --from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/kafka-server-key.pem
   
kubectl -n source create secret generic rest-credential \
    --from-file=basic.txt=$TUTORIAL_HOME/rest-credential.txt
    
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
kubectl -n source create secret tls ca-pair-sslcerts \
    --cert=$TUTORIAL_HOME/ca.pem \
    --key=$TUTORIAL_HOME/ca-key.pem 

kubectl -n destination create secret tls ca-pair-sslcerts \
    --cert=$TUTORIAL_HOME/ca.pem \
    --key=$TUTORIAL_HOME/ca-key.pem   

```

#### deploy source zookeeper, kafka cluster and topic `demo` in namespace `source`
```
kubectl apply -f $TUTORIAL_HOME/zk-kafka-source.yaml
```

### Destination Cluster Deployment
#### create required secrets
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
#### deploy destination zookeeper and kafka cluster in namespace `destination`

    kubectl apply -f $TUTORIAL_HOME/zk-kafka-destination.yaml

### Create TLS Secret to connect Source Cluster using PKCS8 Key format.

#### convert key to PKCS8 format
```
openssl pkcs8 -in $TUTORIAL_HOME../../../assets/certs/component-certs/generated/kafka-server-key.pem -topk8 -nocrypt -out $TUTORIAL_HOME../../../assets/certs/component-certs/generated/kafka-server-key-pkcs8.pem
```
#### Create client secret
```
kubectl -n destination create secret generic source-tls-secret \
    --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/kafka-server.pem \
    --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
    --from-file=privkey.pem=$TUTORIAL_HOME../../../assets/certs/component-certs/generated/kafka-server-key-pkcs8.pem
```

After the Kafka cluster is in running state, create cluster link between source and destination. Cluster link will be created in the destination cluster

#### create clusterlink between source and destination
    kubectl apply -f $TUTORIAL_HOME/clusterlink-mtls.yaml


### Run test

#### exec into source kafka pod
    kubectl -n source exec kafka-0 -it -- bash

#### create kafka.properties

    cat <<EOF > /tmp/kafka.properties
    bootstrap.servers=kafka.source.svc.cluster.local:9071
    security.protocol=SSL
    ssl.keystore.location=/mnt/sslcerts/keystore.p12
    ssl.keystore.password=mystorepassword
    ssl.truststore.location=/mnt/sslcerts/truststore.p12
    ssl.truststore.password=mystorepassword
    EOF

#### produce in source kafka cluster

    seq 100 | kafka-console-producer --topic demo --broker-list kafka.source.svc.cluster.local:9071 --producer.config /tmp/kafka.properties
#### open a new terminal and exec into destination kafka pod
    kubectl -n destination exec kafka-0 -it -- bash

#### create kafka.properties for destination kafka cluster
    cat <<EOF > /tmp/kafka.properties
    bootstrap.servers=kafka.destination.svc.cluster.local:9071
    security.protocol=SSL
    ssl.truststore.location=/mnt/sslcerts/truststore.p12
    ssl.truststore.password=mystorepassword
    ssl.keystore.location=/mnt/sslcerts/keystore.p12
    ssl.keystore.password=mystorepassword
    EOF

#### validate topic is created in destination kafka cluster
    kafka-topics --describe --topic demo --bootstrap-server kafka.destination.svc.cluster.local:9071 --command-config /tmp/kafka.properties

#### consume in destination kafka cluster and confirm message delivery in destination cluster

    kafka-console-consumer --from-beginning --topic demo --bootstrap-server  kafka.destination.svc.cluster.local:9071  --consumer.config /tmp/kafka.properties

