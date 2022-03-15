# Configure Networking: Google Kubernetes Engine

This is the architecture you'll acheive on Google Kubernetes Engine (GKE):

- Namespace naming
  - 1 uniquely named namespace in each region cluster
    - For example: east namespace in the East cluster, central namespace in Central, and west in West
- Flat pod networking
  - Pod IP range from separate clusters must not overlap
  - Pod IPs must be routable between Kubernetes clusters
- Kube DNS
  - each region cluster’s Kube DNS servers exposed via a Load Balancer to other region clusters
  - each region cluster to regard the other region clusters' Kube DNSes as authoritative for domains it doesn’t recognize
    - In particular, Kube DNS in the East cluster is configured for the external Load Balancer IP of the West cluster’s Kube DNS to be the authoritative nameserver for the west.svc.cluster.local stub domain, and like wise for all pairs of regions.
- Firewall rules
  - At minimum: allow TCP traffic on the standard ZooKeeper and Kafka ports between all region clusters' Pod subnetworks.

In this section, you'll configure the required networking between three Google Kubernetes Engine (GKE) clusters, where each GKE cluster is in a different Google Cloud Platform region.

export TUTORIAL_HOME=<Tutorial directory>/hybrid/multi-region-clusters

## Create clusters

Spin up the GKE clusters:

```
# Spin up a cluster in us-west
gcloud container clusters create mrc-west --region=us-west1

# Set the kubectl context so you can refer to it
kubectl config rename-context <your-gke-cluster-name> mrc-west
```

```
# Spin up a cluster in us-east
gcloud container clusters create mrc-east --region=us-east1

# Set the kubectl context so you can refer to it
kubectl config rename-context <your-gke-cluster-name> mrc-east
```

```
# Spin up a cluster in us-east
gcloud container clusters create mrc-central --region=us-central1

# Set the kubectl context so you can refer to it
kubectl config rename-context <your-gke-cluster-name> mrc-central
```

## Create namespaces

You'll create two namespaces, one in each Kubernetes cluster.

```
kubectl create ns west --context mrc-west

kubectl create ns east --context mrc-east

kubectl create ns central --context mrc-central
```

## Set up DNS

### Create a load balancer to access Kube DNS in each Kubernetes cluster

```
kubectl apply -f $TUTORIAL_HOME/networking/dns-lb.yaml --context mrc-west

kubectl apply -f $TUTORIAL_HOME/networking/dns-lb.yaml --context mrc-east

kubectl apply -f $TUTORIAL_HOME/networking/dns-lb.yaml --context mrc-central
```

### Determine the IP address endpoint for each Kube DNS load balancer

```
# For West region
kubectl describe svc kube-dns-lb --namespace kube-system --context mrc-west

Name:                     kube-dns-lb
Namespace:                kube-system
...
Selector:                 k8s-app=kube-dns
Type:                     LoadBalancer
IP:                       10.0.37.50
LoadBalancer Ingress:     35.185.208.215  ## The load balancer IP
```

```
# For East region
kubectl describe svc kube-dns-lb --namespace kube-system --context mrc-east

Name:                     kube-dns-lb
Namespace:                kube-system
...
Selector:                 k8s-app=kube-dns
Type:                     LoadBalancer
IP:                       10.96.0.99
LoadBalancer Ingress:     34.74.229.93  ## The load balancer IP
```

```
# For Central region
kubectl describe svc kube-dns-lb --namespace kube-system --context mrc-central

Name:                     kube-dns-lb
Namespace:                kube-system
...
Selector:                 k8s-app=kube-dns
Type:                     LoadBalancer
IP:                       10.1.32.71
LoadBalancer Ingress:     35.224.242.222  ## The load balancer IP
```

### Configure cluster DNS configmap

Configure each cluster's DNS configuration with entries for the two other cluster's DNS load
balancer endpoints. In each region, don't include the endpoint for the region's own load balancer,
so as to protect against infinite recursion in DNS resolutions.

```
# For West cluster

# dns-configmap-west.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns
  namespace: kube-system
data:
  stubDomains: |
    {"east.svc.cluster.local": ["34.74.229.93"], "central.svc.cluster.local": ["35.224.242.222"]}

kubectl apply -f $TUTORIAL_HOME/networking/dns-configmap-west.yaml --context mrc-west

kubectl delete pods -l k8s-app=kube-dns --namespace kube-system --context mrc-west
```

```
# For Central cluster

# dns-configmap-central.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns
  namespace: kube-system
data:
  stubDomains: |
    {"east.svc.cluster.local": ["34.74.229.93"], "west.svc.cluster.local": ["35.185.208.215"]}

kubectl apply -f $TUTORIAL_HOME/networking/dns-configmap-central.yaml --context mrc-central

kubectl delete pods -l k8s-app=kube-dns --namespace kube-system --context mrc-central
```

```
# For East cluster

# dns-configmap-east.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns
  namespace: kube-system
data:
  stubDomains: |
    {"central.svc.cluster.local": ["35.224.242.222"], "west.svc.cluster.local": ["35.185.208.215"]}

kubectl apply -f $TUTORIAL_HOME/networking/dns-configmap-east.yaml --context mrc-east

kubectl delete pods -l k8s-app=kube-dns --namespace kube-system --context mrc-east
```

## Open ports to allow communication across regions

Create a firewall rule to allow TCP traffic between the regions, to facilitate communication 
to Kafka and Zookeeper across regions:

```
gcloud compute firewall-rules create allow-cp-internal \
  --allow=tcp \
  --source-ranges=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
```

## Validate networking setup

You'll validate that the networking is set up correctly by pinging across regions on the local
Kubernetes network.

Start a Linux container in the `west` region and check the IP address for this pod

```
kubectl run --generator=run-pod/v1 --image=alpine:3.5 -it alpine-shell -n west --context mrc-west
# Exit out of the shell session
/ # exit

# Get the IP address
kubectl describe pod alpine-shell -n west --context mrc-west
...
IP:           10.124.0.5
...
```

Start a Linux container in the `east` region and ping the container in the `west` region

```
kubectl run --generator=run-pod/v1 --image=alpine:3.5 -it alpine-shell -n east --context mrc-east

# Ping the `west` container IP address
/ # ping 10.124.0.5
PING 10.124.0.5 (10.124.0.5): 56 data bytes
64 bytes from 10.124.0.5: seq=0 ttl=62 time=66.117 ms
64 bytes from 10.124.0.5: seq=1 ttl=62 time=65.020 ms
...
```

If you see a successful ping result like above, then the networking setup is done correctly.