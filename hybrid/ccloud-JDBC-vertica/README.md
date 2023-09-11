# Kafka Connect to Confluent Cloud

In this example, you'll set up the following:  
*  Deploy a self managed Vertica server for the connector to utilize  
*  Self-managed Kafka Connect cluster connected to Confluent Cloud
*  Install and manage the JDBC source connector plugin through the declarative `Connector` CRD using bulk mode 
*  Install and manage the JDBC source connector plugin through the Connect REST endpoint  using timestamp+incrementing mode


## Set up Pre-requisites

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/ccloud-JDBC-vertica
```

Create namespace

```
kubectl create ns confluent
```
### Create Vertica server 

Use the following deployment file to create a Vertica cluster: 

```
kubectl -n confluent apply -f $TUTORIAL_HOME/vertica-deployment.yaml
```

Export the Vertica pod name: 
```
export POD_NAME=$(kubectl -n confluent get pods -l service_vertica=vertica -o=jsonpath='{.items..metadata.name}')
kubectl exec -it $POD_NAME -- sh
```

Inside the shell you will create a table, entries and a readonly user (using database called docker )  

```
/opt/vertica/bin/vsql -hvertica -Udbadmin


CREATE SEQUENCE IF NOT EXISTS test_id_seq;
CREATE TABLE IF NOT EXISTS test (
   id INTEGER NOT NULL DEFAULT NEXTVAL('test_id_seq') PRIMARY KEY,
   name VARCHAR(100),
   email VARCHAR(200),
   department VARCHAR(200),
   modified TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);


CREATE ROLE RO_role;
GRANT USAGE ON SCHEMA public TO RO_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO RO_role;
CREATE USER readonlymoshe IDENTIFIED BY 'password';
GRANT RO_Role TO readonlymoshe;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO RO_role;
ALTER USER readonlymoshe DEFAULT ROLE RO_role;
ALTER USER readonlymoshe SEARCH_PATH public;


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

COMMIT;
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

Add username and key for the hosted Confluent Platform (Cloud and Schema)

```
kubectl -n confluent create secret generic ccloud-credentials --from-file=plain.txt=$TUTORIAL_HOME/ccloud-credentials.txt  

kubectl -n confluent create secret generic ccloud-sr-credentials --from-file=basic.txt=$TUTORIAL_HOME/ccloud-sr-credentials.txt
```

## Deploy self-managed Kafka Connect connecting to Confluent Cloud

In the kafka-connect.yaml file, replace schemaRegistry url and bootstrapEndpoint with your own servers.

```
kubectl -n confluent apply -f $TUTORIAL_HOME/kafka-connect.yaml
```
## Shell to the Connect Container  

```
kubectl exec connectverticademo-0 -it -n confluent -- bash
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

### Create topic to load data from table into (CRD connector)

```
kafka-topics --command-config /opt/confluentinc/etc/connect/consumer.properties \
--bootstrap-server CCLOUD:9092  \
--create \
--partitions 3 \
--replication-factor 3 \
--topic verticacrd_test
```

### Create topic to load data from table into (REST API endpoint connector)

```
kafka-topics --command-config /opt/confluentinc/etc/connect/consumer.properties \
--bootstrap-server CCLOUD:9092  \
--create \
--partitions 3 \
--replication-factor 3 \
--topic verticarestapi_test
```

## Create Connector


### Example for the CRD connector  

Outside the Connect pod shell you can issue the command:  
```
 kubectl -n confluent apply -f $TUTORIAL_HOME/connector.yaml 
```

### Example for the REST API endpoint connector  

Create jdbc source connector from the connect pod: 


```
kubectl exec connectverticademo-0 -it -n confluent -- bash


curl -X POST \
-H "Content-Type: application/json" \
--data '{
    "name": "quickstart-jdbc-source-restapi",
    "config": {
        "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
        "tasks.max": 1,
        "connection.url": "jdbc:vertica://vertica:5433/docker",
        "connection.password": "password",
        "connection.user": "readonlymoshe",
        "mode": "timestamp+incrementing",
        "incrementing.column.name": "id",
        "timestamp.column.name": "modified",
        "topic.prefix": "verticarestapi_test",
        "poll.interval.ms": "1000",
         "query":"SELECT * FROM ( select * FROM test) subtab"
    }
}' http://localhost:8083/connectors/
```
## Validation

### Check Connector  
Check if connector is running   
#### CRD connector  endpoint 
```
curl -X GET http://localhost:8083/connectors/verticacrd/status
```

#### REST API connector endpoint    
```
curl -X GET http://localhost:8083/connectors/quickstart-jdbc-source-restapi/status
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
--topic verticacrd_test \
--consumer.config /opt/confluentinc/etc/connect/consumer.properties \
--property schema.registry.url=SR_URL \
--property schema.registry.basic.auth.user.info=SR_USER:SR_SECRET \
--property basic.auth.credentials.source=USER_INFO \
--from-beginning
```

#### Consume from the topic that is used by the REST API created connector:

```
kafka-avro-console-consumer \
--bootstrap-server CCLOUD:9092 \
--topic verticarestapi_test \
--consumer.config /opt/confluentinc/etc/connect/consumer.properties \
--property schema.registry.url=SR_URL \
--property schema.registry.basic.auth.user.info=SR_USER:SR_SECRET \
--property basic.auth.credentials.source=USER_INFO \
--from-beginning
```

You should see the table entries. 

## Tear down
```
kubectl delete -f $TUTORIAL_HOME/kafka-connect.yaml
kubectl delete $TUTORIAL_HOME/vertica-deployment.yaml
helm -n confluent delete operator
```

