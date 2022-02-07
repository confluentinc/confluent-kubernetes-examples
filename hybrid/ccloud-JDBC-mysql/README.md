# Kafka Connect to Confluent Cloud

In this example, you'll set up the following:  
*  Deploy a self managed MySql server for the connector to utilize  
*  Self-managed Kafka Connect cluster connected to Confluent Cloud
*  Install and manage the JDBC source connector plugin through the declarative `Connector` CRD  
*  Install and manage the JDBC source connector plugin through the Connect REST endpoint  


## Set up Pre-requisites

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/ccloud-JDBC-mysql
```

Create namespace

```
kubectl create ns confluent
```
### Create Mysql server 

We are following the [kubernetes](https://kubernetes.io/docs/tasks/run-application/run-single-instance-stateful-application/)


```
kubectl config set-context --current --namespace=confluent
kubectl apply -f https://k8s.io/examples/application/mysql/mysql-pv.yaml
kubectl apply -f https://k8s.io/examples/application/mysql/mysql-deployment.yaml
kubectl get pods -l app=mysql
kubectl run -it --rm --image=mysql:5.6 --restart=Never mysql-client -- mysql -h mysql -ppassword
```

Inside the shell you will create a database, table and entries:  

```
CREATE DATABASE IF NOT EXISTS connect_test;
USE connect_test;

DROP TABLE IF EXISTS test;


CREATE TABLE IF NOT EXISTS test (
  id serial NOT NULL PRIMARY KEY,
  name varchar(100),
  email varchar(200),
  department varchar(200),
  modified timestamp default CURRENT_TIMESTAMP NOT NULL,
  INDEX `modified_index` (`modified`)
);

INSERT INTO test (name, email, department) VALUES ('alice', 'alice@abc.com', 'engineering');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('alice', 'alice@abc.com', 'engineering');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
INSERT INTO test (name, email, department) VALUES ('bob', 'bob@abc.com', 'sales');
```


## Deploy Confluent for Kubernetes

This workflow scenario assumes you are using the namespace `confluent`.

Set up the Helm Chart:

```
helm repo add confluentinc https://packages.confluent.io/helm
```

Install Confluent For Kubernetes using Helm:

```
helm upgrade --install operator confluentinc/confluent-for-kubernetes -n confluent
```
 
Check that the Confluent For Kubernetes pod comes up and is running:

```
kubectl get pods -n confluent
```

## Create Kubernetes Secrets for Confluent Cloud API Key and Confluent Cloud Schema Registry API Key

Add user name and key for the hosted Confluent Platform (Cloud and Schema)

```
kubectl -n confluent create secret generic ccloud-credentials --from-file=plain.txt=$TUTORIAL_HOME/ccloud-credentials.txt  

kubectl -n confluent create secret generic ccloud-sr-credentials --from-file=basic.txt=$TUTORIAL_HOME/ccloud-sr-credentials.txt
```

## Create Kubernetes Secret for the JDBC connector to pull connection URL and password for the mysql server

```
 kubectl -n confluent create secret generic mysql-credential \
  --from-file=sqlcreds.txt=$TUTORIAL_HOME/sqlcreds.txt
```
## Deploy self-managed Kafka Connect connecting to Confluent Cloud

```
kubectl -n confluent apply -f $TUTORIAL_HOME/kafka-connect.yaml
```
## Shell to the Connect Container  

```
kubectl exec connect-0 -it -n confluent -- bash
```

Create consumer properties file:  
```
cat << EOF > /opt/confluentinc/etc/connect/consumer.properties
bootstrap.servers=CCLOUD:9092
security.protocol=SASL_SSL
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule   required username="ccloud-key"   password="ccloud-secret";
ssl.endpoint.identification.algorithm=https
sasl.mechanism=PLAIN
EOF
```

### Create topic to load dat a from table into (CRD connector)
```
kafka-topics --command-config /opt/confluentinc/etc/connect/consumer.properties \
--bootstrap-server CCLOUD:9092  \
--create \
--partitions 3 \
--replication-factor 3 \
--topic quickstart-jdbc-CRD-test
```

### Create topic to load dat a from table into (REST API endpoint connector) 

```
kafka-topics --command-config /opt/confluentinc/etc/connect/consumer.properties \
--bootstrap-server CCLOUD:9092  \
--create \
--partitions 3 \
--replication-factor 3 \
--topic quickstart-jdbc-test
```



## Create Connector


### Example for the CRD connector  

Outside the Connect pod shell you can issue the command:  
```
 kubectl -n confluent apply -f $TUTORIAL_HOME/connector.yaml 
```

### Example for the REST API endpoint connector  
Create jdbc source connector 
```
curl -X POST \
-H "Content-Type: application/json" \
--data '{ "name": "quickstart-jdbc-source", "config": { "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector", "tasks.max": 1, "connection.url": "jdbc:mysql://mysql:3306/connect_test?user=root&password=password", "mode": "incrementing", "incrementing.column.name": "id", "timestamp.column.name": "modified", "topic.prefix": "quickstart-jdbc-", "poll.interval.ms": 1000 } }' \
http://localhost:8083/connectors/
```

## Validation

### Check Connector  
Check if connector is running   
#### CRD connector  endpoint 
```
curl -X GET http://localhost:8083/connectors/mysqlviacrd/status
```

#### REST API connector endpoint    
```
curl -X GET http://localhost:8083/connectors/quickstart-jdbc-source/status
```
### Consume from Cloud topic

Create `log4j` file:  

```
cat << EOF > /tmp/log4j.properties
log4j.rootLogger=WARN, stderr
log4j.appender.stderr=org.apache.log4j.ConsoleAppender
log4j.appender.stderr.layout=org.apache.log4j.PatternLayout
log4j.appender.stderr.layout.ConversionPattern=[%d] %p %m (%c)%n
log4j.appender.stderr.Target=System.err 
EOF
```

Export path:  
```
export SCHEMA_REGISTRY_OPTS="-Dlog4j.configuration=file:/tmp/log4j.properties"
```  

#### Consume from the topic that is used by the CRD created connector:

```
kafka-avro-console-consumer \
--bootstrap-server CCLOUD:9092 \
--topic quickstart-jdbc-CRD-test \
--consumer.config /opt/confluentinc/etc/connect/kafka.properties \
--property schema.registry.url=SR_URL \
--property schema.registry.basic.auth.user.info=SR_USER:SR_SECRET \
--property basic.auth.credentials.source=USER_INFO \
--from-beginning
```

#### Consume from the topic that is used by the REST API created connector:

```
kafka-avro-console-consumer \
--bootstrap-server CCLOUD:9092 \
--topic quickstart-jdbc-test \
--consumer.config /opt/confluentinc/etc/connect/kafka.properties \
--property schema.registry.url=SR_URL \
--property schema.registry.basic.auth.user.info=SR_USER:SR_SECRET \
--property basic.auth.credentials.source=USER_INFO \
--from-beginning
```

You should see the table entries. 

## Tear down
```
kubectl delete -f $TUTORIAL_HOME/kafka-connect.yaml
kubectl delete deployment,svc mysql
kubectl delete pvc mysql-pv-claim
kubectl delete pv mysql-pv-volume
kubectl delete pod mysql-client  
```

