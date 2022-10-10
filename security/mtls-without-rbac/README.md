# Security setup

In this workflow scenario, you'll set up a Confluent Platform cluster with the following security:
- Full TLS network encryption with user provided certificates
- mTLS authentication

Before continuing with the scenario, ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites).

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/mtls-without-rbac
```

## Deploy Confluent for Kubernetes

Set up the Helm Chart:

```
helm repo add confluentinc https://packages.confluent.io/helm
```

Install Confluent For Kubernetes using Helm:

```
helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace confluent
```

Check that the Confluent For Kubernetes pod comes up and is running:

```
kubectl get pods --namespace confluent
```

## Create TLS certificates

In this scenario, you'll configure authentication using the mTLS mechanism. With mTLS, Confluent components and clients use TLS certificates for authentication. The certificate has a CN that identifies the principal name.

Each Confluent component service should have it's own TLS certificate. In this scenario, you'll
generate a server certificate for each Confluent component service. Follow [these instructions](../../assets/certs/component-certs/README.md) to generate these certificates.

## Deploy configuration secrets

You'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.

To support the above deployment scenario, you need to provide the following
credentials:

* Component TLS Certificates

* Authentication credentials for Zookeeper, Kafka, Control Center, remaining CP components

### Provide component TLS certificates

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/mtls-without-rbac
```

In this step, you will create secrets for each Confluent component TLS certificates.

```
kubectl create secret generic tls-zookeeper \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/zookeeper-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/zookeeper-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-kafka \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-controlcenter \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/controlcenter-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/controlcenter-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-schemaregistry \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/schemaregistry-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/schemaregistry-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-connect \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/connect-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/connect-server-key.pem \
  --namespace confluent
  
kubectl create secret generic tls-kafkarestproxy \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafkarestproxy-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafkarestproxy-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-ksqldb \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/ksqldb-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/ksqldb-server-key.pem \
  --namespace confluent
```

## Deploy Confluent Platform

Deploy Confluent Platform:

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform-mtls.yaml --namespace confluent
```

Check that all Confluent Platform resources are deployed:

```
kubectl get pods --namespace confluent
```

## Validate

### Validate in Control Center

Use Control Center to monitor the Confluent Platform, and see the created topic
and data. You can visit the external URL you set up for Control Center, or visit the URL
through a local port forwarding like below:

Set up port forwarding to Control Center web UI from local machine:

```
kubectl port-forward controlcenter-0 9021:9021 --namespace confluent
```

Browse to Control Center: 
```
https://localhost:9021
```

## Tear down

```
kubectl delete -f $TUTORIAL_HOME/confluent-platform-mtls.yaml --namespace confluent

kubectl delete secret tls-zookeeper tls-kafka tls-connect tls-schemaregistry tls-kafkarestproxy tls-ksqldb tls-controlcenter --namespace confluent

helm delete operator --namespace confluent
```

## Appendix: Troubleshooting

### Gather data to troubleshoot

```
# Check for any error messages in events
kubectl get events --namespace confluent

# Check for any pod failures
kubectl get pods --namespace confluent

# For pod failures, check logs
kubectl logs <pod-name> --namespace confluent
```

