# Configure Networking: Azure Kubernetes Service

This is the architecture you'll achieve on Azure Kubernetes Service (AKS):

- Namespace naming
  - 1 uniquely named namespace in each region cluster
    - For example: east namespace in the East cluster, central namespace in Central, and west in West
- Vnet Peering
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
  - an internal load balancer will suffice since the traffic is routed through Microsoft's private network.
  - each region cluster to regard the other region clusters' CoreDNSes as authoritative for domains it doesn't recognize
    - In particular, CoreDNS in the East cluster is configured for the Load Balancer IP of the West cluster’s CoreDNS to
    be the authoritative nameserver for the west.svc.cluster.local domain, and like wise for all pairs of regions.

- Firewall rules
  - At minimum: allow TCP traffic on the standard Zookeeper, Kafka and SchemaRegistry ports between all region clusters' Pod subnetworks.

In this section, you'll configure the required networking between three Azure Kubernetes Service (AKS) clusters, where 
each AKS cluster is in a different Azure region.

`export TUTORIAL_HOME=<Tutorial directory>/hybrid/multi-region-clusters/internal-listeners`

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

You'll create three namespaces, one in each Kubernetes cluster.

```
kubectl create ns west --context mrc-west

kubectl create ns east --context mrc-east

kubectl create ns central --context mrc-central
```

## Set up vnet Peering

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

### Validate VPC connectivity and DNS forwarding
You'll validate that the networking is set up correctly by pinging across regions on the local Kubernetes network.
Run the `network_test.sh` script that validates the network connectivity between regions and also checks the DNS forwarding.

```
$TUTORIAL_HOME/networking/network-test/network_test.sh
Creating test pods to run network tests
statefulset.apps/busybox created
service/busybox created
statefulset.apps/busybox created
service/busybox created
statefulset.apps/busybox created
service/busybox created

Getting pod IPs of the test pods

Testing connectivity from central to east
PING 10.0.102.90 (10.0.102.90): 56 data bytes
64 bytes from 10.0.102.90: seq=0 ttl=253 time=51.456 ms
64 bytes from 10.0.102.90: seq=1 ttl=253 time=52.039 ms
64 bytes from 10.0.102.90: seq=2 ttl=253 time=51.439 ms

--- 10.0.102.90 ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 51.439/51.644/52.039 ms

Testing connectivity from central to west
PING 10.0.115.11 (10.0.115.11): 56 data bytes
64 bytes from 10.0.115.11: seq=0 ttl=253 time=23.062 ms
64 bytes from 10.0.115.11: seq=1 ttl=253 time=20.685 ms
64 bytes from 10.0.115.11: seq=2 ttl=253 time=20.757 ms

--- 10.0.115.11 ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 20.685/21.501/23.062 ms

Testing connectivity from east to central
PING 10.0.1.144 (10.0.1.144): 56 data bytes
64 bytes from 10.0.1.144: seq=0 ttl=253 time=51.517 ms
64 bytes from 10.0.1.144: seq=1 ttl=253 time=51.414 ms
64 bytes from 10.0.1.144: seq=2 ttl=253 time=51.412 ms

--- 10.0.1.144 ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 51.412/51.447/51.517 ms

Testing connectivity from east to west
PING 10.0.115.11 (10.0.115.11): 56 data bytes
64 bytes from 10.0.115.11: seq=0 ttl=253 time=48.651 ms
64 bytes from 10.0.115.11: seq=1 ttl=253 time=48.629 ms
64 bytes from 10.0.115.11: seq=2 ttl=253 time=48.564 ms

--- 10.0.115.11 ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 48.564/48.614/48.651 ms

Testing connectivity from west to central
PING 10.0.1.144 (10.0.1.144): 56 data bytes
64 bytes from 10.0.1.144: seq=0 ttl=253 time=21.792 ms
64 bytes from 10.0.1.144: seq=1 ttl=253 time=21.799 ms
64 bytes from 10.0.1.144: seq=2 ttl=253 time=21.778 ms

--- 10.0.1.144 ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 21.778/21.789/21.799 ms

Testing connectivity from west to east
PING 10.0.102.90 (10.0.102.90): 56 data bytes
64 bytes from 10.0.102.90: seq=0 ttl=253 time=52.256 ms
64 bytes from 10.0.102.90: seq=1 ttl=253 time=52.268 ms
64 bytes from 10.0.102.90: seq=2 ttl=253 time=52.240 ms

--- 10.0.102.90 ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 52.240/52.254/52.268 ms

Testing Kubernetes DNS setup
Testing DNS forwarding from central to east
PING busybox-0.busybox.east.svc.cluster.local (10.0.102.90): 56 data bytes
64 bytes from 10.0.102.90: seq=0 ttl=253 time=51.470 ms
64 bytes from 10.0.102.90: seq=1 ttl=253 time=51.553 ms
64 bytes from 10.0.102.90: seq=2 ttl=253 time=51.498 ms

--- busybox-0.busybox.east.svc.cluster.local ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 51.470/51.507/51.553 ms

Testing DNS forwarding from central to west
PING busybox-0.busybox.west.svc.cluster.local (10.0.115.11): 56 data bytes
64 bytes from 10.0.115.11: seq=0 ttl=253 time=21.287 ms
64 bytes from 10.0.115.11: seq=1 ttl=253 time=21.370 ms
64 bytes from 10.0.115.11: seq=2 ttl=253 time=21.371 ms

--- busybox-0.busybox.west.svc.cluster.local ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 21.287/21.342/21.371 ms

Testing DNS forwarding from east to central
PING busybox-0.busybox.central.svc.cluster.local (10.0.1.144): 56 data bytes
64 bytes from 10.0.1.144: seq=0 ttl=253 time=51.468 ms
64 bytes from 10.0.1.144: seq=1 ttl=253 time=51.618 ms
64 bytes from 10.0.1.144: seq=2 ttl=253 time=51.523 ms

--- busybox-0.busybox.central.svc.cluster.local ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 51.468/51.536/51.618 ms

Testing DNS forwarding from east to west
PING busybox-0.busybox.west.svc.cluster.local (10.0.115.11): 56 data bytes
64 bytes from 10.0.115.11: seq=0 ttl=253 time=54.530 ms
64 bytes from 10.0.115.11: seq=1 ttl=253 time=54.565 ms
64 bytes from 10.0.115.11: seq=2 ttl=253 time=54.516 ms

--- busybox-0.busybox.west.svc.cluster.local ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 54.516/54.537/54.565 ms

Testing DNS forwarding from west to central
PING busybox-0.busybox.central.svc.cluster.local (10.0.1.144): 56 data bytes
64 bytes from 10.0.1.144: seq=0 ttl=253 time=22.126 ms
64 bytes from 10.0.1.144: seq=1 ttl=253 time=21.782 ms
64 bytes from 10.0.1.144: seq=2 ttl=253 time=21.825 ms

--- busybox-0.busybox.central.svc.cluster.local ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 21.782/21.911/22.126 ms

Testing DNS forwarding from west to east
PING busybox-0.busybox.east.svc.cluster.local (10.0.102.90): 56 data bytes
64 bytes from 10.0.102.90: seq=0 ttl=253 time=51.783 ms
64 bytes from 10.0.102.90: seq=1 ttl=253 time=50.696 ms
64 bytes from 10.0.102.90: seq=2 ttl=253 time=50.671 ms

--- busybox-0.busybox.east.svc.cluster.local ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 50.671/51.050/51.783 ms

Test complete. Deleting test pods
statefulset.apps "busybox" deleted
service "busybox" deleted
statefulset.apps "busybox" deleted
service "busybox" deleted
statefulset.apps "busybox" deleted
service "busybox" deleted
```
With this, the network setup is complete.
