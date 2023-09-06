# Deploy KRaft broker and controller with CFK

- [Set the current tutorial directory](#set-the-current-tutorial-directory)
- [Deploy Confluent for Kubernetes](#deploy-confluent-for-kubernetes)
- [Set up cluster](#set-up-cluster)
  * [Deploy KRaft broker and controller](#deploy-kraft-broker-and-controller)
  * [Produce and consume from the topics](#produce-and-consume-from-the-topics)
- [Tear down Cluster](#tear-down-cluster)

This playbook explains how to deploy KRaft brokers and controllers with CFK. Before continuing with the scenario, ensure that you have set up the
[prerequisites](/README.md#prerequisites).

## Set the current tutorial directory

Set the tutorial directory under the directory you downloaded this Github repo:

```   
export TUTORIAL_HOME=<Github repo directory>/quickstart-deploy/kraft-quickstart
```

## Deploy Confluent for Kubernetes

This workflow scenario assumes you are using the namespace `confluent`.

1. Set up the Helm Chart:

```
helm repo add confluentinc https://packages.confluent.io/helm
```

2. Install Confluent For Kubernetes using Helm:

```
helm upgrade --install operator confluentinc/confluent-for-kubernetes -n confluent --set kRaftEnabled=true
```
#### NOTE:  
Make sure to deploy CFK with the `–-set kRaftEnabled=true` flag in the helm upgrade command so that CFK can create the required ClusterRole and ClusterRolebinding for KRaft controllers. Please check the following documentation link for more information: 

- [Deploy CFK with KRaft](https://docs.confluent.io/operator/current/co-deploy-cfk.html#deploy-co-with-kraft)
                

3. Check that the Confluent For Kubernetes pod comes up and is running:

```
kubectl get pods -n confluent
```

## Set up cluster

### Deploy KRaft broker and controller

    kubectl apply -f $TUTORIAL_HOME/kraftbroker_controller.yaml

### Produce and consume from the topics
```
kubectl -n confluent exec -it kafka-0 -- bash

seq 5 | kafka-console-producer --topic demotopic --broker-list kafka.confluent.svc.cluster.local:9092

kafka-console-consumer --from-beginning --topic demotopic --bootstrap-server  kafka.confluent.svc.cluster.local:9092
1
2
3
4
5
```

## Tear down Cluster
    kubectl delete -f $TUTORIAL_HOME/kraftbroker_controller.yaml
    helm uninstall operator -n confluent
    kubectl delete namespace confluent

