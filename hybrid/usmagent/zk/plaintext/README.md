## USM Agent deployment without authentication (ZK mode)

### Pre-requisite
- Confluent Platform 7.9.6+
- CFK Operator 3.1.2+ or 3.2.0+ (required for USM feature support in ZK mode)
- In ZK mode, `inter.broker.protocol.version` must be 2.8 or above for USM metadata emission to work. For greenfield deployments, CFK defaults this to 2.6, so an explicit `configOverrides` is required (see `confluent_platform.yaml`). For brownfield deployments where CFK has previously upgraded CP, the version may already be 2.8+. Verify the current value first and only apply the override if it is below 2.8.
- Deploy Confluent For Kubernetes (CFK) Operator
```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --namespace confluent --version 0.1514.1
```

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/usmagent/zk/plaintext
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
