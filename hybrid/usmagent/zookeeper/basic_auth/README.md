## Deploy USM Agent with Basic Auth (ZooKeeper-based)

### Pre-requisite
- Deploy Confluent For Kubernetes (CFK) Operator
```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --namespace confluent
```

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/usmagent/zookeeper/basic_auth
```

### Load Hotfix Images

Download the hotfix images from `https://hotfix-packages.confluent.io/7.9.4-cp1/images/` and load them into your container registry:

```
docker load -i cp-kafka-7.9.4-cp1-rc260105153205-latest-ubi8.tar.gz
docker load -i cp-zookeeper-7.9.4-cp1-rc260105153205-latest-ubi8.tar.gz
docker load -i cp-kafka-connect-7.9.4-cp1-rc260105153205-latest-ubi8.tar.gz

docker tag confluentinc/cp-kafka:7.9.4-cp1-rc260105153205-latest-ubi8 <your-registry>/confluentinc/cp-kafka:7.9.4-cp1-rc260105153205-latest-ubi8
docker tag confluentinc/cp-zookeeper:7.9.4-cp1-rc260105153205-latest-ubi8 <your-registry>/confluentinc/cp-zookeeper:7.9.4-cp1-rc260105153205-latest-ubi8
docker tag confluentinc/cp-kafka-connect:7.9.4-cp1-rc260105153205-latest-ubi8 <your-registry>/confluentinc/cp-kafka-connect:7.9.4-cp1-rc260105153205-latest-ubi8

docker push <your-registry>/confluentinc/cp-kafka:7.9.4-cp1-rc260105153205-latest-ubi8
docker push <your-registry>/confluentinc/cp-zookeeper:7.9.4-cp1-rc260105153205-latest-ubi8
docker push <your-registry>/confluentinc/cp-kafka-connect:7.9.4-cp1-rc260105153205-latest-ubi8
```

Update the `<your-registry>` placeholder in the YAML files with your container registry.

### Generate ccloud secret. Please update the usm-ccloud.txt file with your credentials before running the command
```
kubectl create secret generic usm-ccloud-cred --from-file=basic.txt=$TUTORIAL_HOME/usm-ccloud.txt -n confluent
```

### Generate Basic Auth credentials for USM Agent
```
kubectl create secret generic usm-basic-auth --from-file=basic.txt=$TUTORIAL_HOME/usm-basic.txt -n confluent
```

### Generate Basic Auth client credentials for Kafka and Connect
```
kubectl create secret generic usm-cp-cred --from-file=basic.txt=$TUTORIAL_HOME/usm-cp-cred.txt -n confluent
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
