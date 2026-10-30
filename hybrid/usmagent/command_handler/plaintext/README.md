## Deploy USM Agent Command Handler without authentication

The Command Handler manages the Connect cluster `connect`. Its REST endpoint and group.id are discovered from the Connect CR.

### Pre-requisite
- Deploy Confluent For Kubernetes (CFK) Operator. The Command Handler needs CFK 3.4.0 and USM Agent 1.3.0 or later.
```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --namespace confluent
```

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/usmagent/command_handler/plaintext
```

### Generate ccloud secret. Please update the usm-ccloud.txt file with your credentials before running the command
```
kubectl create secret generic usm-ccloud-cred --from-file=basic.txt=$TUTORIAL_HOME/usm-ccloud.txt -n confluent
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
