# SASL PLAIN to RBAC with OAuth migration for Kraft cluster

In this workflow scenario, you'll set up a SASL PLAIN Kraft Cluster and then migrate it to RBAC with OAuth(oidc) user store.
Post migration to RBAC, Kafka listeners have sasl plain, MDS has OAuth(oidc) for authorization.  Control center has SSO.

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/migration/nonRBACToRBAC/saslplainOAuth
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

## Deploy Keycloak

* Deploy [Keycloak](https://www.keycloak.org/) which is an open source identity and access managment solution. `keycloak.yaml` is used for an example here, this is not supported by Confluent. Therefore, please make sure to use the identity provider as per the organization requirement.
```
kubectl apply -f $TUTORIAL_HOME/keycloak.yaml
```

* Validate that Keycloak pod is running:
```
kubectl get pods -n confluent 
```

## Deploy configuration secrets

You'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.

To support the above deployment scenario, you need to provide the following
credentials:

* Authentication credentials for KraftController, Kafka, Control Center, remaining CP components, if any.

* RBAC principal credentials

## Provide authentication credentials

* Create a Kubernetes secret object for KraftController, Kafka.

This secret object contains file based properties. These files are in the
format that each respective Confluent component requires for authentication
credentials.

```
kubectl create secret generic credential \
--from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
--from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
-n confluent
```

## Create jass config secret
```
kubectl create -n confluent secret generic oauth-jass --from-file=oauth.txt=$TUTORIAL_HOME/oauth_jass.txt
kubectl -n confluent create secret generic oauth-jass-oidc --from-file=oidcClientSecret.txt=$TUTORIAL_HOME/oauth_jass.txt
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
kubectl apply -f $TUTORIAL_HOME/confluent-platform-plain.yaml
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
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="kafka" password="kafka-secret";
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
kubectl apply -f $TUTORIAL_HOME/kafka-oauth-rbac.yaml
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

* Set up port frowarding for Keyclok:
```
kubectl port-forward deployment/keycloak 8080:8080 -n confluent 
```

* Browse to Control Center, click on `Log in via SSO`, use the credentials user1 as user, and user1 as password to login to Control Center.
```
http://localhost:9021
```

## Tear down

```
kubectl delete confluentrolebinding --all -n confluent
kubectl delete -f $TUTORIAL_HOME/confluent-platform-rbac.yaml -n confluent
kubectl delete secret c3-kafka-client connect-kafka-client sr-kafka-client krp-kafka-client -n confluent
kubectl delete secret oauth-jass oauth-jass-oidc -n confluent
kubectl delete secret mds-token -n confluent
kubectl delete secret credential -n confluent
kubectl delete -f $TUTORIAL_HOME/keycloak.yaml
helm delete operator -n confluent
```
