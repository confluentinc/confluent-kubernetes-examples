## Deploy USM Agent Command Handler with Basic Auth

The Command Handler manages the Connect cluster `connect`, whose REST API requires basic authentication. Its REST endpoint and group.id are discovered from the Connect CR.

### Pre-requisite
- Deploy Confluent For Kubernetes (CFK) Operator. The Command Handler needs CFK 3.4.0 and USM Agent 1.3.0 or later.
```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --namespace confluent
```

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/usmagent/command_handler/basic_auth
```

### Generate ccloud secret. Please update the usm-ccloud.txt file with your credentials before running the command
```
kubectl create secret generic usm-ccloud-cred --from-file=basic.txt=$TUTORIAL_HOME/usm-ccloud.txt -n confluent
```

### Generate Basic Auth credentials for USM Agent
```
kubectl create secret generic usm-basic-auth --from-file=basic.txt=$TUTORIAL_HOME/usm-basic.txt -n confluent
```

### Generate Basic Auth client credentials for Kraft, Kafka and Connect
```
kubectl create secret generic usm-cp-cred --from-file=basic.txt=$TUTORIAL_HOME/usm-cp-cred.txt -n confluent
```

### Generate Basic Auth users for the Connect REST API
```
kubectl create secret generic connect-server-basic --from-file=basic.txt=$TUTORIAL_HOME/connect-server-basic.txt -n confluent
```

### Generate the credentials the Command Handler and the Connector use to call the Connect REST API
```
kubectl create secret generic ch-connect-cred --from-file=basic.txt=$TUTORIAL_HOME/ch-connect-cred.txt -n confluent
```

### Deploy USM Agent
```
kubectl apply -f $TUTORIAL_HOME/usmagent.yaml
```

### Deploy Confluent Platform
```
kubectl apply -f $TUTORIAL_HOME/confluent_platform.yaml
```

### Create Kafka topic
```
kubectl apply -f $TUTORIAL_HOME/kafkatopic.yaml
```

### Create Connector
```
kubectl apply -f $TUTORIAL_HOME/connector.yaml
```

### Login to Confluent Cloud to Register your Confluent Platform Cluster
