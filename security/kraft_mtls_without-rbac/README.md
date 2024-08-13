# Security setup

- [Set the current tutorial directory](#set-the-current-tutorial-directory)
- [Deploy Confluent for Kubernetes](#deploy-confluent-for-kubernetes)
- [Provide a Certificate Authority](#provide-a-certificate-authority)
- [Deploy Confluent Platform](#deploy-confluent-platform)
- [Validate](#validate)
- [Tear down Cluster](#tear-down-cluster)

In this workflow scenario, you'll set up KRaft brokers, controllers, and other Confluent Platform components except control center with the following security:
- Full TLS network encryption using auto-generated certs
- mTLS authentication

Before continuing with the scenario, ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites).

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/kraft_mtls
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

## Provide a Certificate Authority

Confluent For Kubernetes provides auto-generated certificates for Confluent Platform components to use for TLS network encryption. You'll need to generate and provide a Certificate Authority (CA).

Generate a CA pair to use:

```
openssl genrsa -out $TUTORIAL_HOME/ca-key.pem 2048

openssl req -new -key $TUTORIAL_HOME/ca-key.pem -x509 \
  -days 1000 \
  -out $TUTORIAL_HOME/ca.pem \
  -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA"
```

Create a Kubernetes secret for the certificate authority:

```
kubectl create secret tls ca-pair-sslcerts \
  --cert=$TUTORIAL_HOME/ca.pem \
  --key=$TUTORIAL_HOME/ca-key.pem -n confluent
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

## Tear down Cluster

```
kubectl delete -f $TUTORIAL_HOME/confluent-platform-mtls.yaml --namespace confluent

kubectl delete secret ca-pair-sslcerts -n confluent

helm delete operator --namespace confluent
```

