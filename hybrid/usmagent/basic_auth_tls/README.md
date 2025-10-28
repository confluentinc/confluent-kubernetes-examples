## Deploy USM Agent with Basic Auth over TLS

### Pre-requisite
- Deploy Confluent For Kubernetes (CFK) Operator
```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --namespace confluent
```

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/usmagent/basic_auth_tls
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

### Create TLS certificates

You can follow these commands to create a TLS certificate for each component service. In this scenario, you'll
generate a server certificate for each Confluent component service. Follow [these instructions](../../../assets/certs/component-certs/README.md) to generate these certificates.

#### Provide component TLS certificates

```

kubectl create secret generic tls-kraft \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/kraft-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/kraft-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-kafka \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/kafka-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/kafka-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-connect \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/connect-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/connect-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-usmagent \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/usmagent-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/usmagent-server-key.pem \
  --namespace confluent
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