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
  confluentinc/confluent-for-kubernetes -n destination
```

### create a JAAS config ccloud-jaas.conf with API-KEY/SECRET credentials for Confluent Cloud
```
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule   required username='[API_KEY]'   password='[SECRET]';
```


### create required secrets
Create the ccloud secret from the JAAS file
```
kubectl -n destination create secret generic ccloud-credential --from-file=plain-jaas.conf=ccloud-jaas.conf
```

### create required certificates to connect to Confluent Cloud

Get the certificates for the ccloud cluster. This will return the server cert and the CA cert in that order.
Save these certs in fullchain.pem and cacert.pem respectively.

```
openssl s_client -showcerts -servername <FQDN> \
-connect <REST-endpoint>  < /dev/null
```

> INFO
> Use FQDN of the Confluent Cloud REST endpoint

Example:
```
openssl s_client -showcerts -servername pkc-xxxx.eastus.azure.confluent.cloud -connect pkc-xxxx.eastus.azure.confluent.cloud:443
```

### Set up secrets
#### create secret for the certificates to connect to Confluent Cloud
```
kubectl -n destination create secret generic source-tls-ccloud \
    --from-file=fullchain.pem=$TUTORIAL_HOME/fullchain.pem \
    --from-file=cacerts.pem=$TUTORIAL_HOME/cacert.pem 
    
```
#### create password encoder secret
```
 kubectl -n destination create secret generic password-encoder-secret --from-file=password-encoder.txt=password-encoder-secret.txt
```

#### create secret for Kafka REST
```
kubectl -n destination create secret generic rest-credential \
    --from-file=basic.txt=$TUTORIAL_HOME/rest-credential.txt  
```

#### deploy destination zookeeper and kafka cluster in namespace `destination`

    kubectl apply -f $TUTORIAL_HOME/zk-kafka-destination.yaml

After the Kafka cluster is in running state, create cluster link between source and destination. Cluster link will be created in the destination cluster

#### Create clusterlink between source and destination

> IMPORTANT: substitute the Confluent Cloud bootstrap endpoint and cluster id in clusterlink-sasl-ssl.yaml
```
bootstrapEndpoint: pkc-xxxx.eastus.azure.confluent.cloud:9092 
clusterID: lkc-yyyyy
```

    kubectl apply -f $TUTORIAL_HOME/clusterlink-sasl-ssl.yaml
    

### Verify Cluster Linking is working in destination cluster

#### Check if all Confluent resources are up and running

```
kubectl get confluent -n destination

NAME                                                   ID                       STATUS    DESTCLUSTERID            SRCCLUSTERID   MIRRORTOPICCOUNT   AGE
clusterlink.platform.confluent.io/clusterlinkus-demo   xxxxxx-yyyyyy   CREATED   <dest-cluster-id>   lkc-xxxxx     1                  5m5s

NAME                                REPLICAS   READY   STATUS    AGE
kafka.platform.confluent.io/kafka   3          3       RUNNING   11m

NAME                                        REPLICAS   READY   STATUS    AGE
zookeeper.platform.confluent.io/zookeeper   3          3       RUNNING   11m

NAME                                                          AGE
kafkarestclass.platform.confluent.io/destination-kafka-rest   11m
```

Look for `clusterlink.platform.confluent.io/clusterlinkus-demo` in the output above and verify it's in good running state.

#### Open a terminal access into the destination kafka pod
    kubectl -n destination exec kafka-0 -it -- bash

#### produce a message in the Confluent Cloud topic
Go the UI and produce a message into the topic called demo.

#### consume in destination kafka cluster and confirm message delivery in destination cluster

    kafka-console-consumer --from-beginning --topic demo --bootstrap-server  kafka.destination.svc.cluster.local:9071 

## Tear Down

```
kubectl delete -f $TUTORIAL_HOME/clusterlink-ccloud-to-cfk.yaml
kubectl delete clusterlink.platform.confluent.io/clusterlinkus-demo
kubectl delete -f $TUTORIAL_HOME/zk-kafka-destination.yaml
kubectl delete secret rest-credential -n destination
kubectl delete secret password-encoder-secret -n destination
kubectl delete secret source-tls-ccloud -n destination
kubectl delete secret ccloud-credential -n destination
```