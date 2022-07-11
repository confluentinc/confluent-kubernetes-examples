# HDFS 3 sink Connector

In this example, you'll setup the followings:  
* Hadoop server to leverage in this demo
* Confluent Platform with Connect and HDSF 3 sink connector jar files.  


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
kubectl apply -f $TUTORIAL_HOME/hdfs-server.yaml
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

## Create topic

Create topic  
```
kubectl apply -f $TUTORIAL_HOME/topic.yaml
```  

Check topic 
```
kubectl get topic -n confluent
```

## Create Connector

Create connector 
```
kubectl apply -f $TUTORIAL_HOME/connector.yaml
```
Check connector 
```
kubectl get connector -n confluent
```

## 

Messages are sent to `test_hdfs` topic using console producer on the `connect` pod: 

Bash into the  `connect` pod:  
```
 kubectl --namespace confluent exec connect-0  -it -- bash                              
```

Produce few messages: 

```
seq -f "{\"f1\": \"value%g\"}" 10 |   kafka-avro-console-producer --broker-list kafka:9071 \
--property schema.registry.url=http://schemaregistry:8081 \
--topic test_hdfs \
--property value.schema='{"type":"record","name":"myrecord","fields":[{"name":"f1","type":"string"}]}'
```

## Validation

After a few seconds, HDFS should contain files in `/topics/test_hdfs`, check it from the namenode pod:  

```
export POD_NAME=$(kubectl --namespace confluent get pods -l "io.kompose.service=namenode" -o jsonpath="{.items[0].metadata.name}")  

kubectl exec $POD_NAME  -it -- bash  -c "/opt/hadoop-3.1.3/bin/hdfs dfs -ls /topics/test_hdfs"          
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value1
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value2
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value3
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value4
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value5
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value6
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value7
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value8
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value9
```

## Tear down

```
kubectl --namespace confluent delete -f $TUTORIAL_HOME/connector.yaml
kubectl --namespace confluent delete -f $TUTORIAL_HOME/topic.yaml
kubectl --namespace confluent delete -f $TUTORIAL_HOME/confluent-platform.yaml
kubectl --namespace confluent delete -f $TUTORIAL_HOME/hdfs-server.yaml
```

## Notes 

Since the Connect leverage the built in libraries of the hadoop client a name for the user of the pod is needed.  
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




















https://kubernetes.io/docs/tasks/configure-pod-container/translate-compose-kubernetes/
 brew install kompose                      

Download playground 

change compose name that you want 

```
kompose convert
kubectl config set-context --current --namespace=confluent
```
Create HDFS playground: 

```
 for i in `ls hdfs-server/ |grep "\.yaml"`; do kubectl apply -f hdfs-server/$i;done
```

Deploy CP 
```
kubectl apply -f confluent-platform.yaml
```


```
 kubectl exec connect-0  -it -- bash                              
```

```
curl -X PUT \
     -H "Content-Type: application/json" \
     --data '{
               "connector.class":"io.confluent.connect.hdfs3.Hdfs3SinkConnector",
               "tasks.max":"1",
               "topics":"test_hdfs",
               "store.url":"hdfs://namenode.confluent.svc.cluster.local:9000",
               "flush.size":"3",
               "hadoop.conf.dir":"/etc/hadoop/",
               "partitioner.class":"io.confluent.connect.storage.partitioner.FieldPartitioner",
               "partition.field.name":"f1",
               "rotate.interval.ms":"120000",
               "hadoop.home":"/opt/hadoop-3.1.3/share/hadoop/common",
               "logs.dir":"/tmp",
               "hive.integration": "true",
               "hive.metastore.uris": "thrift://hive-metastore.confluent.svc.cluster.local:9083",
               "hive.database": "testhive",
               "confluent.license": "",
               "confluent.topic.bootstrap.servers": "kafka.confluent.svc.cluster.local:9071",
               "confluent.topic.replication.factor": "1",
               "key.converter":"org.apache.kafka.connect.storage.StringConverter",
               "value.converter":"io.confluent.connect.avro.AvroConverter",
               "value.converter.schema.registry.url":"http://schemaregistry.confluent.svc.cluster.local:8081",
               "schema.compatibility":"BACKWARD"
          }' \
     http://localhost:8083/connectors/hdfs3-sink/config 
```

Check:  

```
curl -X GET http://localhost:8083/connectors/hdfs3-sink/status
```


DELETE:  

```
curl -X DELETE http://localhost:8083/connectors/hdfs3-sink/
```

Create topic: 

```
kafka-topics --bootstrap-server kafka:9071 --create --partitions 3 --replication-factor 3  --topic test_hdfs
```

Messages are sent to test_hdfs topic using:


```
seq -f "{\"f1\": \"value%g\"}" 10 |   kafka-avro-console-producer --broker-list kafka:9071 \
--property schema.registry.url=http://schemaregistry:8081 \
--topic test_hdfs \
--property value.schema='{"type":"record","name":"myrecord","fields":[{"name":"f1","type":"string"}]}'
```

After a few seconds, HDFS should contain files in /topics/test_hdfs:

```
 kubectl exec namenode-685cdb7fc5-b6vzk  -it -- bash  -c "/opt/hadoop-3.1.3/bin/hdfs dfs -ls /topics/test_hdfs"          

drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value1
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value2
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value3
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value4
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value5
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value6
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value7
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value8
drwxr-xr-x   - root supergroup          0 2019-10-25 08:19 /topics/test_hdfs/f1=value9
```


First pass: 

```

{"name":"hdfs3-sink","connector":{"state":"RUNNING","worker_id":"connect-0.connect.confluent.svc.cluster.local:8083"},"tasks":[{"id":0,"state":"FAILED","worker_id":"connect-0.connect.confluent.svc.cluster.local:8083","trace":"org.apache.kafka.connect.errors.ConnectException: Exiting WorkerSinkTask due to unrecoverable exception.
	at org.apache.kafka.connect.runtime.WorkerSinkTask.deliverMessages(WorkerSinkTask.java:618)
	at org.apache.kafka.connect.runtime.WorkerSinkTask.poll(WorkerSinkTask.java:334)
	at org.apache.kafka.connect.runtime.WorkerSinkTask.iteration(WorkerSinkTask.java:235)
	at org.apache.kafka.connect.runtime.WorkerSinkTask.execute(WorkerSinkTask.java:204)
	at org.apache.kafka.connect.runtime.WorkerTask.doRun(WorkerTask.java:200)
	at org.apache.kafka.connect.runtime.WorkerTask.run(WorkerTask.java:255)
	at java.base/java.util.concurrent.Executors$RunnableAdapter.call(Executors.java:515)
	at java.base/java.util.concurrent.FutureTask.run(FutureTask.java:264)
	at java.base/java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1128)
	at java.base/java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:628)
	at java.base/java.lang.Thread.run(Thread.java:829)
Caused by: java.lang.NullPointerException
	at io.confluent.connect.hdfs3.Hdfs3SinkTask.put(Hdfs3SinkTask.java:109)
	at org.apache.kafka.connect.runtime.WorkerSinkTask.deliverMessages(WorkerSinkTask.java:584)
	... 10 more
"}],"type":"sink"}bash-4.4$ 
```



```
Caused by: org.apache.hadoop.security.KerberosAuthException: failure to login: javax.security.auth.login.LoginException: java.lang.NullPointerException: invalid null input: name
```





Adding:  `connect.hdfs.principal`  
 


```
curl -X PUT \
     -H "Content-Type: application/json" \
     --data '{
               "connector.class":"io.confluent.connect.hdfs3.Hdfs3SinkConnector",
               "tasks.max":"1",
               "topics":"test_hdfs",
               "store.url":"hdfs://namenode.confluent.svc.cluster.local:9000",
               "flush.size":"3",
               "hadoop.conf.dir":"/etc/hadoop/",
               "partitioner.class":"io.confluent.connect.storage.partitioner.FieldPartitioner",
               "partition.field.name":"f1",
               "rotate.interval.ms":"120000",
               "hadoop.home":"/opt/hadoop-3.1.3/share/hadoop/common",
               "logs.dir":"/tmp",
               "hive.integration": "true",
               "hive.metastore.uris": "thrift://hive-metastore.confluent.svc.cluster.local:9083",
               "hive.database": "testhive",
               "confluent.license": "",
               "confluent.topic.bootstrap.servers": "broker:9092",
               "confluent.topic.replication.factor": "1",
               "key.converter":"org.apache.kafka.connect.storage.StringConverter",
               "value.converter":"io.confluent.connect.avro.AvroConverter",
               "value.converter.schema.registry.url":"http://schema-registry:8081",
               "schema.compatibility":"BACKWARD",
               "connect.hdfs.principal": "connect-0"
          }' \
     http://localhost:8083/connectors/hdfs3-sink2/config
```


```
Caused by: org.apache.hadoop.security.KerberosAuthException: failure to login: javax.security.auth.login.LoginException: java.lang.NullPointerException: invalid null input: name
```


Adding `hdfs.namenode.principal`:  

```
curl -X PUT \
     -H "Content-Type: application/json" \
     --data '{
               "connector.class":"io.confluent.connect.hdfs3.Hdfs3SinkConnector",
               "tasks.max":"1",
               "topics":"test_hdfs",
               "store.url":"hdfs://namenode.confluent.svc.cluster.local:9000",
               "flush.size":"3",
               "hadoop.conf.dir":"/etc/hadoop/",
               "partitioner.class":"io.confluent.connect.storage.partitioner.FieldPartitioner",
               "partition.field.name":"f1",
               "rotate.interval.ms":"120000",
               "hadoop.home":"/opt/hadoop-3.1.3/share/hadoop/common",
               "logs.dir":"/tmp",
               "hive.integration": "true",
               "hive.metastore.uris": "thrift://hive-metastore.confluent.svc.cluster.local:9083",
               "hive.database": "testhive",
               "confluent.license": "",
               "confluent.topic.bootstrap.servers": "broker:9092",
               "confluent.topic.replication.factor": "1",
               "key.converter":"org.apache.kafka.connect.storage.StringConverter",
               "value.converter":"io.confluent.connect.avro.AvroConverter",
               "value.converter.schema.registry.url":"http://schema-registry:8081",
               "schema.compatibility":"BACKWARD",
               "hdfs.namenode.principal": "namenodeconnect-0"
          }' \
     http://localhost:8083/connectors/hdfs3-sink3/config
```


Same

```
Caused by: org.apache.hadoop.security.KerberosAuthException: failure to login: javax.security.auth.login.LoginException: java.lang.NullPointerException: invalid null input: name
```


Adding to connect via original payload , without adding any additional values 

```
  podTemplate:
    podSecurityContext:
      fsGroup: 1000
      runAsUser: 1000
      runAsNonRoot: true
```

```
$ whoami
appuser
```

If not providing the podSecurityContext you get no name in the whoami  
  
```
bash-4.4$ whoami
whoami: cannot find name for user ID 1001
```


```
[WARN] 2022-07-08 18:39:00,759 [task-thread-hdfs3-sink-0] org.apache.hadoop.fs.FileSystem createFileSystem - Failed to initialize fileystem hdfs://namenode.confluent.svc.cluster.local:9000: java.lang.IllegalArgumentException: java.net.UnknownHostException: namenode
```

The above indicates that we've passed the initial error and will work as expected. 




I've fixed the services and it's all working as expected now, with the following still needed:  
```
  podTemplate:
    podSecurityContext:
      fsGroup: 1000
      runAsUser: 1000
      runAsNonRoot: true
```


Tear down: 

``` 
 for i in `ls -R |grep "\.yaml" | grep -v pers`; do kubectl delete -f $i;done # avoid all the pvc that might be locked 
 for i in `ls -R |grep "\.yaml"`; do kubectl delete -f $i;done
```

```
 for i in `ls hdfs-server |grep "\.yaml" | grep -v pers`; do kubectl delete -f hdfs-server/$i;done # avoid all the pvc that might be locked 
 for i in `ls hdfs-server/ |grep "\.yaml"`; do kubectl delete -f hdfs-server/$i;done
```

Delete CP 
```
kubectl delete -f confluent-platform.yaml
```

