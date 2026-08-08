# Remove RBAC in an existing CFK cluster

Enable RBAC for an existing CFK cluster is not supported: 

- https://docs.confluent.io/operator/current/co-plan.html#upgrades-and-updates

It would be possibly better phrased: *Enable or disable Confluent RBAC on an existing cluster is unsupported.*

This guides presents though an unsupported example of removing RBAC (and LDAP autehntication) for an existing CFK cluster. It also shows the alternative option of keeping RBAC but grant anonymous super user access in the cluster.

This guide first deploy an RBAC CFK cluster as per reference:
- https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/security/production-secure-deploy-ldap-rbac-all

(Based on the security/production-secure-deploy-ldap-rbac-all in this repo.)

And after disables RBAC and LDAP authentication from the CFK cluster.

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

Set tutorial directory:

```shell
export TUTORIAL_HOME=`pwd`/confluent-kubernetes-examples/security/production-secure-deploy-ldap-rbac-all
```

Install operator:

```shell
helm repo add confluentinc https://packages.confluent.io/helm
helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace confluent
kubectl get pods --namespace confluent
```

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

### Authentication credentials

```shell
kubectl create secret generic credential \
  --from-file=plain-users.json=$TUTORIAL_HOME/creds/creds-kafka-sasl-users.json \
  --from-file=digest-users.json=$TUTORIAL_HOME/creds/creds-zookeeper-sasl-digest-users.json \
  --from-file=digest.txt=$TUTORIAL_HOME/creds/creds-kafka-zookeeper-credentials.txt \
  --from-file=plain.txt=$TUTORIAL_HOME/creds/creds-client-kafka-sasl-user.txt \
  --from-file=basic.txt=$TUTORIAL_HOME/creds/creds-control-center-users.txt \
  --from-file=plain-interbroker.txt=$TUTORIAL_HOME/creds/creds-client-kafka-sasl-user.txt \
  --from-file=ldap.txt=$TUTORIAL_HOME/creds/ldap.txt \
  --namespace confluent
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

### Configure CP

On the original $TUTORIAL_HOME/confluent-platform-production.yaml we would make some changes just to minimixe resource usage:

- We will set ZK replicas to 1 and volumes to 2Gb. 
- For Kafka brokers just reduce volumes to 2gb. 
- For the rest of CR we set replicas to 0.
- Change also the `<host>` for broker entry to localhost:

We have in fact that file with final changes as part of our repo [my-confluent-platform-production.yaml](./my-confluent-platform-production.yaml). So we will use it directly on next steps.

### Deploy CP

```shell
kubectl apply -f $TUTORIAL_HOME/../remove-rbac/my-confluent-platform-production.yaml --namespace confluent
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

Now let's create a topic and write something to it:

```shell
kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 --command-config /tmp/kafka_kafka_user.properties --topic test --create --partitions 1 --replication-factor 3
kafka-console-producer --bootstrap-server kafka.confluent.svc.cluster.local:9071 --producer.config /tmp/kafka_kafka_user.properties --topic test << EOF
Hello World
Hola mundo
EOF
```

If we wanted to read:

```shell
kafka-console-consumer --bootstrap-server kafka.confluent.svc.cluster.local:9071 --consumer.config /tmp/kafka_kafka_user.properties --topic test --from-beginning
```

Now we can exit.

We can also double check our topic on any other instance to confirm all is good:

```shell
kubectl  exec kafka-0 -it -- bash             
```

Inside the container:

```shell
cat <<EOF > /tmp/kafka_kafka_user.properties
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=kafka password=kafka-secret;
sasl.mechanism=PLAIN
security.protocol=SASL_SSL
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF
kafka-console-consumer --bootstrap-server kafka.confluent.svc.cluster.local:9071 --consumer.config /tmp/kafka_kafka_user.properties --topic test --from-beginning
```

And the same once inside the other broker:

```shell
kubectl  exec kafka-1 -it -- bash             
```

## Remove RBAC Authorization (and LDAP Authentication)

The following would be for removing RBAC. In case you want to try enable super user anonymous go to next section. Here we will use now the file [new-my-confluent-platform-production.yaml](./new-my-confluent-platform-production.yaml). Where we have basically commented out all the blocks in the Kafka CR related to RBAC/MDS or LDAP authentication:

```yaml
---
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
  namespace: confluent
spec:
  replicas: 3
  image:
    application: confluentinc/cp-server:7.6.0
    init: confluentinc/confluent-init-container:2.8.0
  dataVolumeCapacity: 2Gi
  tls:
    secretRef: tls-group1
  listeners:
    internal:
      # authentication:
      #   type: ldap
      #   jaasConfig:
      #     secretRef: credential
      tls:
        enabled: true
    external:
      externalAccess:
        type: nodePort
        nodePort:
          host: localhost
          nodePortOffset: 30000
      # authentication:
      #   type: ldap
      #   jaasConfig:
      #     secretRef: credential
      tls:
        enabled: true
  # authorization:
  #   type: rbac
  #   superUsers:
  #   - User:kafka
  services:
    kafkaRest:
      externalAccess:
        type: nodePort
        nodePort:
          host: localhost
          nodePortOffset: 30100
    # mds:
    #   tls:
    #     enabled: true
    #   tokenKeyPair:
    #     secretRef: mds-token
    #   externalAccess:
    #     type: nodePort
    #     nodePort:
    #       host: localhost
    #       nodePortOffset: 30200
    #   provider:
    #     type: ldap
    #     ldap:
    #       address: ldap://ldap.confluent.svc.cluster.local:389
    #       authentication:
    #         type: simple
    #         simple:
    #           secretRef: credential
    #       configurations:
    #         groupNameAttribute: cn
    #         groupObjectClass: group
    #         groupMemberAttribute: member
    #         groupMemberAttributePattern: CN=(.*),DC=test,DC=com
    #         groupSearchBase: dc=test,dc=com
    #         userNameAttribute: cn
    #         userMemberOfAttributePattern: CN=(.*),DC=test,DC=com
    #         userObjectClass: organizationalRole
    #         userSearchBase: dc=test,dc=com
  dependencies:
    # kafkaRest:
    #   authentication:
    #     type: bearer
    #     bearer:
    #       secretRef: mds-client
    zookeeper:
      endpoint: zookeeper.confluent.svc.cluster.local:2182
      authentication:
        type: digest
        jaasConfig:
          secretRef: credential
      tls:
        enabled: true
```

Let's apply and recreate our pods:

```shell
kubectl apply -f $TUTORIAL_HOME/../remove-rbac/new-my-confluent-platform-production.yaml --namespace confluent
k delete pod kafka-0 kafka-1 kafka-2 --namespace confluent
```

After check that all kafka brokers are ready:

```shell
kubectl get pods --namespace confluent
```

### Test

Now let's confirm everything is working:

```shell
kubectl  exec kafka-2 -it -- bash             
```

And inside the container we try to list and after consume our topic created before without any user details:

```shell
cat <<EOF > /tmp/kafka_no_user.properties
security.protocol=SSL
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF
kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 --command-config /tmp/kafka_no_user.properties --list           
```

```shell
kafka-console-consumer --bootstrap-server kafka.confluent.svc.cluster.local:9071 --consumer.config /tmp/kafka_no_user.properties --topic test --from-beginning
```

## Set anonymous super user

In this case we will add `User:ANONYMOUS`to super.users. And set at least one listener for not using ldap to authenticate. We have done that in [anonymous-confluent-platform-production.yaml](./anonymous-confluent-platform-production.yaml):

```shell
kubectl apply -f $TUTORIAL_HOME/../remove-rbac/anonymous-confluent-platform-production.yaml --namespace confluent
k delete pod kafka-0 kafka-1 kafka-2 --namespace confluent
```

After check that all kafka brokers are ready:

```shell
kubectl get pods --namespace confluent
```

Now we confirm as before:

```shell
kubectl  exec kafka-2 -it -- bash             
```

```shell
cat <<EOF > /tmp/kafka_anonymous_user.properties
security.protocol=SSL
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF
kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 --command-config /tmp/kafka_anonymous_user.properties --list           
```

```shell
kafka-console-consumer --bootstrap-server kafka.confluent.svc.cluster.local:9071 --consumer.config /tmp/kafka_anonymous_user.properties --topic test --from-beginning
```


## Cleanup

```shell
kind delete cluster
rm -fr confluent-kubernetes-examples
```