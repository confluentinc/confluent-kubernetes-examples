# mTLS to RBAC with mTLS migration for Kraft cluster

In this workflow scenario, you'll set up a Kraft Cluster with mTLS and then migrate it to RBAC with mTLS.
Post migration to RBAC, Kafka listeners have mTLS, MDS has mTLS for authorization and file based user store for C3 login.

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/migration/nonRBACToRBAC/mtlsOnly
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

## Create TLS certificates

In this scenario, you'll configure authentication using the mTLS mechanism. With mTLS, Confluent components and clients use TLS certificates for authentication. The certificate has a CN that identifies the principal name.

Each Confluent component service should have its own TLS certificate. In this scenario, you'll
generate a server certificate for each Confluent component service. Follow [these instructions](../../../assets/certs/component-certs/README.md) to generate these certificates.


## Deploy configuration secrets
You'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.

To support the above deployment scenario, you need to provide the following
credentials:

* Component TLS Certificates

* Authentication credentials for KraftController, Kafka, Control Center, remaining CP components, if any.

* RBAC principal credentials

You can either provide your own certificates, or generate test certificates. Follow instructions
in the below `Appendix: Create your own certificates` section to see how to generate certificates
and set the appropriate SANs.


## Provide component TLS certificates

```

kubectl create secret generic tls-kafka \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/kafka-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/kafka-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-controlcenter \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/controlcenter-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/controlcenter-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-schemaregistry \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/schemaregistry-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/schemaregistry-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-connect \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/connect-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/connect-server-key.pem \
  --namespace confluent
  
kubectl create secret generic tls-kafkarestproxy \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/kafkarestproxy-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/component-certs/generated/kafkarestproxy-server-key.pem \
  --namespace confluent
```

## Provide file based credentials

* Create a Kubernetes secret object for external users, which can be used for C3 login.

This secret object contains file based username/password. They kubernetes secret should have key "userstore.txt"
The users must be added in the format <username>:<password>

```
kubectl create secret generic file-secret \
--from-file=userstore.txt=$TUTORIAL_HOME/fileUserPassword.txt \
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

## Deploy Confluent Platform

* Deploy Confluent Platform without RBAC
```
kubectl apply -f $TUTORIAL_HOME/confluent-platform-mtls.yaml
```

* Check that all Confluent Platform resources are deployed:

```
kubectl get pods -n confluent
```

## Enable authorization in Kafka Broker and Kraft

* This restarts the kraft and kafka pods in rolling manner

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
security.protocol=SSL
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
--allow-principal "User:c3" --allow-principal "User:krp" \
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
--allow-principal "User:c3" \
--operation Describe --operation AlterConfigs  --operation DescribeConfigs \
--cluster kafka-cluster

```

## Enable RBAC in Kraft,Kafka and Create KafkaRestClass

* This restarts the kraft and kafka pods in rolling manner

```
kubectl apply -f $TUTORIAL_HOME/kafka-mtls-rbac.yaml
```

## Enable RBAC in Other CP components

* This restarts all cp components in rolling manner

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform-rbac.yaml
```

## Create RBAC Rolebindings for Control Center user

```
kubectl apply -f $TUTORIAL_HOME/controlcenter-rolebinding.yaml
```

## Validate

### Validate in Control Center

Use Control Center to monitor the Confluent Platform. You can visit the external URL you set up for Control Center, or visit the URL through a local port forwarding like below:

* Set up port forwarding to Control Center web UI from local machine:

```
kubectl port-forward controlcenter-0 9021:9021 -n confluent
```

* Browse to Control Center, use the credentials testuser1 as user, and password1 as password to login to Control Center.
```
https://localhost:9021
```

## Tear down

```
kubectl delete confluentrolebinding --all -n confluent
kubectl delete -f $TUTORIAL_HOME/confluent-platform-rbac.yaml -n confluent
kubectl delete secret mds-token -n confluent
kubectl delete secret file-secret -n confluent
kubectl delete secret tls-kafka tls-controlcenter tls-connect tls-kafkarestproxy tls-schemaregistry -n confluent
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
