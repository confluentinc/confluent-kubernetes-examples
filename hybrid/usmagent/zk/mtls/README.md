## Deploy USM Agent with mutual TLS (ZK mode)

### Pre-requisite
- Confluent Platform 7.9.6+
- CFK Operator 3.1.2+ or 3.2.0+ (required for USM feature support in ZK mode)
- In ZK mode, `inter.broker.protocol.version` must be 2.8 or above for USM metadata emission to work. For greenfield deployments, CFK defaults this to 2.6, so an explicit `configOverrides` is required (see `confluent_platform.yaml`). For brownfield deployments where CFK has previously upgraded CP, the version may already be 2.8+. Verify the current value first and only apply the override if it is below 2.8.
- Deploy Confluent For Kubernetes (CFK) Operator
```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --namespace confluent --version 0.1514.1
```

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/usmagent/zk/mtls
```

### Generate ccloud secret. Please update the usm-ccloud.txt file with your credentials before running the command
```
kubectl create secret generic usm-ccloud-cred --from-file=basic.txt=$TUTORIAL_HOME/usm-ccloud.txt -n confluent
```

### Create TLS certificates

In this scenario, you'll configure authentication using the mTLS mechanism. With mTLS, Confluent components and clients use TLS certificates for authentication. The certificate has a CN that identifies the principal name.

Each Confluent component service should have its own TLS certificate. In this scenario, you'll
generate a server certificate for each Confluent component service. Follow [these instructions](../../../../assets/certs/component-certs/README.md) to generate these certificates.

#### Provide component TLS certificates

```

kubectl create secret generic tls-kafka \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../../../assets/certs/component-certs/generated/kafka-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../../../assets/certs/component-certs/generated/kafka-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-connect \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../../../assets/certs/component-certs/generated/connect-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../../../assets/certs/component-certs/generated/connect-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-usmagent \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../../../assets/certs/component-certs/generated/usmagent-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../../../assets/certs/component-certs/generated/usmagent-server-key.pem \
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
