# MRC Deployment - Basic

In this deployment, you'll deploy a quickstart Confluent Platform cluster across a multiple regions set up.

This assumes that you have set up three Kubernetes clusters, and have Kubernetes contexts set up as:
- mrc-central
- mrc-east
- mrc-west

## Set up - Deploy Confluent for Kubernetes

Deploy Confluent for Kubernetes to each Kubernetes cluster.

```
# Set up the Helm Chart

helm repo add confluentinc https://packages.confluent.io/helm

# Install Confluent For Kubernetes

helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n east --kube-context mrc-east

helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n west --kube-context mrc-west

helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n central --kube-context mrc-central
```

## Set up - Deploy Confluent Platform

In this step, you'll deploy:
- 3 Kafka brokers to the `west` region, and 3 Kafka brokers to the `east` region
  - Configure rack awareness so that partition placement can take broker region into account
- 3 Zookeeper servers to the `central` region
- 1 Control Center to the `west` region

### Configure service account

In order for rack awareness to be configured, you'll need to use a service account that is configured with a clusterrole/role that provides get/list access to both the pods and nodes resources. This is required as Kafka pods will curl kubernetes api for the node it is scheduled on using the mounted serviceAccountToken.

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform/rack-awareness/service-account-rolebinding-central.yaml --context mrc-central
kubectl apply -f $TUTORIAL_HOME/confluent-platform/rack-awareness/service-account-rolebinding-east.yaml --context mrc-east
kubectl apply -f $TUTORIAL_HOME/confluent-platform/rack-awareness/service-account-rolebinding-west.yaml --context mrc-west
```

### Deploy the clusters

Here, you'll deploy a Zookeeper cluster to the `central` region.
You'll deploy 2 Kafka clusters - one to `east` region and one to `west` region.

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform/basic-deployment/confluent-platform-central.yaml --context mrc-central
kubectl apply -f $TUTORIAL_HOME/confluent-platform/basic-deployment/confluent-platform-west.yaml --context mrc-west
kubectl apply -f $TUTORIAL_HOME/confluent-platform/basic-deployment/confluent-platform-east.yaml --context mrc-east
```

## Check deployment
Log in to Control Center by running:
```
kubectl confluent dashboard controlcenter
```
The credentials required for logging in are `c3:c3-secret`.

You should see a single cluster with 6 brokers with broker ids according to the offsets in the Kafka CRs: `0, 1, 2, 100, 101, 102`

## Tear down

```
kubectl delete -f $TUTORIAL_HOME/confluent-platform/basic-deployment/confluent-platform-central.yaml --context mrc-central
kubectl delete -f $TUTORIAL_HOME/confluent-platform/basic-deployment/confluent-platform-west.yaml --context mrc-west
kubectl delete -f $TUTORIAL_HOME/confluent-platform/basic-deployment/confluent-platform-east.yaml --context mrc-east

helm uninstall cfk-operator -n east --kube-context mrc-east
helm uninstall cfk-operator -n west --kube-context mrc-west
helm uninstall cfk-operator -n central --kube-context mrc-central
```


## Troubleshooting

### Check that Kafka is using the Zookeeper deployments

Look at the ZK nodes.

```
$ kubectl exec zookeeper-0 -it bash -n central --context mrc-central

bash-4.4$ zookeeper-shell 127.0.0.1:2181

ls /kafka-west/brokers/ids
[0, 1, 100, 101, 102, 2]

# You should see 6 brokers ^
```
