## ClusterLink Setup

### Kafka Cluster with Basic Authentication
In this example, both source and destination kafka are run in SASL_SSL mode, source cluster and destination cluster use tls group1

## Set up Pre-requisites
Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```bash
export TUTORIAL_HOME=<Tutorial directory>/security/oauth/client_assertion/clusterlinking
```

Create two namespaces, one for the source cluster components and one for the destination cluster components.
Note:: in this example, only deploy zookeeper and kafka for source and zookeeper, kafka and connect for destination

```bash
kubectl create ns source
kubectl create ns destination
```

Deploy Confluent for Kubernetes (CFK) in cluster mode, so that the one CFK instance can manage Confluent deployments in multiple namespaces. Here, CFk is deployed to the `default` namespace.
```bash
helm upgrade --install confluent-operator \
confluentinc/confluent-for-kubernetes \
--namespace default --set namespaced=false
```

### create required secrets
```bash
kubectl -n source create secret generic credential \
--from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
--from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
--from-file=basic.txt=$TUTORIAL_HOME/creds-basic-users.txt

kubectl -n destination create secret generic credential \
--from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
--from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
--from-file=basic.txt=$TUTORIAL_HOME/creds-basic-users.txt
```

### Source Cluster Deployment

### deploy keycloak
Deploy keycloak by following the steps [here](../keycloak/README.md).

#### deploy source kraft, kafka cluster and topic `demo` in namespace `source`
```bash
kubectl apply -f $TUTORIAL_HOME/kraft-kafka-source.yaml
```

### Destination Cluster Deployment
#### create required secrets
```bash
kubectl -n destination create secret generic password-encoder-secret \
--from-file=password-encoder.txt=$TUTORIAL_HOME/password-encoder-secret.txt
```

#### deploy destination zookeeper and kafka cluster in namespace `destination`
```bash
kubectl apply -f $TUTORIAL_HOME/kraft-kafka-destination.yaml
```

After the Kafka cluster is in running state, create cluster link between source and destination. Cluster link will be created in the destination cluster

#### create clusterlink between source and destination
```bash
kubectl apply -f $TUTORIAL_HOME/clusterlink-sasl-ssl.yaml
```

### Run test

#### exec into source kafka pod
```bash
kubectl -n source exec kafka-0 -it -- bash
```

#### create source kafka.properties
```bash
kubectl cp -n source kafka.properties  kafka-0:/tmp/kafka.properties
```

#### produce in source kafka cluster
```bash
seq 100 | kafka-console-producer --topic demo --broker-list kafka.source.svc.cluster.local:9071 --producer.config /tmp/kafka.properties
```

#### open a new terminal and exec into destination kafka pod
```bash
kubectl -n destination exec kafka-0 -it -- bash
```

#### create kafka.properties for destination kafka cluster
```bash
kubectl cp -n destination kafka.properties  kafka-0:/tmp/kafka.properties
```

#### validate topic is created in destination kafka cluster
```bash
kafka-topics --describe --topic demo-test --bootstrap-server kafka.destination.svc.cluster.local:9071 --command-config /tmp/kafka.properties
```

#### consume in destination kafka cluster and confirm message delivery in destination cluster
```bash
kafka-console-consumer --from-beginning --topic demo --bootstrap-server  kafka.destination.svc.cluster.local:9071  --consumer.config /tmp/kafka.properties
```
