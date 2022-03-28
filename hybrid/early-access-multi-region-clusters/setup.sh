#!/bin/bash
# Make sure to complete Kubernetes networking setup before running this script.

# shellcheck disable=SC2128
TUTORIAL_HOME=$(dirname "$BASH_SOURCE")

# Create namespace
kubectl create ns central --context mrc-central
kubectl create ns east --context mrc-east
kubectl create ns west --context mrc-west

# Set up the Helm Chart
helm repo add confluentinc https://packages.confluent.io/helm

# Install Confluent For Kubernetes
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n central --kube-context mrc-central
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n east --kube-context mrc-east
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n west --kube-context mrc-west

# Setup the Helm chart
helm repo add bitnami https://charts.bitnami.com/bitnami

# Install External DNS
helm install external-dns -f "$TUTORIAL_HOME"/external-dns-values.yaml --set namespace=central,txtOwnerId=mrc-central bitnami/external-dns -n central --kube-context mrc-central
helm install external-dns -f "$TUTORIAL_HOME"/external-dns-values.yaml --set namespace=east,txtOwnerId=mrc-east bitnami/external-dns -n east --kube-context mrc-east
helm install external-dns -f "$TUTORIAL_HOME"/external-dns-values.yaml --set namespace=west,txtOwnerId=mrc-west bitnami/external-dns -n west --kube-context mrc-west

# Deploy OpenLdap
helm upgrade --install -f "$TUTORIAL_HOME"/../../assets/openldap/ldaps-rbac.yaml open-ldap "$TUTORIAL_HOME"/../../assets/openldap -n central --kube-context mrc-central

# Configure service account
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rack-awareness/service-account-rolebinding-central.yaml --context mrc-central
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rack-awareness/service-account-rolebinding-east.yaml --context mrc-east
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rack-awareness/service-account-rolebinding-west.yaml --context mrc-west

# Create CFK CA TLS certificates for auto generating certs
kubectl create secret tls ca-pair-sslcerts \
  --cert="$TUTORIAL_HOME"/../../assets/certs/generated/ca.pem \
  --key="$TUTORIAL_HOME"/../../assets/certs/generated/ca-key.pem \
  -n central --context mrc-central
kubectl create secret tls ca-pair-sslcerts \
  --cert="$TUTORIAL_HOME"/../../assets/certs/generated/ca.pem \
  --key="$TUTORIAL_HOME"/../../assets/certs/generated/ca-key.pem \
  -n east --context mrc-east
kubectl create secret tls ca-pair-sslcerts \
  --cert="$TUTORIAL_HOME"/../../assets/certs/generated/ca.pem \
  --key="$TUTORIAL_HOME"/../../assets/certs/generated/ca-key.pem \
  -n west --context mrc-west

# Configure credentials for Authentication and Authorization
kubectl create secret generic credential \
  --from-file=digest-users.json="$TUTORIAL_HOME"/confluent-platform/credentials/zk-users-server.json \
  --from-file=digest.txt="$TUTORIAL_HOME"/confluent-platform/credentials/zk-users-client.txt \
  --from-file=plain-users.json="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-users-server.json \
  --from-file=plain.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-users-client.txt \
  --from-file=ldap.txt="$TUTORIAL_HOME"/confluent-platform/credentials/ldap-client.txt \
  -n central --context mrc-central
kubectl create secret generic credential \
  --from-file=digest-users.json="$TUTORIAL_HOME"/confluent-platform/credentials/zk-users-server.json \
  --from-file=digest.txt="$TUTORIAL_HOME"/confluent-platform/credentials/zk-users-client.txt \
  --from-file=plain-users.json="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-users-server.json \
  --from-file=plain.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-users-client.txt \
  --from-file=ldap.txt="$TUTORIAL_HOME"/confluent-platform/credentials/ldap-client.txt \
  -n east --context mrc-east
kubectl create secret generic credential \
  --from-file=digest-users.json="$TUTORIAL_HOME"/confluent-platform/credentials/zk-users-server.json \
  --from-file=digest.txt="$TUTORIAL_HOME"/confluent-platform/credentials/zk-users-client.txt \
  --from-file=plain-users.json="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-users-server.json \
  --from-file=plain.txt="$TUTORIAL_HOME"/confluent-platform/credentials/kafka-users-client.txt \
  --from-file=ldap.txt="$TUTORIAL_HOME"/confluent-platform/credentials/ldap-client.txt \
  -n west --context mrc-west

# Create Kubernetes secret object for MDS:
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem="$TUTORIAL_HOME"/../../assets/certs/mds-publickey.txt \
  --from-file=mdsTokenKeyPair.pem="$TUTORIAL_HOME"/../../assets/certs/mds-tokenkeypair.txt \
  -n central --context mrc-central
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem="$TUTORIAL_HOME"/../../assets/certs/mds-publickey.txt \
  --from-file=mdsTokenKeyPair.pem="$TUTORIAL_HOME"/../../assets/certs/mds-tokenkeypair.txt \
  -n east --context mrc-east
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem="$TUTORIAL_HOME"/../../assets/certs/mds-publickey.txt \
  --from-file=mdsTokenKeyPair.pem="$TUTORIAL_HOME"/../../assets/certs/mds-tokenkeypair.txt \
  -n west --context mrc-west

# Create Kafka RBAC credential
kubectl create secret generic mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/mds-client.txt \
  -n central --context mrc-central
kubectl create secret generic mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/mds-client.txt \
  -n east --context mrc-east
kubectl create secret generic mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/mds-client.txt \
  -n west --context mrc-west

# Create Schema Registry RBAC credential
kubectl create secret generic sr-mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/sr-mds-client.txt \
  -n central --context mrc-central
kubectl create secret generic sr-mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/sr-mds-client.txt \
  -n east --context mrc-east
kubectl create secret generic sr-mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/sr-mds-client.txt \
  -n west --context mrc-west

# Create Control Center RBAC credential
kubectl create secret generic c3-mds-client \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/c3-mds-client.txt \
  -n central --context mrc-central

# Create Kafka REST credential
kubectl create secret generic kafka-rest-credential \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/mds-client.txt \
  -n central --context mrc-central
kubectl create secret generic kafka-rest-credential \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/mds-client.txt \
  -n east --context mrc-east
kubectl create secret generic kafka-rest-credential \
  --from-file=bearer.txt="$TUTORIAL_HOME"/confluent-platform/credentials/mds-client.txt \
  -n west --context mrc-west

# Create role bindings for Schema Registry
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/mrc-rolebindings.yaml -n central --context mrc-central
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/mrc-rolebindings.yaml -n east --context mrc-east
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/mrc-rolebindings.yaml -n west --context mrc-west

# Create role bindings for Control Center
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/c3-rolebindings.yaml --context mrc-central

# Deploy Zookeeper cluster
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/zookeeper/zookeeper-central.yaml --context mrc-central
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/zookeeper/zookeeper-east.yaml --context mrc-east
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/zookeeper/zookeeper-west.yaml --context mrc-west

# Wait until Zookeeper is up
echo "Waiting for Zookeeper to be Ready..."
kubectl wait pod -l app=zookeeper --for=condition=Ready --timeout=-1s -n central --context mrc-central
kubectl wait pod -l app=zookeeper --for=condition=Ready --timeout=-1s -n east --context mrc-east
kubectl wait pod -l app=zookeeper --for=condition=Ready --timeout=-1s -n west --context mrc-west

# Deploy Kafka cluster
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kafka/kafka-central.yaml --context mrc-central
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kafka/kafka-east.yaml --context mrc-east
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kafka/kafka-west.yaml --context mrc-west

# Wait until Kafka is up
echo "Waiting for Kafka to be Ready..."
kubectl wait pod -l app=kafka --for=condition=Ready --timeout=-1s -n central --context mrc-central
kubectl wait pod -l app=kafka --for=condition=Ready --timeout=-1s -n east --context mrc-east
kubectl wait pod -l app=kafka --for=condition=Ready --timeout=-1s -n west --context mrc-west

# Create Kafka REST class
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kafkarestclass.yaml -n central --context mrc-central
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kafkarestclass.yaml -n east --context mrc-east
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/kafkarestclass.yaml -n west --context mrc-west

# Deploy Schema Registry cluster
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/schemaregistry/schemaregistry-central.yaml --context mrc-central
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/schemaregistry/schemaregistry-east.yaml --context mrc-east
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/schemaregistry/schemaregistry-west.yaml --context mrc-west

# Wait until Schema Registry is up
echo "Waiting for Schema Registry to be Ready..."
kubectl wait pod -l app=schemaregistry --for=condition=Ready --timeout=-1s -n central --context mrc-central
kubectl wait pod -l app=schemaregistry --for=condition=Ready --timeout=-1s -n east --context mrc-east
kubectl wait pod -l app=schemaregistry --for=condition=Ready --timeout=-1s -n west --context mrc-west

# Deploy Control Center
kubectl apply -f "$TUTORIAL_HOME"/confluent-platform/controlcenter.yaml --context mrc-central

# Wait until Control Center is up
echo "Waiting for Control Center to be Ready..."
sleep 1
kubectl wait pod -l app=controlcenter --for=condition=Ready --timeout=-1s -n central --context mrc-central