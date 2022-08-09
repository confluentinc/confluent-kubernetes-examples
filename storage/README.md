# Create a Production Storage Class on GKE

In this workflow scenario, you'll create a custom storage class on GKE for your Confluent Platform cluster. We do not recommend using the default storage class on GKE for production clusters because it has its `ReclaimPolicy` set to Delete. 

Before continuing with the scenario, ensure that you have set up the
[prerequisites](/README.md#prerequisites).

## Set the current tutorial directory

Set the tutorial directory under the directory you downloaded this GitHub repo:

```   
export TUTORIAL_HOME=<GitHub repo directory>/storage
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

## Create a Custom Storage Class

To create the custom storage class for Confluent Platform:
```
kubectl apply -f $TUTORIAL_HOME/storage.yml
```

## Deploy Confluent Platform

Using a Custom Storage Class is as simple as setting a storage class in your CRD spec:

```
spec:
  storageClass:
    name: production-storage-class
```

Deploy Confluent Platform:
```
kubectl apply -f $TUTORIAL_HOME/deployment.yaml
```

## Confirm Persistent Volume

Now to confirm your PVCs are using the storage class
```
% kubectl get pvc 
NAME                 STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS               AGE
data-zookeeper-0     Bound    pvc-abd3dfba-c2c0-47f3-9bf2-7dbb0526bd45   10Gi       RWO            production-storage-class   4m53s
data-zookeeper-1     Bound    pvc-bffdacc8-9484-4fce-b27b-1d9357ad95ef   10Gi       RWO            production-storage-class   4m44s
data-zookeeper-2     Bound    pvc-cec4d627-0c58-40fd-81c9-c0c6bd4667d2   10Gi       RWO            production-storage-class   4m44s
data0-kafka-0        Bound    pvc-db459bd3-784d-4e94-9e34-95e6b65d2ef0   10Gi       RWO            production-storage-class   3m36s
data0-kafka-1        Bound    pvc-c1129fcb-4a24-46ff-8f45-de313386b18e   10Gi       RWO            production-storage-class   3m36s
data0-kafka-2        Bound    pvc-1b801f22-5df5-49a5-9569-ae8ffb501a58   10Gi       RWO            production-storage-class   3m36s
txnlog-zookeeper-0   Bound    pvc-f3d6dc23-c905-49e2-9d5b-9eed29deae16   10Gi       RWO            production-storage-class   4m53s
txnlog-zookeeper-1   Bound    pvc-578b8bbf-ea28-4725-99f7-3f519a03d181   10Gi       RWO            production-storage-class   4m44s
txnlog-zookeeper-2   Bound    pvc-f6de1b11-d36e-4b39-bbca-437a60724cb9   10Gi       RWO            production-storage-class   4m44s
```

And to inspect one of the PVs:
```
% k get pv pvc-1b801f22-5df5-49a5-9569-ae8ffb501a58
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                    STORAGECLASS               REASON   AGE
pvc-1b801f22-5df5-49a5-9569-ae8ffb501a58   10Gi       RWO            Retain           Bound    operator/data0-kafka-2   production-storage-class            5m23s
```

Notice the Reclaim Policy is set to **Retain**!