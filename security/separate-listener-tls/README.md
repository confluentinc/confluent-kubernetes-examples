# Deploy Confluent Platform with separate internal and external certs on embededKafkaRest, schema-registry and ksqldb

In this workflow scenario, you'll set up a Confluent Platform cluster with
full TLS network encryption. Specifically, you will set up embededKafkaRest, schema-registry and ksqldb to use 
separate certs internal and external communication, so that you do not mix external and internal domains in the certificate SAN.

[Separate TLS certificates for internal and external communications](https://docs.confluent.io/operator/current/co-network-encryption.html#co-configure-separate-certificates) feature is supported for ksqlDB, Schema Registry, MDS, and Kafka REST services, starting in CFK 2.6.0 and Confluent Platform 7.4.0 release.

## Set the current tutorial directory

Set the tutorial directory under the directory you downloaded this Github repo:

```   
export TUTORIAL_HOME=<Github repo directory>/security/separate-listener-tls
```

## Deploy Confluent for Kubernetes

This workflow scenario assumes you are using the namespace `confluent`. You can create `confluent` namespace by running command `kubectl create namespace confluent`.



Set up the Helm Chart:

```
helm repo add confluentinc https://packages.confluent.io/helm
```

Install Confluent For Kubernetes using Helm:

```
helm upgrade --install operator confluentinc/confluent-for-kubernetes -n confluent
```
  
Check that the Confluent For Kubernetes pod comes up and is running:

```
kubectl get pods
```

## Provide a Certificate Authority

Confluent For Kubernetes provides auto-generated certificates for Confluent Platform
components to use for TLS network encryption. You'll need to generate and provide a
Certificate Authority (CA).

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

In this scenario, you'll be allowing clients to connect with KafkaRest, schemaRegistry and ksqldb through the external-to-Kubernetes network.

For that purpose, you'll provide a server certificate that secures the external domain used to access these component.

```
# If you don't have one, create a root certificate authority for the external component certs
openssl genrsa -out $TUTORIAL_HOME/externalRootCAkey.pem 2048

openssl req -x509  -new -nodes \
  -key $TUTORIAL_HOME/externalRootCAkey.pem \
  -days 3650 \
  -out $TUTORIAL_HOME/externalCacerts.pem \
  -subj "/C=US/ST=CA/L=MVT/O=TestOrg/OU=Cloud/CN=ExternalCA"

# Create Kafka server certificates
cfssl gencert -ca=$TUTORIAL_HOME/externalCacerts.pem \
-ca-key=$TUTORIAL_HOME/externalRootCAkey.pem \
-config=$TUTORIAL_HOME/../../assets/certs/ca-config.json \
-profile=server $TUTORIAL_HOME/kafka-server-domain.json | cfssljson -bare $TUTORIAL_HOME/kafka-server

# Create SchemaRegistry server certificates
cfssl gencert -ca=$TUTORIAL_HOME/externalCacerts.pem \
-ca-key=$TUTORIAL_HOME/externalRootCAkey.pem \
-config=$TUTORIAL_HOME/../../assets/certs/ca-config.json \
-profile=server $TUTORIAL_HOME/sr-server-domain.json | cfssljson -bare $TUTORIAL_HOME/sr-server

# Create Ksqldb server certificates
cfssl gencert -ca=$TUTORIAL_HOME/externalCacerts.pem \
-ca-key=$TUTORIAL_HOME/externalRootCAkey.pem \
-config=$TUTORIAL_HOME/../../assets/certs/ca-config.json \
-profile=server $TUTORIAL_HOME/ksqldb-server-domain.json | cfssljson -bare $TUTORIAL_HOME/ksqldb-server

```

Provide the certificates to respective components through a Kubernetes Secret:

```
kubectl create secret generic tls-kafka-rest \
  --from-file=fullchain.pem=$TUTORIAL_HOME/kafka-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/externalCacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/kafka-server-key.pem \
  --namespace confluent
  
kubectl create secret generic tls-sr \
  --from-file=fullchain.pem=$TUTORIAL_HOME/sr-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/externalCacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/sr-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-ksqldb \
  --from-file=fullchain.pem=$TUTORIAL_HOME/ksqldb-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/externalCacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/ksqldb-server-key.pem \
  --namespace confluent    
```

## Deploy Confluent Platform

Note that external accesses to Confluent Platform components are configured using the Load Balance services.
``` 
spec:
  listeners:
    external:
      externalAccess:
        type: loadBalancer
        loadBalancer:
          domain: my.domain    --- [1]
``` 
* [1]  Set this to the value of ``$DOMAIN``, Your Kubernetes cluster domain. You need to provide this value for this tutorial.

Deploy Confluent Platform:

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform-separate-listener.yaml
```

Check that all Confluent Platform resources are deployed:

```   
kubectl get confluent -n confluent
```


## Validate in Control Center

Use Control Center to monitor the Confluent Platform, and see the created topic
and data.

```
kubectl port-forward controlcenter-0 9021:9021 -n confluent
```

Browse to Control Center:

```   
https://localhost:9021
```

## Tear down

```
kubectl delete -f $TUTORIAL_HOME/confluent-platform-separate-listener.yaml -n confluent

kubectl delete secret tls-kafka-rest tls-sr tls-ksqldb -n confluent

kubectl delete secret ca-pair-sslcerts -n confluent

helm delete operator -n confluent
```