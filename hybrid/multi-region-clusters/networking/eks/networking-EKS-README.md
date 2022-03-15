# Configure Networking: Azure Kubernetes Service

This is the architecture you'll achieve on Elastic Kubernetes Service (EKS):

- Namespace naming
  - 1 uniquely named namespace in each region cluster
    - For example: central namespace in Central, east namespace in the East cluster, and west in West
- VPC Peering
  - A VPC peering connection is a networking connection between two VPCs that enables you to route traffic between them 
  using private IPv4 addresses or IPv6 addresses. Instances in either VPC can communicate with each other as if they are
  within the same network. You can create a VPC peering connection between your own VPCs, or with a VPC in another AWS 
  account. The VPCs can be in different regions (also known as an inter-region VPC peering connection).
  - For peering to work, address space between VPCs cannot overlap.
  - Additional details on VPC peering can be found here: https://docs.aws.amazon.com/vpc/latest/peering/what-is-vpc-peering.html
- Flat pod networking
  - With Amazon VPC Container Networking Interface (CNI), every pod gets an IP address from the subnet and can be accessed directly. 
  - These IP addresses must be unique across your network space. 
  - Each node can support upto a certain number of pods as defined here: https://github.com/awslabs/amazon-eks-ami/blob/master/files/eni-max-pods.txt 
  - The equivalent number of IP addresses per node are then reserved up front for that node.
  - With Amazon VPC CNI, pods do not require a separate address space.
  - Additional details on Amazon VPC CNI can be found here: https://docs.aws.amazon.com/eks/latest/userguide/pod-networking.html
- CoreDNS
  - each region cluster’s CoreDNS servers are exposed via a Load Balancer to other region clusters.
  - each region cluster to regard the other region clusters' CoreDNSes as authoritative for domains it doesn't recognize
    - In particular, CoreDNS in the East cluster is configured for the Load Balancer IP of the West cluster’s CoreDNS to
    be the authoritative nameserver for the west.svc.cluster.local domain, and likewise for all pairs of regions.
- 
- Firewall rules
  - At minimum: allow TCP traffic on the standard ZooKeeper, Kafka and SchemaRegistry ports between all region clusters' Pod subnetworks.

In this section, you'll configure the required networking between three Elastic Kubernetes Service (EKS) clusters, where 
each EKS cluster is in a different AWS region.

export TUTORIAL_HOME=<Tutorial directory>/hybrid/multi-region-clusters

## Create clusters

Spin up the EKS clusters in 3 regions (central, east and west) as documented here: https://docs.aws.amazon.com/eks/latest/userguide/getting-started-console.html

```
# Connect to the cluster in central and set the kubectl context so you can refer to it
aws eks update-kubeconfig --region ca-central-1 --name mrc-central --alias mrc-central
```

```
# Connect to the cluster in east and set the kubectl context so you can refer to it
aws eks update-kubeconfig --region us-east-2 --name mrc-east --alias mrc-east
```

```
# Connect to the cluster in west and set the kubectl context so you can refer to it
aws eks update-kubeconfig --region us-west-2 --name mrc-west --alias mrc-west
```

## Create namespaces

You'll create two namespaces, one in each Kubernetes cluster.

```
kubectl create ns central --context mrc-central

kubectl create ns east --context mrc-east

kubectl create ns west --context mrc-west
```

## Setup VPC Peering
You'll need to set up VPC peering between the three regions for pods to communicate across three separate Kubernetes clusters.
Follow the AWS doc to set up VPC peering as outlined here: https://docs.aws.amazon.com/vpc/latest/peering/create-vpc-peering-connection.html

In addition, you'll also need to update the route tables in your VPC subnets to send private IPv4 traffic from your pod to a pod 
in a different Kubernetes cluster running in the peered VPC. Follow the AWS doc to update the route tables: 
https://docs.aws.amazon.com/vpc/latest/peering/vpc-peering-routing.html

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
kubectl run --image=alpine:3.5 -it alpine-shell -n central --context mrc-central
# Exit out of the shell session
/ # exit

# Get the IP address
kubectl describe pod alpine-shell -n central --context mrc-central
...
IP:           10.124.0.5
...
```

Start a Linux container in the `east` region and ping the container in the `west` region

```
kubectl run --image=alpine:3.5 -it alpine-shell -n east --context mrc-east

# Ping the `west` container IP address
/ # ping 10.124.0.5
PING 10.124.0.5 (10.124.0.5): 56 data bytes
64 bytes from 10.124.0.5: seq=0 ttl=62 time=66.117 ms
64 bytes from 10.124.0.5: seq=1 ttl=62 time=65.020 ms
...
```

If you see a successful ping result like above, then the networking setup is done correctly.