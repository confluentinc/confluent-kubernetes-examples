## Deploy USM Agent with Basic Auth

### Pre-requisite
- Deploy Confluent For Kubernetes (CFK) Operator
```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --namespace confluent
```

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/usmagent/basic_auth
```

### Generate ccloud secret. Please update the setu-ccloud.txt file with your credentials before running the command
```
kubectl create secret generic setu-ccloud-cred --from-file=basic.txt=$TUTORIAL_HOME/setu-ccloud.txt -n confluent
```

### Generate Basic Auth credentials for USM Agent
```
kubectl create secret generic setu-basic-auth --from-file=basic.txt=$TUTORIAL_HOME/setu-basic.txt -n confluent
```

### Generate Basic Auth client credentials for Kraft, Kafka and Connect
```
kubectl create secret generic setu-cp-cred --from-file=basic.txt=$TUTORIAL_HOME/setu-cp-cred.txt -n confluent
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