# Enable RBAC in an existing CFK cluster

- [Enable RBAC in an existing CFK cluster](#enable-rbac-in-an-existing-cfk-cluster)
  - [Intro](#intro)
  - [Setup](#setup)
    - [K8s Setup](#k8s-setup)
    - [Create Certs](#create-certs)
    - [Provide TLS certificates](#provide-tls-certificates)
    - [Install without RBAC Authorization (and LDAP Authentication)](#install-without-rbac-authorization-and-ldap-authentication)
  - [Test](#test)
  - [Deploy with RBAC (and LDAP Authentication)](#deploy-with-rbac-and-ldap-authentication)
    - [OpenLDAP](#openldap)
    - [Authentication credentials](#authentication-credentials)
    - [RBAC and principal credentials](#rbac-and-principal-credentials)
    - [Deploy CP](#deploy-cp)
  - [Test](#test-1)
  - [Cleanup](#cleanup)

## Intro

Enable RBAC for an existing CFK cluster is not supported: 

- https://docs.confluent.io/operator/current/co-plan.html#upgrades-and-updates

This guides presents though an unsupported example of enabling RBAC (and LDAP autehntication) for an existing CFK cluster. 

## Setup

### K8s Setup

Start k8s cluster:

```shell
kind create cluster
```

Clone repo:

```shell
git clone git@github.com:confluentinc/confluent-kubernetes-examples.git
```

Setup confluent namespace:

```shell
k create namespace confluent
kubectl config set-context --current --namespace=confluent
```

Install operator:

```shell
helm repo add confluentinc https://packages.confluent.io/helm
helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace confluent
kubectl get pods --namespace confluent
```

Set tutorial directory:

```shell
export TUTORIAL_HOME=`pwd`/confluent-kubernetes-examples/security/production-secure-deploy-ldap-rbac-all
```

### Create Certs

```shell
# Install libraries on Mac OS
brew install cfssl
# Create Certificate Authority
mkdir $TUTORIAL_HOME/../../assets/certs/generated && cfssl gencert -initca $TUTORIAL_HOME/../../assets/certs/ca-csr.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/ca -
# Validate Certificate Authority
openssl x509 -in $TUTORIAL_HOME/../../assets/certs/generated/ca.pem -text -noout
# Create server certificates with the appropriate SANs (SANs listed in server-domain.json)
# Don't forget to add your SAN
cfssl gencert -ca=$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
-ca-key=$TUTORIAL_HOME/../../assets/certs/generated/ca-key.pem \
-config=$TUTORIAL_HOME/../../assets/certs/ca-config.json \
-profile=server $TUTORIAL_HOME/../../assets/certs/server-domain.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/server

# Validate server certificate and SANs
openssl x509 -in $TUTORIAL_HOME/../../assets/certs/generated/server.pem -text -noout
```

### Provide TLS certificates

```shell
kubectl create secret generic tls-group1 \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/generated/server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/generated/server-key.pem \
  --namespace confluent
```

### Install without RBAC Authorization (and LDAP Authentication)

The following would be for deploying CP without RBAC. For this we will use now the file [norbac-confluent-platform-production.yaml](./norbac-confluent-platform-production.yaml). Where we have basically commented out all the blocks in the Kafka CR related to RBAC/MDS or LDAP authentication.

Let's apply:

```shell
kubectl apply -f norbac-confluent-platform-production.yaml --namespace confluent
```

After check that all kafka brokers are ready:

```shell
kubectl get pods --namespace confluent
```

## Test

Once all kafka brokers and zk are ready:

```shell
kubectl  exec kafka-2 -it -- bash             
```

And inside the container shell:

```shell
cat <<EOF > /tmp/kafka.properties
security.protocol=SSL
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF

kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 --command-config /tmp/kafka.properties --list
```

Now let's create a topic and write something to it:

```shell
kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 --command-config /tmp/kafka.properties --topic test --create --partitions 1 --replication-factor 3
kafka-console-producer --bootstrap-server kafka.confluent.svc.cluster.local:9071 --producer.config /tmp/kafka.properties --topic test << EOF
Hello World
Hola mundo
EOF
```

If we wanted to read:

```shell
kafka-console-consumer --bootstrap-server kafka.confluent.svc.cluster.local:9071 --consumer.config /tmp/kafka.properties --topic test --from-beginning
```

Now we can exit.

## Deploy with RBAC (and LDAP Authentication)

### OpenLDAP

Install and confirm its running:

```shell
helm upgrade --install -f $TUTORIAL_HOME/../../assets/openldap/ldaps-rbac.yaml test-ldap $TUTORIAL_HOME/../../assets/openldap --namespace confluent
```

```shell
kubectl get pods --namespace confluent
```

When ldap-0 is ready, login and test search:

```shell
kubectl --namespace confluent exec -it ldap-0 -- bash
```

```shell
ldapsearch -LLL -x -H ldap://ldap.confluent.svc.cluster.local:389 -b 'dc=test,dc=com' -D "cn=mds,dc=test,dc=com" -w 'Developer!'
```

Exit.

### Authentication credentials

```shell
kubectl create secret generic credential \
  --from-file=plain-users.json=$TUTORIAL_HOME/creds/creds-kafka-sasl-users.json \
  --from-file=digest-users.json=$TUTORIAL_HOME/creds/creds-zookeeper-sasl-digest-users.json \
  --from-file=digest.txt=$TUTORIAL_HOME/creds/creds-kafka-zookeeper-credentials.txt \
  --from-file=plain.txt=$TUTORIAL_HOME/creds/creds-client-kafka-sasl-user.txt \
  --from-file=plain-interbroker.txt=$TUTORIAL_HOME/creds/creds-client-kafka-sasl-user.txt \
  --from-file=ldap.txt=$TUTORIAL_HOME/creds/ldap.txt \
  --from-file=basic.txt=$TUTORIAL_HOME/creds/creds-control-center-users.txt \
  --namespace confluent \
   --save-config --dry-run=client -oyaml | kubectl apply -f -
```

### RBAC and principal credentials

```shell
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../assets/certs/mds-publickey.txt \
  --from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../assets/certs/mds-tokenkeypair.txt \
  --namespace confluent
```

```shell
# Kafka RBAC credential
kubectl create secret generic mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/creds/bearer.txt \
  --namespace confluent
# Control Center RBAC credential
kubectl create secret generic c3-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/creds/c3-mds-client.txt \
  --namespace confluent
# Connect RBAC credential
kubectl create secret generic connect-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/creds/connect-mds-client.txt \
  --namespace confluent
# Schema Registry RBAC credential
kubectl create secret generic sr-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/creds/sr-mds-client.txt \
  --namespace confluent
# ksqlDB RBAC credential
kubectl create secret generic ksqldb-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/creds/ksqldb-mds-client.txt \
  --namespace confluent
# Kafka Rest Proxy RBAC credential
kubectl create secret generic krp-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/creds/krp-mds-client.txt \
  --namespace confluent
# Kafka REST credential
kubectl create secret generic rest-credential \
  --from-file=bearer.txt=$TUTORIAL_HOME/creds/bearer.txt \
  --from-file=basic.txt=$TUTORIAL_HOME/creds/bearer.txt \
  --namespace confluent
```

### Deploy CP

```shell
kubectl apply -f rbac-confluent-platform-production.yaml --namespace confluent
```

Check resources creation:

```shell
kubectl get pods --namespace confluent
```

In case of issues check events:

```shell
kubectl get events --namespace confluent
```

Check rolebindings created:

```shell
kubectl get confluentrolebinding --namespace confluent
```

When single broker restarted we apply next:

```shell
kubectl apply -f rbac2-confluent-platform-production.yaml --namespace confluent
```

Check all resources are ready:

```shell
kubectl get pods --namespace confluent
```

## Test

Once all kafka brokers and zk are ready:

```shell
kubectl  exec kafka-2 -it -- bash             
```

And inside the container shell:

```shell
# kafka user 
cat <<EOF > /tmp/kafka_kafka_user.properties
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=kafka password=kafka-secret;
sasl.mechanism=PLAIN
security.protocol=SASL_SSL
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF

kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 --command-config /tmp/kafka_kafka_user.properties --list

# testadmin (RBAC via the apply yaml steps before)

cat <<EOF > /tmp/kafka_testadmin_user.properties
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=testadmin password=testadmin;
sasl.mechanism=PLAIN
security.protocol=SASL_SSL
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF

kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 --command-config /tmp/kafka_testadmin_user.properties --list

# Test a user does did not get authorization yet: james

cat <<EOF > /tmp/kafka_james_user.properties
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=james password=james-secret;
sasl.mechanism=PLAIN
security.protocol=SASL_SSL
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF

kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 --command-config /tmp/kafka_james_user.properties  --list
```

Now let's consume our topic before:

```shell
kafka-console-consumer --bootstrap-server kafka.confluent.svc.cluster.local:9071 --consumer.config /tmp/kafka_kafka_user.properties --topic test --from-beginning
```

Now we can exit.

## Cleanup

```shell
kind delete cluster
rm -fr confluent-kubernetes-examples
```