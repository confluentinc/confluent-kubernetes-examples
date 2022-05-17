# Schema Exporter Playbook

## Table of Contents
- [Basic setup](#basic-setup)
- [Source Cluster Deployment](#source-cluster-deployment)
- [Destination Cluster Deployment](#destination-cluster-deployment)
- [Verify is schemas are exported](#verify-is-schemas-are-exported)

## Basic setup
- Set the tutorial directory for this tutorial under the directory you downloaded
  the tutorial files:
```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/schemalink/mtls
```

- Deploy Confluent for Kubernetes (CFK) in cluster mode, so that the one CFK instance can manage Confluent deployments in multiple namespaces. Here, CFk is deployed to the `default` namespace.

```
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes \
  --namespace default --set namespaced=false
```
- Check that the Confluent For Kubernetes pod comes up and is running:
```
  kubectl get pods
```

- Create a namespaces

```
  kubectl create ns source
  kubectl create ns destination
```

- Generate a CA pair to use in this tutorial:
```
openssl genrsa -out $TUTORIAL_HOME/ca-key.pem 2048
openssl req -new -key $TUTORIAL_HOME/ca-key.pem -x509 \
  -days 1000 \
  -out $TUTORIAL_HOME/ca.pem \
  -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA"
```  

- Create secret `ca-pair-sslcerts` for operator
```
kubectl -n source create secret tls ca-pair-sslcerts \
    --cert=$TUTORIAL_HOME/ca.pem \
    --key=$TUTORIAL_HOME/ca-key.pem 

kubectl -n destination create secret tls ca-pair-sslcerts \
    --cert=$TUTORIAL_HOME/ca.pem \
    --key=$TUTORIAL_HOME/ca-key.pem   

```


## Source Cluster Deployment
### Create required secrets
    kubectl -n source create secret generic password-encoder-secret --from-file=password-encoder.txt=$TUTORIAL_HOME/password-encoder-secret.txt

### Deploy source zookeeper, kafka cluster, schema registry and a schema in namespace `source`

    kubectl apply -f $TUTORIAL_HOME/zk-kafka-sr-source.yaml

## Destination Cluster Deployment
### Create required secrets
    kubectl -n destination create secret generic password-encoder-secret --from-file=password-encoder.txt=$TUTORIAL_HOME/password-encoder-secret.txt

### Deploy destination zookeeper,kafka and schema registry cluster in namespace `destination`

    kubectl apply -f $TUTORIAL_HOME/zk-kafka-sr-destination.yaml

After the Schema registry is in running state, create schema exporter between source and destination. Schema exporter will be created in the source cluster.

### Create schema exporter between source and destination
    kubectl apply -f $TUTORIAL_HOME/schemaexporter-mtls.yaml


## Verify is schemas are exported

### Exec into source schema registry pod
    kubectl -n source exec -it schemaregistry-1 -- bash

### Check if schema exporter and subject is created
    curl --cert /mnt/sslcerts/tls.crt --key /mnt/sslcerts/tls.key --cacert /mnt/sslcerts/ca.crt https://schemaregistry.source.svc.cluster.local:8081/exporters -u admin:Developer1 -k
    curl --cert /mnt/sslcerts/tls.crt --key /mnt/sslcerts/tls.key --cacert /mnt/sslcerts/ca.crt https://schemaregistry.source.svc.cluster.local:8081/subjects -u admin:Developer1 -k

### Exec into destination schema registry pod
    kubectl -n destination exec -it schemaregistry-1 -- bash

### Check if schema exporter is exported to the custom context
    curl --cert /mnt/sslcerts/tls.crt --key /mnt/sslcerts/tls.key --cacert /mnt/sslcerts/ca.crt https://schemaregistry.destination.svc.cluster.local:8081/subjects -u admin:Developer1 -k
