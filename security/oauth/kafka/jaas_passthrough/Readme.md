## Introduction

## Pre-requisite

Follow [Sso](../../keycloak/) example to deploy keycloak

## Deploy Confluent for Kubernetes

1. Set up the Helm Chart:
```bash
   helm repo add confluentinc https://packages.confluent.io/helm
```
Note that it is assumed that your Kubernetes cluster has a ``confluent`` namespace available, otherwise you can create it by running ``kubectl create namespace confluent``. 

2.. Install Confluent For Kubernetes using Helm:
```bash
     helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace operator
```
3. Check that the Confluent For Kubernetes pod comes up and is running:
```bash    
     kubectl get pods --namespace operator
```

## Deployment

1. Create jass config pass through secret
    ```bash
    kubectl create -n operator secret generic pass-through-internal --from-file=oauth-jass.conf=oauth_jass_internal.txt
    kubectl create -n operator secret generic pass-through-repl --from-file=oauth-jass.conf=oauth_jass_repl.txt
    ```
2. apply cp_components.yaml
    ```bash
    kubectl apply -f cp_components.yaml
    ```
   
## Testing

1. Copy updated kafka.properties in /tmp
    ```bash
    kubectl cp -n operator kafka.properties  kafka-0:/tmp/kafka.properties
    ```
2. Do Shell
   ```bash
   kubectl -n operator exec kafka-0 -it /bin/bash
   ```
3. Run topic command for internal 9071
   ```bash
   kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9071 --topic test-topic --create --replication-factor 3 --command-config /tmp/kafka.properties
   kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9071 --topic test-topic --describe --command-config /tmp/kafka.properties
   kafka-console-producer   --bootstrap-server kafka.operator.svc.cluster.local:9071 --topic test-topic --producer.config /tmp/kafka.properties
   kafka-console-consumer   --bootstrap-server kafka.operator.svc.cluster.local:9071 --topic test-topic --from-beginning --consumer.config /tmp/kafka.properties
   ```
4. Run topic command for replication 9072
   ```bash
   kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9072 --topic test-topic --create --replication-factor 3 --command-config /tmp/kafka.properties
   kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9072 --topic test-topic --describe --command-config /tmp/kafka.properties
   kafka-console-producer   --bootstrap-server kafka.operator.svc.cluster.local:9072 --topic test-topic --producer.config /tmp/kafka.properties
   kafka-console-consumer   --bootstrap-server kafka.operator.svc.cluster.local:9072 --topic test-topic --from-beginning --consumer.config /tmp/kafka.properties
   ```   