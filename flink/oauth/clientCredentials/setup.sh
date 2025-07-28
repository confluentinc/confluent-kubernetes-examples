#!/bin/bash

# Exit on error
set -e

# Set up environment variables
export TUTORIAL_HOME=$(pwd)
export CFK_EXAMPLES_REPO_HOME="https://raw.githubusercontent.com/confluentinc/confluent-kubernetes-examples/master"

echo "Creating operator namespace..."
kubectl create ns operator

echo "Deploying Keycloak..."
kubectl apply -f $TUTORIAL_HOME/dependencies/keycloak/keycloak.yaml
echo "Waiting for Keycloak deployment to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/keycloak -n operator

echo "Generating CA certificate..."
openssl genrsa -out $TUTORIAL_HOME/certs/ca/ca-key.pem 2048
openssl req -new -key $TUTORIAL_HOME/certs/ca/ca-key.pem -x509 \
  -days 1000 \
  -out $TUTORIAL_HOME/certs/ca/ca.pem \
  -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA"

echo "Creating CA certificate secret..."
kubectl -n operator create secret tls ca-pair-sslcerts \
  --cert=$TUTORIAL_HOME/certs/ca/ca.pem \
  --key=$TUTORIAL_HOME/certs/ca/ca-key.pem

echo "Creating credential secrets..."
kubectl create secret generic credential \
  --from-file=plain-users.json=$TUTORIAL_HOME/creds/cp/creds-kafka-sasl-users.json \
  --from-file=digest-users.json=$TUTORIAL_HOME/creds/cp/creds-zookeeper-sasl-digest-users.json \
  --from-file=digest.txt=$TUTORIAL_HOME/creds/cp/creds-kafka-zookeeper-credentials.txt \
  --from-file=plain.txt=$TUTORIAL_HOME/creds/cp/creds-client-kafka-sasl-user.txt \
  --from-file=basic.txt=$TUTORIAL_HOME/creds/cp/creds-control-center-users.txt \
  --namespace operator

echo "Creating MDS token secret..."
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem=<(curl -sSL $CFK_EXAMPLES_REPO_HOME/assets/certs/mds-publickey.txt) \
  --from-file=mdsTokenKeyPair.pem=<(curl -sSL $CFK_EXAMPLES_REPO_HOME/assets/certs/mds-tokenkeypair.txt) \
  --namespace operator

echo "Creating OAuth JAAS secrets..."
kubectl create -n operator secret generic oauth-jaas --from-file=oauth.txt=$TUTORIAL_HOME/creds/cp/oauth_jass.txt
kubectl create -n operator secret generic oauth-jaas-sso --from-file=oidcClientSecret.txt=$TUTORIAL_HOME/creds/cp/oauth_jass.txt

echo "Creating C3 Next Gen credentials..."
kubectl -n operator create secret generic prometheus-credentials --from-file=basic.txt=./creds/c3/prometheus-credentials-secret.txt
kubectl -n operator create secret generic alertmanager-credentials --from-file=basic.txt=./creds/c3/alertmanager-credentials-secret.txt
kubectl -n operator create secret generic prometheus-client-creds --from-file=basic.txt=./creds/c3/prometheus-client-credentials-secret.txt
kubectl -n operator create secret generic alertmanager-client-creds --from-file=basic.txt=./creds/c3/alertmanager-client-credentials-secret.txt

echo "Generating C3 Next Gen certificates..."
cfssl gencert -ca=$TUTORIAL_HOME/certs/ca/ca.pem \
  -ca-key=$TUTORIAL_HOME/certs/ca/ca-key.pem \
  -config=$TUTORIAL_HOME/certs/server_configs/ca-config.json \
  -profile=server $TUTORIAL_HOME/certs/server_configs/c3-ng-server-config.json | \
  cfssljson -bare $TUTORIAL_HOME/certs/generated/controlcenter-server

echo "Creating prometheus and alertmanager TLS secrets..."
kubectl create secret generic prometheus-tls -n operator \
  --from-file=fullchain.pem=./certs/generated/controlcenter-server.pem \
  --from-file=privkey.pem=./certs/generated/controlcenter-server-key.pem \
  --from-file=cacerts.pem=./certs/ca/ca.pem
kubectl create secret generic alertmanager-tls -n operator \
  --from-file=fullchain.pem=./certs/generated/controlcenter-server.pem \
  --from-file=privkey.pem=./certs/generated/controlcenter-server-key.pem \
  --from-file=cacerts.pem=./certs/ca/ca.pem

echo "Creating client side certificates..."
kubectl create secret generic prometheus-client-tls -n operator \
  --from-file=fullchain.pem=./certs/generated/controlcenter-server.pem \
  --from-file=privkey.pem=./certs/generated/controlcenter-server-key.pem \
  --from-file=cacerts.pem=./certs/ca/ca.pem
kubectl create secret generic alertmanager-client-tls -n operator \
  --from-file=fullchain.pem=./certs/generated/controlcenter-server.pem \
  --from-file=privkey.pem=./certs/generated/controlcenter-server-key.pem \
  --from-file=cacerts.pem=./certs/ca/ca.pem

echo "Generating CMF certificates..."
cfssl gencert -ca=$TUTORIAL_HOME/certs/ca/ca.pem \
  -ca-key=$TUTORIAL_HOME/certs/ca/ca-key.pem \
  -config=$TUTORIAL_HOME/certs/server_configs/ca-config.json \
  -profile=server $TUTORIAL_HOME/certs/server_configs/cmf-server-config.json | \
  cfssljson -bare $TUTORIAL_HOME/certs/generated/cmf-server

echo "Creating JKS files..."
curl -sSL $CFK_EXAMPLES_REPO_HOME/scripts/create-truststore.sh | bash -s -- $TUTORIAL_HOME/certs/ca/ca.pem allpassword
curl -sSL $CFK_EXAMPLES_REPO_HOME/scripts/create-keystore.sh | bash -s -- $TUTORIAL_HOME/certs/generated/cmf-server.pem $TUTORIAL_HOME/certs/generated/cmf-server-key.pem allpassword
rm -rf $TUTORIAL_HOME/certs/jks
mv jks $TUTORIAL_HOME/certs

#echo "Deploying Confluent Operator"
#OPERATOR_VERSION=v0.1193.34
#helm install confluent-operator confluentinc/confluent-for-kubernetes --namespace operator --version OPERATOR_VERSION

echo "Deploying Confluent Platform components..."
kubectl apply -f $TUTORIAL_HOME/manifests/cp_components.yaml
sleep 30

echo "Waiting for Confluent Platform components to be ready..."
kubectl wait --for=condition=ready --timeout=-1s pod -l app=kraftcontroller -n operator
sleep 30
kubectl wait --for=condition=ready --timeout=-1s pod -l app=kafka -n operator
sleep 30
kubectl wait --for=condition=ready --timeout=-1s pod -l app=controlcenter-ng -n operator


echo "Creating CMF certificate secrets..."
kubectl create secret generic cmf-truststore -n operator --from-file=truststore.jks=$TUTORIAL_HOME/certs/jks/truststore.jks
kubectl create secret generic cmf-keystore -n operator --from-file=keystore.jks=$TUTORIAL_HOME/certs/jks/keystore.jks

echo "Deploying CMF via Helm..."
helm upgrade --install -f $TUTORIAL_HOME/dependencies/cmf/values.yaml cmf confluentinc/confluent-manager-for-apache-flink --namespace operator
echo "Waiting for CMF deployment to be ready..."
kubectl wait --for=condition=available --timeout=-1s deployment/confluent-manager-for-apache-flink -n operator

echo "Creating CMF Rest Class TLS secret..."
kubectl create secret generic cmf-day2-tls -n operator \
  --from-file=fullchain.pem=$TUTORIAL_HOME/certs/generated/cmf-server.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/certs/generated/cmf-server-key.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/certs/ca/ca.pem

echo "Deploying CMF Rest Class..."
kubectl apply -f $TUTORIAL_HOME/manifests/cmfrestclass.yaml

echo "Deploying Flink Environment..."
kubectl apply -f $TUTORIAL_HOME/manifests/flinkenvironment.yaml

echo "Deploying Flink Application..."
kubectl apply -f $TUTORIAL_HOME/manifests/flinkapplication.yaml

echo "Please Add local DNS entry... command below:"
echo "echo 127.0.0.1 confluent-manager-for-apache-flink.operator.svc.cluster.local | sudo tee -a /etc/hosts"
echo "echo 127.0.0.1 keycloak | sudo tee -a /etc/hosts"

echo "Setup completed successfully!"
echo ""
echo "Next steps:"
echo "1. Port forward Keycloak: while true; do kubectl port-forward service/keycloak 8080:8080 -n operator; done"
echo "2. Configure Keycloak clients and users at http://localhost:8080/admin/master/console/#/sso_test/clients"
echo "3. Port forward CMF service: while true; do kubectl port-forward service/cmf-service 8091:80 -n operator; done"
echo "4. Test API access using the provided curl commands in the README"
