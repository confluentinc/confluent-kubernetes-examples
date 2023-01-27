# Configure Workloads Scheduling

In this workflow scenario, you'll deploy Confluent Platform to a multi-zone Kubernetes cluster, with Pod's Workload Scheduling configured.

One of the things you can do to get the optimal performance out of Confluent components is to control how the component pods are scheduled on Kubernetes nodes. For example, you can configure pods not to be scheduled on the same node as other resource intensive applications, pods to be scheduled on dedicated nodes, or pods to be scheduled on the nodes with the most suitable hardware.

Read more about Pod Scheduling in [Confluent Docs][1].


## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/scheduling/pod-scheduling
```

## Deploy Confluent for Kubernetes

This workflow scenario assumes you are using the namespace `confluent`.

Set up the Helm Chart:

```
helm repo add confluentinc https://packages.confluent.io/helm
```

Install Confluent For Kubernetes using Helm:

```
helm upgrade --install operator confluentinc/confluent-for-kubernetes -n confluent
```
  
Check that the Confluent For Kubernetes pod comes up and is running:

```
kubectl get pods
```

## Configure 

### Set Required or Preferred

Two types of affinity rules are supported:

1. `requiredDuringSchedulingIgnoredDuringExecution`
2. `preferredDuringSchedulingIgnoredDuringExecution`

In `confluent-platform.yml`, `requiredDuringSchedulingIgnoredDuringExecution` is used.

### Set the labelSelector

`labelSelector` is used to find matching pods by label. This can be found by querying the pod:

```
> kubectl describe pod/<pod-name>

# In the Labels section, key-value names are found.

Labels:           app=zookeeper
                  clusterId=confluent
                  confluent-platform=true
                  controller-revision-hash=zookeeper-75c664dbbf
                  platform.confluent.io/type=zookeeper
                  statefulset.kubernetes.io/pod-name=zookeeper-0
                  type=zookeeper
```

To only apply this rule to zookeeper, set

```
- labelSelector:
   matchExpressions:
   - key: app
     operator: In
     values:
     - zookeeper
```


### Get the topologyKey

The topology key is the label of the cluster node to specify the nodes to co-locate or avoid scheduling pods. This depends on the Kubernetes flavors such as cloud providers. To get the correct value, run:

```
> kubectl get node

NAME                                STATUS   ROLES   AGE     VERSION
aks-agentpool-18842733-vmss000001   Ready    agent   7h59m   v1.24.6
aks-agentpool-18842733-vmss000003   Ready    agent   154m    v1.24.6
aks-agentpool-18842733-vmss000004   Ready    agent   153m    v1.24.6
```

And pick a node and describe it:

```
> kubectl describe node/aks-agentpool-18842733-vmss000001

Labels:             agentpool=agentpool
                    beta.kubernetes.io/arch=amd64
                    beta.kubernetes.io/instance-type=Standard_A8m_v2
                    beta.kubernetes.io/os=linux
                    failure-domain.beta.kubernetes.io/region=japaneast
                    failure-domain.beta.kubernetes.io/zone=japaneast-2
                    kubernetes.azure.com/agentpool=agentpool
                    kubernetes.azure.com/cluster=MC_taku-test_taku-test_japaneast
                    kubernetes.azure.com/kubelet-identity-client-id=f8663bd6-a676-4b9f-8cb7-f57bc43a92a7
                    kubernetes.azure.com/mode=system
                    kubernetes.azure.com/node-image-version=AKSUbuntu-1804containerd-2023.01.10
                    kubernetes.azure.com/os-sku=Ubuntu
                    kubernetes.azure.com/role=agent
                    kubernetes.azure.com/storageprofile=managed
                    kubernetes.azure.com/storagetier=Standard_LRS
                    kubernetes.io/arch=amd64
                    kubernetes.io/hostname=aks-agentpool-18842733-vmss000001
                    kubernetes.io/os=linux
                    kubernetes.io/role=agent
                    node-role.kubernetes.io/agent=
                    node.kubernetes.io/instance-type=Standard_A8m_v2
                    storageprofile=managed
                    storagetier=Standard_LRS
                    topology.disk.csi.azure.com/zone=japaneast-2
                    topology.kubernetes.io/region=japaneast
                    topology.kubernetes.io/zone=japaneast-2
```

Select a key to use, for example, `topology.kubernetes.io/zone`.


## Deploy Kafka Components

To deploy Kafka components:
```
kubectl apply -f $TUTORIAL_HOME/confluent-platform.yml
```

If the changes aren't applied, run `kubectl delete pod/<pod-name>` to restart individual pods.

## Tear Down

To tear down the components, run:
```
kubectl delete -f $TUTORIAL_HOME/confluent-platform.yml
```

## Troubleshooting

1. Pod is in a Pending state.

Run `kubectl describe pod/<pod-name>` and see why the correct node is not assigned. 

2. Pod is not assigned to node due to `volume node affinity conflict`.

Check the Persistent Volume and Persistent Volume Claim. (`kubectl get pv` or `kubectl get pvc`) Most likely multiple volumes already belong to the same node or zone. A quick forceful fix is by tearing down the YAML file, removing pods, removing PVC, removing PVs, and then deploy again.


