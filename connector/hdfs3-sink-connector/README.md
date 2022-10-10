# HDFS 3 sink Connector

In this example, you'll setup the followings:  
* Hadoop server to leverage in this demo
* Confluent Platform with Connect and HDFS 3 sink connector jar files.  


You will install and manage the HDFS 3 sink connector plugin through the declarative `Connector` CRD.  
In this scenario, we deploy the a Confluent cluster without security.  
## Set up Pre-requisites

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/connector/hdfs3-sink-connector
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

## Deploy Hadoop cluster with all the dependencies   

```
kubectl --namespace confluent apply -f $TUTORIAL_HOME/hdfs-server.yaml
```

Check that all components were created: 

```
kubectl --namespace confluent get pods 

NAME                                        READY   STATUS    RESTARTS   AGE
datanode-7bc7865674-l6lkc                   1/1     Running   0          10m
historyserver-868b58dc99-szcdd              1/1     Running   1          10m
hive-metastore-757fd95bf9-vpzs8             1/1     Running   0          10m
hive-metastore-postgresql-9ddc48484-nwkfb   1/1     Running   0          10m
hive-server-76d5bb47d6-wgbwt                1/1     Running   0          10m
namenode-685cdb7fc5-xpddc                   1/1     Running   0          10m
nodemanager-8476f7f8cd-829wv                1/1     Running   1          10m
presto-coordinator-666bb48897-8vpsk         1/1     Running   0          10m
resourcemanager-9f7c6958c-8gmxs             1/1     Running   0          10m
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

## Create topic

Once the Kafka cluster is ready create a topic:    
```
kubectl --namespace confluent apply -f $TUTORIAL_HOME/topic.yaml
```  

Check topic 
```
kubectl --namespace confluent get topic
```

## Create Connector

Create connector 
```
kubectl --namespace confluent apply -f $TUTORIAL_HOME/connector.yaml
```
Check connector 
```
kubectl --namespace confluent get connector
```

## Validate the connector

Messages are sent to `test-hdfs` topic using console producer on the `connect` pod: 

Bash into the  `connect` pod:  
```
 kubectl --namespace confluent exec connect-0  -it -- bash                              
```

Produce few messages: 

```
seq -f "{\"f1\": \"value%g\"}" 10 |   kafka-avro-console-producer --broker-list kafka:9071 \
--property schema.registry.url=http://schemaregistry:8081 \
--topic test-hdfs \
--property value.schema='{"type":"record","name":"myrecord","fields":[{"name":"f1","type":"string"}]}'
```   

Exit the pod.

## Validation

After a few seconds, HDFS should contain files in `/topics/test-hdfs`, check it from the namenode pod:  

```
export POD_NAME=$(kubectl --namespace confluent get pods -l "io.kompose.service=namenode" -o jsonpath="{.items[0].metadata.name}")  

echo $POD_NAME

kubectl --namespace confluent exec $POD_NAME  -it -- bash  -c "/opt/hadoop-3.1.3/bin/hdfs dfs -ls /topics/test-hdfs"          

WARNING: HADOOP_PREFIX has been replaced by HADOOP_HOME. Using value of HADOOP_PREFIX.
Found 10 items
drwxr-xr-x   - appuser supergroup          0 2022-07-11 09:02 /topics/test-hdfs/f1=value1
drwxr-xr-x   - appuser supergroup          0 2022-07-11 09:02 /topics/test-hdfs/f1=value10
drwxr-xr-x   - appuser supergroup          0 2022-07-11 09:02 /topics/test-hdfs/f1=value2
drwxr-xr-x   - appuser supergroup          0 2022-07-11 09:02 /topics/test-hdfs/f1=value3
drwxr-xr-x   - appuser supergroup          0 2022-07-11 09:02 /topics/test-hdfs/f1=value4
drwxr-xr-x   - appuser supergroup          0 2022-07-11 09:02 /topics/test-hdfs/f1=value5
drwxr-xr-x   - appuser supergroup          0 2022-07-11 09:02 /topics/test-hdfs/f1=value6
drwxr-xr-x   - appuser supergroup          0 2022-07-11 09:02 /topics/test-hdfs/f1=value7
drwxr-xr-x   - appuser supergroup          0 2022-07-11 09:02 /topics/test-hdfs/f1=value8
drwxr-xr-x   - appuser supergroup          0 2022-07-11 09:02 /topics/test-hdfs/f1=value9
```

## Tear down

```
kubectl --namespace confluent delete -f $TUTORIAL_HOME/connector.yaml
kubectl --namespace confluent delete -f $TUTORIAL_HOME/topic.yaml
kubectl --namespace confluent delete -f $TUTORIAL_HOME/confluent-platform.yaml
kubectl --namespace confluent delete -f $TUTORIAL_HOME/hdfs-server.yaml
```

## Notes 

Since the Connect leverages the built in libraries of the Hadoop client a name for the user of the pod is needed.
By default Confluent Platform uses ` user ID 1001` which has no name:  


```
bash-4.4$ whoami
whoami: cannot find name for user ID 1001
```

The connector will fail with the following if we don't correct it: 

```
Caused by: org.apache.hadoop.security.KerberosAuthException: failure to login: javax.security.auth.login.LoginException: java.lang.NullPointerException: invalid null input: name
```

To overcome this limitation we include `podTemplate` `podSecurityContext` for the connect pod: 

```
  podTemplate:
    podSecurityContext:
      fsGroup: 1000
      runAsUser: 1000
      runAsNonRoot: true
```

This will use the built in `appuser`.  
```
$ whoami
appuser
```
