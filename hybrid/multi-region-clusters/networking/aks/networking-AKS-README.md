# Configure Networking: Azure Kubernetes Service

This is the architecture you'll achieve on Azure Kubernetes Service (AKS):

- Namespace naming
  - 1 uniquely named namespace in each region cluster
    - For example: east namespace in the East cluster, central namespace in Central, and west in West
- Vnet Peering (optional)
  - In this approach, we peer the vnets in the different regions. This makes the virtual networks appear as one for 
  connectivity purposes. The traffic between virtual machines in peered virtual networks uses the Microsoft backbone 
  infrastructure. Like traffic between virtual machines in the same network, traffic is routed through Microsoft's 
  private network only.
  - For peering to work, address space between vnets cannot overlap.
  - Additional details on vnet peering can be found here: https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-peering-overview
- Flat pod networking
  - Using kubenet
    - By default, AKS clusters use kubenet, and an Azure virtual network and subnet are created for you. 
    - With kubenet, nodes get an IP address from the Azure virtual network subnet. 
    - Pods receive an IP address from a logically different address space to the Azure virtual network subnet of the nodes.
    - Network address translation (NAT) is then configured so that the pods can reach resources on the Azure virtual network. 
    - The source IP address of the traffic is NAT'd to the node's primary IP address. 
    - This approach greatly reduces the number of IP addresses that you need to reserve in your network space for pods to use.
    - Pod IP range from separate clusters must not overlap
    - Pod IPs must be routable between Kubernetes clusters. We make this possible by making changes to the CoreDNS as outlined below.
    - Additional details on kubenet can be found here: https://docs.microsoft.com/en-us/azure/aks/configure-kubenet
  - Using Azure CNI
    - With Azure Container Networking Interface (CNI), every pod gets an IP address from the subnet and can be accessed directly. 
    - These IP addresses must be unique across your network space. 
    - Each node has a configuration parameter for the maximum number of pods that it supports. 
    - The equivalent number of IP addresses per node are then reserved up front for that node.
    - With Azure CNI, pods do not require a separate address space.
    - Additional details on Azure CNI can be found here: https://docs.microsoft.com/en-us/azure/aks/configure-azure-cni
- CoreDNS
  - each region cluster’s CoreDNS servers exposed via a Load Balancer to other region clusters.
  - If vnet peering is configured, an internal load balancer will suffice since the traffic is routed through Microsoft's private network.
  - If vnet peering is not configured, an external load balancer is required for each region's CoreDNS.
  - each region cluster to regard the other region clusters' CoreDNSes as authoritative for domains it doesn't recognize
    - In particular, CoreDNS in the East cluster is configured for the Load Balancer IP of the West cluster’s CoreDNS to
    be the authoritative nameserver for the west.svc.cluster.local domain, and like wise for all pairs of regions.

- Firewall rules
  - At minimum: allow TCP traffic on the standard ZooKeeper and Kafka ports between all region clusters' Pod subnetworks.

In this section, you'll configure the required networking between three Azure Kubernetes Service (AKS) clusters, where 
each AKS cluster is in a different Azure region.

export TUTORIAL_HOME=<Tutorial directory>/hybrid/early-access-multi-region-clusters

## AKS variables

```
# Define resource group
rg="aks-rg"
clus1="mrc-centralus"
clus2="mrc-eastus"
clus3="mrc-westus"
loc1="centralus"
loc2="eastus"
loc3="westus"
```

## Create clusters

Spin up the AKS clusters. Add `--network-plugin=azure` if using Azure CNI.

```
# Spin up a cluster in centralus
az aks create -g aks-rg -n mrc-central -l centralus
```

```
# Spin up a cluster in eastus
az aks create -g aks-rg -n mrc-east -l eastus
```

```
# Spin up a cluster in westus
az aks create -g aks-rg -n mrc-west -l westus
```

## Create namespaces

You'll create two namespaces, one in each Kubernetes cluster.

```
kubectl create ns west --context mrc-west

kubectl create ns east --context mrc-east

kubectl create ns central --context mrc-central
```

## Set up vnet Peering (Optional)

Configure vnet peering between the regions.

```
# central-east peer
az network vnet peering create -g aks-rg -n centralus-eastus-peer --vnet-name mrc-central-vnet --remote-vnet mrc-east-vnet \
  --allow-vnet-access --allow-forwarded-traffic --allow-gateway-transit

# central-west peer  
az network vnet peering create -g aks-rg -n centralus-westus-peer --vnet-name mrc-central-vnet --remote-vnet mrc-west-vnet \
  --allow-vnet-access --allow-forwarded-traffic --allow-gateway-transit

# east-central peer  
az network vnet peering create -g aks-rg -n eastus-centralus-peer --vnet-name mrc-east-vnet --remote-vnet mrc-central-vnet \
  --allow-vnet-access --allow-forwarded-traffic --allow-gateway-transit

# east-west peer  
az network vnet peering create -g aks-rg -n eastus-westus-peer --vnet-name mrc-east-vnet --remote-vnet mrc-west-vnet \
  --allow-vnet-access --allow-forwarded-traffic --allow-gateway-transit

# west-central peer  
az network vnet peering create -g aks-rg -n westus-centralus-peer --vnet-name mrc-west-vnet --remote-vnet mrc-central-vnet \
  --allow-vnet-access --allow-forwarded-traffic --allow-gateway-transit

# west-east peer  
az network vnet peering create -g aks-rg -n westus-eastus-peer --vnet-name mrc-west-vnet --remote-vnet mrc-east-vnet \
  --allow-vnet-access --allow-forwarded-traffic --allow-gateway-transit
```

## Set up DNS

### Create a load balancer to access CoreDNS in each Kubernetes cluster

If vnet peering is configured, internal load balancers will suffice, otherwise, external load balancers will need to be created.
```
kubectl apply -f $TUTORIAL_HOME/networking/aks/dns-lb.yaml --context mrc-central

kubectl apply -f $TUTORIAL_HOME/networking/aks/dns-lb.yaml --context mrc-east

kubectl apply -f $TUTORIAL_HOME/networking/aks/dns-lb.yaml --context mrc-west
```

### Determine the External IP address for each CoreDNS load balancer

```
# For Central region
kubectl get svc kube-dns-lb --namespace kube-system --context mrc-central

NAME          TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)        AGE
kube-dns-lb   LoadBalancer   10.0.14.129   10.0.16.4     53:30904/UDP   104s
```

```
# For East region
kubectl get svc kube-dns-lb --namespace kube-system --context mrc-east

NAME          TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)        AGE
kube-dns-lb   LoadBalancer   10.0.20.210   10.0.24.4     53:31197/UDP   4m49s
```

```
# For West region
kubectl get svc kube-dns-lb --namespace kube-system --context mrc-west

NAME          TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)        AGE
kube-dns-lb   LoadBalancer   10.0.24.252   10.0.32.4     53:30288/UDP   5m7s
```

### Configure cluster DNS configmap

Configure each cluster's DNS configuration with entries for the two other cluster's DNS load balancer endpoints. 
In each region, don't include the endpoint for the region's own load balancer to protect against infinite recursion in DNS resolutions.

```
# For Central cluster

# coredns-configmap-central.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  kubernetes.stretch.server: |
    east.svc.cluster.local:53 {
      errors
      cache 30
      forward . 10.0.24.4
    }
    west.svc.cluster.local:53 {
      errors
      cache 30
      forward . 10.0.32.4
    }

kubectl apply -f $TUTORIAL_HOME/networking/aks/coredns-configmap-central.yaml --context mrc-central
```

```
# For East cluster

# coredns-configmap-east.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  kubernetes.stretch.server: |
    central.svc.cluster.local:53 {
      errors
      cache 30
      forward . 10.0.16.4
    }
    west.svc.cluster.local:53 {
      errors
      cache 30
      forward . 10.0.32.4
    }

kubectl apply -f $TUTORIAL_HOME/networking/aks/coredns-configmap-east.yaml --context mrc-east
```

```
# For West cluster

# coredns-configmap-west.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  kubernetes.stretch.server: |
    central.svc.cluster.local:53 {
      errors
      cache 30
      forward . 10.0.16.4
    }
    east.svc.cluster.local:53 {
      errors
      cache 30
      forward . 10.0.24.4
    }

kubectl apply -f $TUTORIAL_HOME/networking/aks/coredns-configmap-west.yaml --context mrc-west
```

## Validate networking setup

You'll validate that the networking is set up correctly by pinging across regions on the local
Kubernetes network.

Start a Linux container in the `centralus` region and check the IP address for this pod

```
kubectl run network-test --image=alpine --restart=Never -n central --context mrc-central -- sleep 999
# Exit out of the shell session
/ # exit

# Get the IP address
kubectl describe pod network-test -n central --context mrc-central
...
IP:           10.124.0.5
...
```

Start a Linux container in the `eastus` region and ping the container in the `central` region

```
kubectl run -it network-test --image=alpine --restart=Never -n east --context mrc-east -- ping 10.124.0.5

# Ping the `east` container IP address
/ # ping 10.124.0.5
PING 10.124.0.5 (10.124.0.5): 56 data bytes
64 bytes from 10.124.0.5: seq=0 ttl=62 time=66.117 ms
64 bytes from 10.124.0.5: seq=1 ttl=62 time=65.020 ms
...
```

If you see a successful ping result like above, then the networking setup is done correctly. Delete the pods.

```
kubectl delete pod network-test -n central --context mrc-central

kubectl delete pod network-test -n east --context mrc-east
```