## ClusterLink Setup

### Kafka Cluster connecting to Confluent Cloud
In this example, we spin up a destination Kafka cluster on CFK connecting to Confluent Cloud.

## Set up Pre-requisites
Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/clusterlink/ccloud_source_cluster
```

Create one namespace for the destination cluster components.
Note:: in this example, only deploy zookeeper and kafka for destination

```
kubectl create ns destination
kubectl config set-context --current --namespace destination
```

Deploy Confluent for Kubernetes (CFK) in `destination` namespace.

```
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes 
```

### create a file with API-KEY/SECRET credentials for Confluent Cloud
```
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule   required username='[API_KEY]'   password='[SECRET]';
```


### create required secrets
Create  
```
kubectl -n destination create secret generic ccloud-credential --from-file=plain-jaas.conf=ccloud-jaas.conf
```

### create required certificates to connect to Confluent Cloud

Get the server certificates for the ccloud cluster. This will return the server cert and the ca cert in that order Save these certs in fullchain.pem and cacert.pem

```
openssl s_client -showcerts -servername pkc-41973.westus2.azure.confluent.cloud \
-connect pkc-41973.westus2.azure.confluent.cloud:443  < /dev/null
```

### create secret for the certificates to connect to Confluent Cloud
```
kubectl -n destination create secret generic source-tls-group1 \
    --from-file=fullchain.pem=$TUTORIAL_HOME/fullchain.pem \
    --from-file=cacerts.pem=$TUTORIAL_HOME/cacerts.pem 
    
```


#### create password encoder secret
```
 kubectl -n destination create secret generic password-encoder-secret --from-file=password-encoder.txt=password-encoder-secret.txt
```

#### deploy destination zookeeper and kafka cluster in namespace `destination`

    kubectl apply -f $TUTORIAL_HOME/zk-kafka-destination.yaml

After the Kafka cluster is in running state, create cluster link between source and destination. Cluster link will be created in the destination cluster

#### create clusterlink between source and destination
    kubectl apply -f $TUTORIAL_HOME/clusterlink-sasl-ssl.yaml
    

### Run test

#### exec into destination kafka pod
    kubectl -n destination exec kafka-0 -it -- bash

#### produce a message in the Confluent Cloud topic
Go the UI and produce a message into the topic called demo.

#### consume in destination kafka cluster and confirm message delivery in destination cluster

    kafka-console-consumer --from-beginning --topic demo --bootstrap-server  kafka.destination.svc.cluster.local:9071 

 
