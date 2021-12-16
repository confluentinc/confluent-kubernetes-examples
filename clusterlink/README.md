## ClusterLink Setup

### Kafka Cluster with Basic Authentication
Note: in this example, both source and destination kafka are run in SASL_SSL mode, source cluster and destination cluster use auto-generated certs use tls group1

### Pre-requisite
- deploy operator with namespaced false, refer to [Here](../../../charts/README.md)
- create secret `credential` in both source cluster and destination cluster namespace, refer to [Here](../../../config/samples/README.md) in both source and destination namespace
  Following was used in this playbook
### create required secrets
    kubectl create -n origin secret generic credential --from-file=plain.txt=config/samples/kafka/files/plain.txt --from-file=plain-users.json=config/samples/kafka/files/plain-users.json --from-file=basic.txt=config/samples/controlcenter/files/basic.txt
    kubectl create -n destination secret generic credential --from-file=plain.txt=config/samples/kafka/files/plain.txt --from-file=plain-users.json=config/samples/kafka/files/plain-users.json --from-file=basic.txt=config/samples/controlcenter/files/basic.txt

- create namespace origin and destination
       
        kubectl create ns origin
        kubectl create ns destination


### Source Cluster Deployment
### create required secrets
    kubectl -n origin create secret generic origin-tls-group1 --from-file=fullchain.pem=resource/files/certs/fullchain.pem --from-file=cacerts.pem=resource/files/certs/cacerts.pem --from-file=privkey.pem=resource/files/certs/privkey.pem
    kubectl -n origin create secret tls  ca-pair-sslcerts --cert=../../certs/ca/ca.pem --key=../../certs/ca/ca-key.pem
    kubectl -n origin create secret generic rest-credential --from-file=basic.txt=resource/files/rest-credential.txt

#### deploy source zookeeper, kafka cluster and topic `demo` in namespace `origin`

    kubectl apply -f resource/basic/zk-kafka-origin.yaml

### Destination Cluster Deployment
#### create required secrets
     kubectl -n destination create secret generic destination-tls-group1 --from-file=fullchain.pem=resource/files/certs/fullchain.pem --from-file=cacerts.pem=resource/files/certs/cacerts.pem --from-file=privkey.pem=resource/files/certs/privkey.pem
     kubectl -n destination create secret generic origin-tls-group1 --from-file=fullchain.pem=resource/files/certs/fullchain.pem --from-file=cacerts.pem=resource/files/certs/cacerts.pem --from-file=privkey.pem=resource/files/certs/privkey.pem
     kubectl -n destination create secret tls  ca-pair-sslcerts --cert=../../certs/ca/ca.pem --key=../../certs/ca/ca-key.pem
     kubectl -n destination create secret generic rest-credential --from-file=basic.txt=resource/files/rest-credential.txt
     kubectl -n destination create secret generic password-encoder-secret --from-file=password_encoder_secret=resource/files/password-encoder-secret.txt
      
#### deploy destination zookeeper and kafka cluster in namespace `destination`

    kubectl apply -f resource/basic/zk-kafka-destination.yaml

After the Kafka cluster is in running state, create cluster link between source and destination. Cluster link will be created in the destination cluster

#### create clusterlink between source and destination
    kubectl apply -f resource/basic/clusterlink-basic.yaml
    

### Run test

#### exec into source kafka pod
    kubectl -n origin exec kafka-0 -it -- bash

#### create kafka.properties

    cat <<EOF > /tmp/kafka.properties
    bootstrap.servers=kafka.origin.svc.cluster.local:9071
    sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=kafka password=kafka-secret;
    sasl.mechanism=PLAIN
    security.protocol=SASL_SSL
    ssl.truststore.location=/mnt/sslcerts/truststore.p12
    ssl.truststore.password=mystorepassword
    EOF

#### produce in source kafka cluster

    seq 100 | kafka-console-producer --topic demo --broker-list kafka.origin.svc.cluster.local:9071 --producer.config kafka.properties
#### open a new terminal and exec into destination kafka pod
    kubectl -n destination exec kafka-0 -it -- bash
#### create kafka.properties for destination kafka cluster
    cat <<EOF > /tmp/kafka.properties
    bootstrap.servers=kafka.destination.svc.cluster.local:9071
    sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=kafka password=kafka-secret;
    sasl.mechanism=PLAIN
    security.protocol=SASL_SSL
    ssl.truststore.location=/mnt/sslcerts/truststore.p12
    ssl.truststore.password=mystorepassword
    EOF
#### validate topic is created in destination kafka cluster
    kafka-topics --describe --topic demo --bootstrap-server kafka.destination.svc.cluster.local:9071 --command-config kafka.properties

#### consume in destination kafka cluster and confirm message delivery in destination cluster

    kafka-console-consumer --from-beginning --topic demo --bootstrap-server  kafka.destination.svc.cluster.local:9071  --consumer.config kafka.properties


### Kafka Cluster with MTLS Authentication
Note: in this example, both source and destination kafka are run in MTLS mode

### Source Cluster Deployment
### Source Cluster Deployment
### create required secrets
    kubectl -n origin create secret generic origin-tls-group1 --from-file=fullchain.pem=resource/files/certs/fullchain.pem --from-file=cacerts.pem=resource/files/certs/cacerts.pem --from-file=privkey.pem=resource/files/certs/privkey.pem
    kubectl -n origin create secret tls  ca-pair-sslcerts --cert=../../certs/ca/ca.pem --key=../../certs/ca/ca-key.pem
    kubectl -n origin create secret generic rest-credential --from-file=basic.txt=resource/files/rest-credential.txt

#### deploy source zookeeper, kafka cluster and topic `demo` in namespace `origin`

    kubectl apply -f resource/mtls/zk-kafka-origin.yaml


### Destination Cluster Deployment
#### create required secrets
     kubectl -n destination create secret generic destination-tls-group1 --from-file=fullchain.pem=resource/files/certs/fullchain.pem --from-file=cacerts.pem=resource/files/certs/cacerts.pem --from-file=privkey.pem=resource/files/certs/privkey.pem
     kubectl -n destination create secret generic origin-tls-group1 --from-file=fullchain.pem=resource/files/certs/fullchain.pem --from-file=cacerts.pem=resource/files/certs/cacerts.pem --from-file=privkey.pem=resource/files/certs/privkey.pem
     kubectl -n destination create secret tls  ca-pair-sslcerts --cert=../../certs/ca/ca.pem --key=../../certs/ca/ca-key.pem
     kubectl -n destination create secret generic rest-credential --from-file=basic.txt=resource/files/rest-credential.txt
     kubectl -n destination create secret generic password-encoder-secret --from-file=password_encoder_secret=resource/files/password-encoder-secret.txt

#### deploy destination zookeeper and kafka cluster in namespace `destination`

    kubectl apply -f resource/mtls/zk-kafka-destination.yaml 

After the Kafka cluster is in running state, create cluster link between source and destination. Cluster link will be created in the destination cluster

#### create clusterlink between source and destination
    kubectl apply -f resource/mtls/clusterlink-mtls.yaml
 
    
### Run test

#### exec into source kafka pod
    kubectl -n origin exec kafka-0 -it -- bash

#### create kafka.properties

    cat <<EOF > /tmp/kafka.properties
    bootstrap.servers=kafka.origin.svc.cluster.local:9071
    security.protocol=SSL
    ssl.keystore.location=/mnt/sslcerts/keystore.p12
    ssl.keystore.password=mystorepassword
    ssl.truststore.location=/mnt/sslcerts/truststore.p12
    ssl.truststore.password=mystorepassword
    EOF

#### produce in source kafka cluster

    seq 100 | kafka-console-producer --topic demo --broker-list kafka.origin.svc.cluster.local:9071 --producer.config kafka.properties
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
    kafka-topics --describe --topic demo --bootstrap-server kafka.destination.svc.cluster.local:9071 --command-config kafka.properties

#### consume in destination kafka cluster and confirm message delivery in destination cluster

    kafka-console-consumer --from-beginning --topic demo --bootstrap-server  kafka.destination.svc.cluster.local:9071  --consumer.config kafka.properties

    
 
