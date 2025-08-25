# Migrate from ZK based Kafka cluster with rbac authorization to KRaft based Kafka cluster using Confluent for Kubernetes

Starting in the CFK 2.8, [CFK supports migration](https://docs.confluent.io/operator/current/co-migrate-kraft.html) from the Zookeeper based Confluent Platform deployment to Kraft based deployment.
In this workflow scenario, you'll migrate from Zookeeper based Kafka cluster with rbac authorization to KRaft based Kafka cluster with rbac using Confluent for Kubernetes. This example has the rbac enabled on the Kafka cluster. 

Please make sure to follow the [requirements](https://docs.confluent.io/operator/current/co-migrate-kraft.html#requirements-and-considerations) before running the migration workflow.

More details on the KRaft with Confluent for Kubernetes can be found in the following documentation link:

* [Configure and Manage KRaft for Confluent Platform Using Confluent for Kubernetes](https://docs.confluent.io/operator/current/co-configure-kraft.html)

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/migration/KRaftMigration/rbac-enabled-cluster
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
helm upgrade --install -f $TUTORIAL_HOME/../../../assets/openldap/ldaps-rbac.yaml test-ldap $TUTORIAL_HOME/../../assets/openldap --namespace confluent
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

* Authentication credentials for Zookeeper, Kafka and other Confluent Platform component

* RBAC principal credentials

You can either provide your own certificates, or generate test certificates. Follow instructions
in the below `Appendix: Create your own certificates` section to see how to generate certificates
and set the appropriate SANs.


## Provide component TLS certificates

```
kubectl create secret generic tls-group1 \
--from-file=fullchain.pem=$TUTORIAL_HOME/../../../assets/certs/generated/server.pem \
--from-file=cacerts.pem=$TUTORIAL_HOME/../../../assets/certs/generated/ca.pem \
--from-file=privkey.pem=$TUTORIAL_HOME/../../../assets/certs/generated/server-key.pem \
-n confluent
```


## Provide authentication credentials

* Create a Kubernetes secret object for Zookeeper, Kafka and other Confluent Platform component.

This secret object contains file based properties. These files are in the
format that each respective Confluent component requires for authentication
credentials.

```
kubectl create secret generic credential \
--from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
--from-file=digest-users.json=$TUTORIAL_HOME/creds-zookeeper-sasl-digest-users.json \
--from-file=digest.txt=$TUTORIAL_HOME/creds-kafka-zookeeper-credentials.txt \
--from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
--from-file=ldap.txt=$TUTORIAL_HOME/ldap.txt \
--from-file=plain-interbroker.txt=$TUTORIAL_HOME/creds/creds-client-kafka-sasl-user.txt \
--namespace confluent
```

```
kubectl create secret generic credential-plain \
--from-file=plain-jaas.conf=$TUTORIAL_HOME/creds-kafka-sasl-users.conf \
--namespace confluent
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

* Create Kafka REST credential
```
kubectl create secret generic rest-credential \
--from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
--from-file=basic.txt=$TUTORIAL_HOME/bearer.txt \
-n confluent
```

## Deploy Confluent Platform

* Deploy Confluent Platform
```
kubectl apply -f $TUTORIAL_HOME/zookeeper.yaml
kubectl apply -f $TUTORIAL_HOME/confluent-platform.yaml
```

* Check that all Confluent Platform resources are deployed:
```
kubectl get pods -n confluent
```

## Create Migration Job

* Create KRaft migration job to migrate the ZooKeeper-based Confluent Platform to a KRaft-based deployment
```
kubectl apply -f $TUTORIAL_HOME/kraftmigrationjob.yaml
```

## Monitor Migration job

Keep monitoring the migration job throughout the migration process using the following command:
```
kubectl get kraftmigrationjob kraft-migration -n confluent -oyaml -w 
```

The complete migration time would be dependent on the following factors:

* Time to take single Kafka roll multiplied by 3
* Time to migrate metadata from ZooKeeper to KRaftController
* Time to take the KRaftController roll

## Move to kRaft mode completely

* Once the KRaft migration job status phase changes to `DUAL-WRITE`, KRaft migration workflow will be in Dual write mode means Kafka cluster writes metadata to both KRaftControllers as well as ZK nodes. The dual mode write mode status can be seen via monitoring the migration job.
* Validate that all data has been migrated without any loss.
* If validation passes, and you want to complete the migration process to move to the KRaft mode completely, apply the `platform.confluent.io/kraft-migration-trigger-finalize-to-kraft` annotation to the migration job CR. If validation fails, and you want to go back to ZooKeeper, you can [roll back to ZooKeeper](https://docs.confluent.io/operator/current/co-migrate-kraft.html#co-rollback-to-zookeeper).

```
kubectl annotate kraftmigrationjob kraft-migration \
platform.confluent.io/kraft-migration-trigger-finalize-to-kraft=true \
--namespace confluent 
```

## Remove the lock

Once the migration is completed i.e. `status.Phase` is `COMPLETE` for kraftmigrationjob, a few additional post migration steps need to be done.

The migration job locks the Kafka, ZooKeeper, and KRaft resources on initialization of migration workflow. When migration is completed, status message will prompt you to:

* Download the updated Kafka and kRaftController CR
* Update your CI/CD as necessary.
* Remove the migration CR lock using the platform.confluent.io/kraft-migration-release-cr-lock annotation.

```
kubectl annotate kraftmigrationjob kraft-migration \
  platform.confluent.io/kraft-migration-release-cr-lock=true \
  --namespace confluent
```

## Download the updated yaml 

KRaft migration job modifies the YAML representation of Kafka and KRaftController CRs. To get the updated yaml, run the following commands:
```
kubectl get kafka kafka -n confluent -oyaml > updated_kafka.yaml
kubectl get kraftcontroller kraftcontroller -n confluent -oyaml > updated_kraftcontroller.yaml
```

## Delete the zookeeper cluster

Once the migration is finished, zookeeper cluster can be removed.
```
kubectl delete -f $TUTORIAL_HOME/zookeeper.yaml
```

## Tear down

```
kubectl delete -f $TUTORIAL_HOME/kraftmigrationjob.yaml
kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml -n confluent
kubectl delete secret rest-credential mds-client mds-token -n confluent
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
mkdir $TUTORIAL_HOME/../../../assets/certs/generated && cfssl gencert -initca $TUTORIAL_HOME/../../../assets/certs/ca-csr.json | cfssljson -bare $TUTORIAL_HOME/../../../assets/certs/generated/ca -
```
* Validate Certificate Authority
```
openssl x509 -in $TUTORIAL_HOME/../../../assets/certs/generated/ca.pem -text -noout
```
* Create server certificates with the appropriate SANs (SANs listed in server-domain.json)
```
cfssl gencert -ca=$TUTORIAL_HOME/../../../assets/certs/generated/ca.pem \
-ca-key=$TUTORIAL_HOME/../../../assets/certs/generated/ca-key.pem \
-config=$TUTORIAL_HOME/../../../assets/certs/ca-config.json \
-profile=server $TUTORIAL_HOME/../../../assets/certs/server-domain.json | cfssljson -bare $TUTORIAL_HOME/../../../assets/certs/generated/server
``` 

* Validate server certificate and SANs
```
openssl x509 -in $TUTORIAL_HOME/../../../assets/certs/generated/server.pem -text -noout
```







