#!/bin/bash
# Make sure to complete Kubernetes networking setup before running this script.

# shellcheck disable=SC2128
TUTORIAL_HOME=$(dirname "$BASH_SOURCE")

# Destroy Control Center
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/controlcenter.yaml --context mrc-central

# Destroy Schema Registry
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/schemaregistry/schemaregistry-west.yaml --context mrc-west
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/schemaregistry/schemaregistry-east.yaml --context mrc-east
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/schemaregistry/schemaregistry-central.yaml --context mrc-central

# Delete Control Center role bindings
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/c3-rolebindings.yaml --context mrc-central

# Delete Schema Registry role bindings
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/mrc-rolebindings.yaml -n west --context mrc-west
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/mrc-rolebindings.yaml -n east --context mrc-east
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rolebindings/mrc-rolebindings.yaml -n central --context mrc-central

# Wait for internal role bindings to be deleted
echo "Waiting for role bindings to be deleted..."
kubectl wait cfrb --all --for=delete --timeout=-1s -n west --context mrc-west
kubectl wait cfrb --all --for=delete --timeout=-1s -n east --context mrc-east
kubectl wait cfrb --all --for=delete --timeout=-1s -n central --context mrc-central

# Delete Kafka REST class
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kafkarestclass.yaml -n west --context mrc-west
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kafkarestclass.yaml -n east --context mrc-east
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kafkarestclass.yaml -n central --context mrc-central

# Destroy Kafka
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kafka/kafka-west.yaml --context mrc-west
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kafka/kafka-east.yaml --context mrc-east
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/kafka/kafka-central.yaml --context mrc-central

# Wait for Kafka to be destroyed
echo "Waiting for Kafka to be deleted..."
kubectl wait pod -l app=kafka --for=delete --timeout=-1s -n west --context mrc-west
kubectl wait pod -l app=kafka --for=delete --timeout=-1s -n east --context mrc-east
kubectl wait pod -l app=kafka --for=delete --timeout=-1s -n central --context mrc-central

# Destroy Zookeeper
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/zookeeper/zookeeper-west.yaml --context mrc-west
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/zookeeper/zookeeper-east.yaml --context mrc-east
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/zookeeper/zookeeper-central.yaml --context mrc-central

# Delete Kafka REST credential
kubectl delete secret kafka-rest-credential -n west --context mrc-west
kubectl delete secret kafka-rest-credential -n east --context mrc-east
kubectl delete secret kafka-rest-credential -n central --context mrc-central

# Delete Control Center RBAC credential
kubectl delete secret c3-mds-client -n central --context mrc-central

# Delete Schema Registry RBAC credential
kubectl delete secret sr-mds-client -n west --context mrc-west
kubectl delete secret sr-mds-client -n east --context mrc-east
kubectl delete secret sr-mds-client -n central --context mrc-central

# Delete Kafka RBAC credential
kubectl delete secret mds-client -n west --context mrc-west
kubectl delete secret mds-client -n east --context mrc-east
kubectl delete secret mds-client -n central --context mrc-central

# Delete Kubernetes secret object for MDS:
kubectl delete secret mds-token -n west --context mrc-west
kubectl delete secret mds-token -n east --context mrc-east
kubectl delete secret mds-token -n central --context mrc-central

# Delete credentials for Authentication and Authorization
kubectl delete secret credential -n west --context mrc-west
kubectl delete secret credential -n east --context mrc-east
kubectl delete secret credential -n central --context mrc-central

# Delete CFK CA TLS certificates for auto generating certs
kubectl delete secret ca-pair-sslcerts -n west --context mrc-west
kubectl delete secret ca-pair-sslcerts -n east --context mrc-east
kubectl delete secret ca-pair-sslcerts -n central --context mrc-central

# Delete service account
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rack-awareness/service-account-rolebinding-west.yaml --context mrc-west
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rack-awareness/service-account-rolebinding-east.yaml --context mrc-east
kubectl delete -f "$TUTORIAL_HOME"/confluent-platform/rack-awareness/service-account-rolebinding-central.yaml --context mrc-central

# Uninstall Open LDAP
helm uninstall open-ldap -n central --kube-context mrc-central

# Uninstall external-dns
# Allow sufficient time for external-dns to clean up DNS records
echo "Sleeping for 30s to allow external-dns to clean up DNS entries"
sleep 30
helm uninstall external-dns -n west --kube-context mrc-west
helm uninstall external-dns -n east --kube-context mrc-east
helm uninstall external-dns -n central --kube-context mrc-central

# Uninstall CFK
helm uninstall cfk-operator -n west --kube-context mrc-west
helm uninstall cfk-operator -n east --kube-context mrc-east
helm uninstall cfk-operator -n central --kube-context mrc-central

# Delete namespace
kubectl delete ns west --context mrc-west
kubectl delete ns east --context mrc-east
kubectl delete ns central --context mrc-central