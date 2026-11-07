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

1. Create jaas config secret
    ```bash
    kubectl create -n operator secret generic oauth-jaas --from-file=oauth.txt=oauth_jaas.txt
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
3. Run topic command
   ```bash
   kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9073 --topic test-topic-internal --create --replication-factor 3 --command-config /tmp/kafka.properties
   ```