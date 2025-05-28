# Create namespace
kubectl create ns central --context mrc-central
kubectl create ns east --context mrc-east
kubectl create ns west --context mrc-west

# Install Confluent For Kubernetes

```bash
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n central --values charts/values/values.yaml --kube-context mrc-central
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n east --values charts/values/values.yaml --kube-context mrc-east
helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes -n west --values charts/values/values.yaml --kube-context mrc-west
```

# Set up the Helm Chart
helm repo add confluentinc https://packages.confluent.io/helm


# Setup the Helm chart
helm repo add bitnami https://charts.bitnami.com/bitnami

# Install External DNS
This is optional, if you want to use external-dns to manage the DNS records for the services, you can install it using the following commands.
```bash
helm install external-dns -f external-dns-values.yaml --set namespace=kraft-central,txtOwnerId=mrc-central bitnami/external-dns -n kraft-central --kube-context mrc-central
helm install external-dns -f external-dns-values.yaml --set namespace=kraft-east,txtOwnerId=mrc-east bitnami/external-dns -n kraft-east 
helm install external-dns -f external-dns-values.yaml --set namespace=kraft-west,txtOwnerId=mrc-west bitnami/external-dns -n kraft-west 
```
## Install KRAFT controllers

```bash
kubectl apply -f kraft/kraft-central.yaml --kube-context mrc-central
```


> [!NOTE]
>   
> We need to set the cluster-id same in all the clusters. CFK will generate different cluster in each region by default, so for MRC
> we need to set the cluster id explicitly. We can simply deploy in one cluster and fetch the cluster-id from the status and use it in other clusters.
    
To get the cluster-id from the status of the kraftcontroller, run the following command:
```bash
kubectl get kraftcontroller kraftcontroller-central -n kraft-central --kube-context mrc-east -ojson | jq .status.clusterID
```
 For this example we are randomly using the value of 'f66a6843-54f1-4af8-b3Q'

```bash
kubectl apply -f kraft/kraft-east.yaml --kube-context mrc-east
kubectl apply -f kraft/kraft-west.yaml --kube-context mrc-west
```

## Install Kafka brokers controllers

```bash
kubectl apply -f kraft/kraft-central.yaml --kube-context mrc-central
kubectl apply -f kraft/kraft-east.yaml --kube-context mrc-east
kubectl apply -f kraft/kraft-west.yaml --kube-context mrc-west
```


## Create topic in central cluster
Here we create a topic with replication factor 3.
```bash
kubectl apply -f kraft/topic.yaml --kube-context mrc-central
```

### produce to the topic
```bash
 kubectl apply -f producer_app.yaml
```
Now we can check the logs

```bash 
kubectl logs elastic-0 -n kraft-central --kube-context mrc-central
```
here we can see the messages being produced to the topic.
