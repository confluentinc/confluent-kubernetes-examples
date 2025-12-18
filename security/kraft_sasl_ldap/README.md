# Security setup

In this workflow scenario, you'll set up Kraft controller and Kafka broker cluster with the following security:
- KRaft controller with SASL_PLAIN/TLS authentication
- Kafka broker cluster with following authentication for different listeners:
  - internal listener : SASL_PLAIN/TLS with LDAP 
  - external listener : SASL_PLAIN/TLS with LDAP 
  - replication listener : SASL_PLAIN/TLS 
  - controller listener: SASL_PLAIN/TLS

Note: To implement both a SASL/PLAIN listener and a SASL/PLAIN with LDAP listener in the Kafka cluster, the SASL/PLAIN listener must be configured with authentication.jaasConfigPassThrough.

Before continuing with the scenario, ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites).

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/kraft_sasl_lap
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

## Deploy OpenLDAP

This repo includes a Helm chart for [OpenLdap](https://github.com/osixia/docker-openldap). The chart ``values.yaml``
includes the set of principal definitions that are needed for this usecase. 

- Deploy OpenLDAP

```
helm upgrade --install -f $TUTORIAL_HOME/../../assets/openldap/ldaps-rbac.yaml test-ldap $TUTORIAL_HOME/../../assets/openldap --namespace confluent
```

- Validate that OpenLDAP is running:

```
kubectl get pods --namespace confluent
```

- Log in to the LDAP pod:

```
kubectl --namespace confluent exec -it ldap-0 -- bash
```

- Run the LDAP search command:

```
ldapsearch -LLL -x -H ldap://ldap.confluent.svc.cluster.local:389 -b 'dc=test,dc=com' -D "cn=mds,dc=test,dc=com" -w 'Developer!'
```

- Exit out of the LDAP pod:

```
exit 
```
     
## Deploy configuration secrets

To provide credential configurations, you'll use kubernetes secrets. With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.

To support the above deployment scenario, you need to provide the following
credentials:

* Component TLS Certificates
* Authentication credentials for KRaft and Kafka broker 
* RBAC principal credentials

You can either provide your own certificates, or generate test certificates. Follow instructions
in the below `Appendix: Create your own certificates #appendix-create-your-own-certificates`_ section to see how to generate certificates
and set the appropriate SANs.



## Provide component TLS certificates

``` 
kubectl create secret generic tls-group1 \
--from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/generated/server.pem \
--from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
--from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/generated/server-key.pem \
--namespace confluent
```

## Provide authentication credentials

- Create a Kubernetes secret object for KRaft, and Kafka 
- This secret object contains file based properties. These files are in the
format that each respective Confluent component requires for authentication
credentials.
```
kubectl create secret generic credential \
--from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
--from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
--from-file=ldap.txt=$TUTORIAL_HOME/ldap.txt \
--namespace confluent
```

## Provide RBAC principal credentials

- Create a Kubernetes secret object for MDS: 
```
kubectl create secret generic mds-token \
--from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../assets/certs/mds-publickey.txt \
--from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../assets/certs/mds-tokenkeypair.txt \
--namespace confluent
```

- Kafka RBAC credential
```
kubectl create secret generic mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
--namespace confluent
```

- Kafka REST credential
```bash
kubectl create secret generic rest-credential \
--from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
--from-file=basic.txt=$TUTORIAL_HOME/bearer.txt \
--namespace confluent
```

- SASL/PLAIN credentials for jaasConfigPassThrough
```bash
kubectl create secret generic credential-plain \
--from-file=plain-jaas.conf=$TUTORIAL_HOME/creds-kafka-sasl-users.conf \
--namespace confluent
```

## Set up Confluent Platform 
- Deploy KRaft and Kafka broker 
```bash
kubectl apply -f $TUTORIAL_HOME/kraftbroker_controller.yaml
```

- Check that all pods are deployed:
```bash
kubectl get pods --namespace confluent
```

### Produce and consume from the topics
- Login to kafka-0 pod 
```bash
kubectl -n confluent exec -it kafka-0 -- bash
``` 

- Create a conf file inside the kafka-0 pod
```bash
cat << EOF > /tmp/kafka.properties
bootstrap.servers=kafka.confluent.svc.cluster.local:9071
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=kafka password=kafka-secret;
sasl.mechanism=PLAIN
security.protocol=SASL_SSL
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword 
EOF
```

- Produce to the demotopic 
```bash
seq 5 | kafka-console-producer --topic demotopic --broker-list kafka.confluent.svc.cluster.local:9071 --producer.config /tmp/kafka.properties
```

- Consumer from the demotopic 
```bash
kafka-console-consumer --from-beginning --topic demotopic --bootstrap-server  kafka.confluent.svc.cluster.local:9071 --consumer.config /tmp/kafka.properties
1
2
3
4
5
```

## Tear down Cluster

```bash
kubectl delete -f $TUTORIAL_HOME/kraftbroker_controller.yaml
kubectl delete secret rest-credential mds-client mds-token credential credential-plain tls-group1 --namespace confluent
helm delete test-ldap --namespace confluent
helm delete operator --namespace confluent
kubectl delete namespace confluent
```
