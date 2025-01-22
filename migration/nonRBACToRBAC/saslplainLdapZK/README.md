# SASL PLAIN to RBAC with LDAP migration for Zookeeper cluster

In this workflow scenario, you'll set up a SASL PLAIN ZK Cluster and then migrate it to RBAC with LDAP user store.
Post migration to RBAC, Kafka listeners have sasl plain, MDS has LDAP for authorization 

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/migration/nonRBACToRBAC/saslplainLdapZK
```

## Deploy Confluent for Kubernetes

* Set up the Helm Chart:
```
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
```

* Install Confluent For Kubernetes using Helm:
```
helm upgrade --install operator confluentinc/confluent-for-kubernetes -n confluent
```

* Check that the Confluent for Kubernetes pod comes up and is running:
```
kubectl get pods -n confluent
```

## Deploy OpenLDAP

This repo includes a Helm chart for [OpenLdap](https://github.com/osixia/docker-openldap). The chart ``values.yaml`` includes the set of principal definitions that Confluent Platform needs for RBAC.

* Deploy OpenLdap
```
helm upgrade --install -f $TUTORIAL_HOME/../../../assets/openldap/ldaps-rbac.yaml test-ldap $TUTORIAL_HOME/../../../assets/openldap --namespace confluent
```

* Validate that OpenLDAP is running:
```
kubectl get pods -n confluent
```

* Log in to the LDAP pod:
```
kubectl -n confluent exec -it ldap-0 -- bash
``` 

* Run the LDAP search command:

```
ldapsearch -LLL -x -H ldap://ldap.confluent.svc.cluster.local:389 -b 'dc=test,dc=com' -D "cn=mds,dc=test,dc=com" -w 'Developer!'
```

* Exit out of the LDAP pod:
```
exit 
```

## Deploy configuration secrets

You'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.

To support the above deployment scenario, you need to provide the following
credentials:

* Component TLS Certificates

* Authentication credentials for Zookeeper, Kafka, Control Center, remaining CP components, if any.

* RBAC principal credentials

You can either provide your own certificates, or generate test certificates. Follow instructions
in the below `Appendix: Create your own certificates` section to see how to generate certificates
and set the appropriate SANs.


## Provide component TLS certificates

```
kubectl create secret generic tls-group1 \
--from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/generated/server.pem \
--from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/generated/cacerts.pem \
--from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/generated/server-key.pem \
-n confluent
```


## Provide authentication credentials

* Create a Kubernetes secret object for Zookeeper, Kafka.

This secret object contains file based properties. These files are in the
format that each respective Confluent component requires for authentication
credentials.

```
kubectl create secret generic credential \
--from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
--from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
--from-file=ldap.txt=$TUTORIAL_HOME/ldap.txt \
--from-file=digest-users.json=$TUTORIAL_HOME/creds-zookeeper-sasl-digest-users.json \
--from-file=digest.txt=$TUTORIAL_HOME/creds-kafka-zookeeper-credentials.txt \
-n confluent
```

## Provide kafka client principal credentials
```
kubectl create secret generic c3-kafka-client \
--from-file=plain.txt=$TUTORIAL_HOME/c3-client.txt \
-n confluent
```
```
kubectl create secret generic krp-kafka-client \
--from-file=plain.txt=$TUTORIAL_HOME/krp-client.txt \
-n confluent
```
```
kubectl create secret generic connect-kafka-client \
--from-file=plain.txt=$TUTORIAL_HOME/connect-client.txt \
-n confluent
```
```
kubectl create secret generic sr-kafka-client \
--from-file=plain.txt=$TUTORIAL_HOME/sr-client.txt \
-n confluent
```
```
kubectl create secret generic ksql-kafka-client \
--from-file=plain.txt=$TUTORIAL_HOME/ksql-client.txt \
-n confluent
```


## Provide RBAC principal credentials

* Create a Kubernetes secret object for MDS:

```
kubectl create secret generic mds-token \
--from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../../assets/certs/mds-publickey.txt \
--from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../../assets/certs/mds-tokenkeypair.txt \
-n confluent
```
* Create Kafka RBAC credential
```
kubectl create secret generic mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
-n confluent
``` 
* Create RBAC client credentials for other components
```
kubectl create secret generic c3-mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/c3-client.txt \
-n confluent

kubectl create secret generic connect-mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/connect-client.txt \
-n confluent

kubectl create secret generic sr-mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/sr-client.txt \
-n confluent

kubectl create secret generic krp-mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/krp-client.txt \
-n confluent

kubectl create secret generic ksql-mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/ksql-client.txt \
-n confluent
```

* Create Kafka REST credential
```
kubectl create secret generic rest-credential \
--from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
--from-file=basic.txt=$TUTORIAL_HOME/bearer.txt \
-n confluent
```

## Deploy Confluent Platform

* Deploy Confluent Platform without RBAC
```
kubectl apply -f $TUTORIAL_HOME/confluent-platform-plain.yaml
```

* Check that all Confluent Platform resources are deployed:

```
kubectl get pods -n confluent
```

## Enable authorization in Kafka

* This restarts the kafka pods in rolling manner

```
kubectl apply -f $TUTORIAL_HOME/kafka-acl.yaml
```

## Create the ACLs for each component

Due to the "allow.everyone.if.no.acl.found=true" set in the previous step, all the applications can access resources right now.

Add ACLs for the principals of all cp components and external clients

Read up on the ACL format and concepts here: https://docs.confluent.io/platform/current/kafka/authorization.html#acl-format

In this step, you'll create the required ACLs to start each Confluent component.

### Create ACLs using tooling on Kafka pod

Note: Bashing to the Broker pod is ok in order to test functionality.  
For production scenarios you'll want to run the CLI or call the Admin API from outside the Kafka cluster and either connect over the internal or external Kubernetes network.

Open an interactive shell session in the Kafka broker container:

```
kubectl -n confluent exec -it kafka-0 -- bash
```

Create the client configuration to connect to the Kafka cluster over
the internal Kubernetes network:

```
cat <<-EOF > /opt/confluentinc/kafka.properties
bootstrap.servers=kafka.confluent.svc.cluster.local:9071
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="kafka" password="kafka-secret";
ssl.keystore.location=/mnt/sslcerts/keystore.p12
ssl.keystore.password=mystorepassword
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF
```

Create ACLs for cp components:
* Note that ACLs for all external clients need to be created in similar manner

```
/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
--command-config /opt/confluentinc/kafka.properties \
--add  --allow-principal "User:sr" --allow-principal "User:connect" \
--allow-principal "User:c3" --allow-principal "User:ksql" --allow-principal "User:krp" \
--operation All --topic "*"

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
--command-config /opt/confluentinc/kafka.properties \
--add \
--allow-principal "User:sr" \
--operation Read \
--group id_schemaregistry_confluent

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
--command-config /opt/confluentinc/kafka.properties \
--add \
--allow-principal "User:connect" \
--operation Read \
--group confluent.connect

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
--command-config /opt/confluentinc/kafka.properties \
--add \
--allow-principal "User:c3" \
--operation Describe --operation Delete --operation Read \
--group ConfluentTelemetryReporterSampler \
--resource-pattern-type prefixed

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
--command-config /opt/confluentinc/kafka.properties \
--add \
--allow-principal "User:c3" \
--operation All \
--group _confluent-controlcenter \
--resource-pattern-type prefixed

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
--command-config /opt/confluentinc/kafka.properties \
--add \
--allow-principal "User:sr" \
--allow-principal "User:connect" \
--allow-principal "User:c3" \
--operation ClusterAction \
--cluster kafka-cluster

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
--command-config /opt/confluentinc/kafka.properties \
--add \
--allow-principal "User:connect" \
--allow-principal "User:c3" \
--operation Create \
--cluster kafka-cluster

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
--command-config /opt/confluentinc/kafka.properties \
--add \
--allow-principal "User:ksql" \
--allow-principal "User:c3" \
--operation Describe \
--cluster kafka-cluster

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
--command-config /opt/confluentinc/kafka.properties \
--add \
--allow-principal "User:c3" \
--operation AlterConfigs  --operation DescribeConfigs \
--cluster kafka-cluster

```

## Enable RBAC in Kafka and Create KafkaRestClass

* This restarts the kafka pods in rolling manner

```
kubectl apply -f $TUTORIAL_HOME/kafka-ldap-rbac.yaml
```

## Enable RBAC in Other CP components

* This restarts all cp components in rolling manner

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform-rbac.yaml
```

## Create RBAC Rolebindings for Control Center user

```
kubectl apply -f $TUTORIAL_HOME/c3-rolebinding.yaml
```

## Validate

### Validate in Control Center

Use Control Center to monitor the Confluent Platform. You can visit the external URL you set up for Control Center, or visit the URL through a local port forwarding like below:

* Set up port forwarding to Control Center web UI from local machine:

```
kubectl port-forward controlcenter-0 9021:9021 -n confluent
```

* Browse to Control Center, use the credentials c3 as user, and c3-secret as password to login to Control Center.
```
https://localhost:9021
```

## Tear down

```
kubectl delete confluentrolebinding --all -n confluent
kubectl delete -f $TUTORIAL_HOME/confluent-platform-rbac.yaml -n confluent
kubectl delete secret rest-credential c3-mds-client connect-mds-client ksql-mds-client sr-mds-client krp-mds-client \
c3-kafka-client connect-kafka-client ksql-kafka-client sr-kafka-client krp-kafka-client mds-client -n confluent
kubectl delete secret mds-token -n confluent
kubectl delete secret credential -n confluent
kubectl delete secret tls-group1 -n confluent
helm delete test-ldap -n confluent
helm delete operator -n confluent
```
## Appendix: Create your own certificates

When testing, it's often helpful to generate your own certificates to validate the architecture and deployment. You'll want both these to be represented in the certificate SAN:

* external domain names
* internal Kubernetes domain names
* Install libraries on Mac OS

The internal Kubernetes domain name depends on the namespace you deploy to. If you deploy to confluent namespace, then the internal domain names will be:
* .kraftcontroller.confluent.svc.cluster.local
* .kafka.confluent.svc.cluster.local
* .confluent.svc.cluster.local

Create your certificates by following the steps:
* Install libraries on Mac OS
```
brew install cfssl
```
* Create Certificate Authority
```
mkdir $TUTORIAL_HOME/../../assets/certs/generated && cfssl gencert -initca $TUTORIAL_HOME/../../assets/certs/ca-csr.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/ca -
```
* Validate Certificate Authority
```
openssl x509 -in $TUTORIAL_HOME/../../assets/certs/generated/ca.pem -text -noout
```
* Create server certificates with the appropriate SANs (SANs listed in server-domain.json)
```
cfssl gencert -ca=$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
-ca-key=$TUTORIAL_HOME/../../assets/certs/generated/ca-key.pem \
-config=$TUTORIAL_HOME/../../assets/certs/ca-config.json \
-profile=server $TUTORIAL_HOME/../../assets/certs/server-domain.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/server
``` 

* Validate server certificate and SANs
```
openssl x509 -in $TUTORIAL_HOME/../../assets/certs/generated/server.pem -text -noout
```







