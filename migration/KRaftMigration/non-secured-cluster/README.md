# Migrate from Zookeeper based Kafka cluster to KRaft based Kafka cluster using Confluent for Kubernetes 

Starting in the CFK 2.8, [CFK supports migration](https://docs.confluent.io/operator/current/co-migrate-kraft.html) from the Zookeeper based Confluent Platform deployment to Kraft based deployment. 
In this workflow scenario, you'll migrate from Zookeeper based Kafka cluster to KRaft based Kafka cluster using Confluent for Kubernetes. This example doesn't have any security enabled on the Confluent Platform deployment. 
Please make sure to follow the [requirements](https://docs.confluent.io/operator/current/co-migrate-kraft.html#requirements-and-considerations) before running the migration workflow. 

More details on the KRaft with Confluent for Kubernetes can be found in the following documentation link: 

* [Configure and Manage KRaft for Confluent Platform Using Confluent for Kubernetes](https://docs.confluent.io/operator/current/co-configure-kraft.html)

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:
```
export TUTORIAL_HOME=<Tutorial directory>/migration/KRaftMigration/non-secured-cluster
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

## Deploy Confluent Platform

* Deploy Zookeeper, Kafka, and KRaft cluster: 
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

Monitor the migration job status throughout the migration process using the following command: 
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
* Remove the migration CR lock using the `platform.confluent.io/kraft-migration-release-cr-lock` annotation.

```
kubectl annotate kraftmigrationjob kraft-migration \
  platform.confluent.io/kraft-migration-release-cr-lock=true \
  --namespace confluent
```

## Download the updated yaml

KRaft migration job modifies the yaml representation of Kafka and KRaftController CRs. To get the updated yaml, run the following commands:
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
kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml
helm delete operator -n confluent
```