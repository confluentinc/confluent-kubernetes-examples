# Security setup

In this workflow scenario, you'll set up a Confluent Platform cluster with the following security:
- Full TLS network encryption with user provided certificates
- mTLS authentication
- Kafka ACLs authorization

Before continuing with the scenario, ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites).

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/userprovided-tls_mtls_kafka-acls
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

## Create TLS certificates

In this scenario, you'll configure authentication using the mTLS mechanism. With mTLS, Confluent components and clients use TLS certificates for authentication. The certificate has a CN that identifies the principal name.

Each Confluent component service should have it's own TLS certificate. In this scenario, you'll
generate a server certificate for each Confluent component service. Follow [these instructions](../../assets/certs/component-certs/README.md) to generate these certificates.

These TLS certificates include the following principal names for each component in the certificate Common Name:
- Kafka: `kafka`
- Schema Registry: `sr`
- Kafka Connect: `connect`
- Kafka Rest Proxy: `krp`
- ksqlDB: `ksql`
- Control Center: `controlcenter`
     
## Deploy configuration secrets

you'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.

To support the above deployment scenario, you need to provide the following
credentials:

* Component TLS Certificates

* Authentication credentials for Zookeeper, Kafka, Control Center, remaining CP components

### Provide component TLS certificates

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/userprovided-tls_mtls_kafka-acls
```

In this step, you will create secrets for each Confluent component TLS certificates.

```
kubectl create secret generic tls-zookeeper \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/zookeeper-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/zookeeper-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-kafka \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-controlcenter \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/controlcenter-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/controlcenter-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-schemaregistry \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/schemaregistry-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/schemaregistry-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-connect \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/connect-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/connect-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-ksqldb \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/ksqldb-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/ksqldb-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-kafkarestproxy \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafkarestproxy-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafkarestproxy-server-key.pem \
  --namespace confluent
```

### Provide authentication credentials

Create a Kubernetes secret object for Control Center authentication credentials.

This secret object contains file based properties. These files are in the
format that each respective Confluent component requires for authentication
credentials.

```   
kubectl create secret generic credential \
  --from-file=basic.txt=$TUTORIAL_HOME/creds-control-center-users.txt \
  --namespace confluent
```

## Deploy Confluent Platform

Deploy Confluent Platform:

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform-mtls-acls.yaml --namespace confluent
```

Check that all Confluent Platform resources are deployed:

```
kubectl get pods --namespace confluent
```

If any component does not deploy, it could be due to missing configuration information in secrets.
The Kubernetes events will tell you if there are any issues with secrets. For example:  

If you see a **`CrashLoopBackOff`** on any of the components like Schema Registry / Connect or Control Center, this is **expected** as the ACLs were not yet created, continue to the next steps to add ACLs.  

```
kubectl get events --namespace confluent
Warning  KeyInSecretRefIssue  kafka/kafka  required key [ldap.txt] missing in secretRef [credential] for auth type [ldap_simple]
```

## Create the ACLs for each component

You'll see that Schema Registry, Connect, ksqlDB, Control Center - all fail to come up. This is because 
the Kafka ACLs that let these components create, read and write to their required topics have not been 
created.

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

Create ACLs:

```
# For Schema Registry

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:sr" \
 --operation Read --operation Write --operation Create \
 --topic _confluent-license

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:sr" \
 --operation Describe \
 --topic __consumer_offsets \
 --topic _confluent-metrics \
 --topic _confluent-telemetry-metrics \
 --topic _confluent-command \
 --topic _confluent-monitoring \
 --topic confluent.connect-configs \
 --topic confluent.connect-offsets \
 --topic confluent.connect-status \
 --topic _confluent-ksql-confluent.ksqldb__command_topic
 
/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:sr" \
 --operation Describe \
 --topic _confluent_balancer \
 --topic _confluent-controlcenter \
 --resource-pattern-type prefixed

### The schemas topic is named: _schemas_<sr-cluster-name>_<namespace>
/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:sr" \
 --operation Read --operation Write --operation Create --operation DescribeConfigs --operation Describe \
 --topic _schemas_schemaregistry_confluent

### The Schema Registry consumer group is: id_<sr-cluster-name>_<namespace>
/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:sr" \
 --operation Read \
 --group id_schemaregistry_confluent

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:sr" \
 --operation ClusterAction \
 --cluster kafka-cluster


# For Connect

### The Connect topic prefix is: <namespace>.<connect-cluster-name>-
/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:connect" \
 --operation Read --operation Write --operation Create \
 --topic confluent.connect- \
 --resource-pattern-type prefixed

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:connect" \
 --operation Write \
 --topic _confluent-monitoring \
 --resource-pattern-type prefixed

### The Connect consumer group is: <namespace>.<connect-cluster-name>
/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:connect" \
 --operation Read \
 --group confluent.connect

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:connect" \
 --operation Create --operation ClusterAction \
 --cluster kafka-cluster

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:connect" \
 --operation Describe \
 --topic _confluent-controlcenter \
 --resource-pattern-type prefixed

 /bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:connect" \
 --operation Describe \
 --topic __consumer_offsets \
 --topic _confluent-command \
 --topic _confluent-ksql-confluent.ksqldb__command_topic \
 --topic _confluent-license \
 --topic _confluent-metrics \
 --topic _confluent-telemetry-metrics \
 --topic _confluent_balancer_api_state \
 --topic _confluent_balancer_broker_samples \
 --topic _confluent_balancer_partition_samples \
 --topic _schemas_schemaregistry_confluent \
 --topic confluent.connect-offsets

# For ksqlDB

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:ksql" \
 --operation Read --operation Write --operation Create \
 --topic app1_ \
 --resource-pattern-type prefixed

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:ksql" \
 --operation All \
 --topic _confluent-ksql-confluent \
 --resource-pattern-type prefixed

 /bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:ksql" \
 --operation Describe \
 --cluster kafka-cluster
 
# For Control Center

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:c3" \
 --operation Read --operation Write --operation Create --operation Alter --operation AlterConfigs --operation Delete \
 --topic _confluent-controlcenter \
 --resource-pattern-type prefixed

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:c3" \
 --operation Read --operation Write --operation Create \
 --topic _confluent-command

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:c3" \
 --operation Read --operation Write --operation Create --operation DescribeConfigs --operation Describe \
 --topic _confluent-metrics

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:c3" \
 --operation Read --operation Write --operation Create --operation DescribeConfigs --operation Describe --operation Alter --operation AlterConfigs --operation Delete \
 --topic _confluent-monitoring \
 --topic _confluent-telemetry-metrics \
 --topic confluent.connect-configs \
 --topic confluent.connect-offsets \
 --topic confluent.connect-status \
  --topic __consumer_offsets

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:c3" \
 --operation Describe --operation Alter --operation AlterConfigs --operation Create --operation Delete --operation DescribeConfigs \
 --topic _confluent_balancer_api_state \
 --topic _confluent_balancer_broker_samples \
 --topic _confluent_balancer_partition_samples \
 --topic _confluent-command \
 --topic _confluent-ksql-confluent.ksqldb__command_topic \
 --topic _confluent-license \
 --topic _confluent-telemetry-metrics \
 --topic _schemas_schemaregistry_confluent

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:c3" \
 --operation DescribeConfigs \
 --topic _confluent-command

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:c3" \
 --operation DescribeConfigs \
 --topic _confluent-controlcenter \
 --resource-pattern-type prefixed

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:c3" \
 --operation AlterConfigs --operation Create --operation Describe --operation DescribeConfigs --operation Describe --operation ClusterAction \
 --cluster kafka-cluster

/bin/kafka-acls --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
 --command-config /opt/confluentinc/kafka.properties \
 --add \
 --allow-principal "User:c3" \
 --operation AlterConfigs --operation Create --operation Describe --operation DescribeConfigs --operation Create \
 --cluster kafka-cluster

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

Browse to Control Center.

```
https://localhost:9021
```

## Tear down

```  
kubectl delete -f $TUTORIAL_HOME/confluent-platform-mtls-acls.yaml --namespace confluent

kubectl delete secret \
tls-zookeeper tls-kafka  tls-controlcenter tls-schemaregistry tls-connect tls-ksqldb credential \
--namespace confluent

helm delete operator --namespace confluent
```

## Appendix: Troubleshooting

### Gather data to troubleshoot

```
# Check for any error messages in events
kubectl get events --namespace confluent

# Check for any pod failures
kubectl get pods --namespace confluent

# For CP component pod failures, check pod logs
kubectl logs <pod-name> --namespace confluent
```

### Component authorization issue

**Issue**

This issue occurs when the component cannot access Kafka resources because of authorization issues.

In the component logs, you'll see errors like this:

```
[ERROR] 2021-07-27 21:47:16,926 [DistributedHerder-connect-1-1] org.apache.kafka.connect.runtime.distributed.DistributedHerder run - [Worker clientId=connect-1, groupId=confluent.connect] Uncaught exception in herder work thread, exiting:
org.apache.kafka.common.errors.TopicAuthorizationException: Not authorized to access topics: [confluent.connect-offsets]
```

**Solution**

Check the following:
1) What principal is being used by the component - this comes from the CN of the certificate used by the component
2) Are the appropriate ACL created for the components principal

To see why Kafka failed the access request, look at the kafka broker logs. 
You might see messages that indicate authorization failures:

```
[INFO] 2021-07-27 21:41:33,793 [data-plane-kafka-request-handler-7] kafka.authorizer.logger logAuditMessage - Principal = User:sr is Denied Operation = Describe from host = 10.124.4.50 on resource = Topic:LITERAL:_confluent-license
```
