# Configure Networking: Elastic Kubernetes Service

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
  - Each node can support up to a certain number of pods as defined here: https://github.com/awslabs/amazon-eks-ami/blob/master/files/eni-max-pods.txt
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

`export TUTORIAL_HOME=<Tutorial directory>/hybrid/multi-region-clusters/internal-listeners`

## Create clusters

Spin up the EKS clusters in 3 regions (central, east and west) as documented here: https://docs.aws.amazon.com/eks/latest/userguide/getting-started-console.html


**CoreDNS**: Make sure to have self-managed CodeDNS add-on as opposed to Amazon EKS managed add-on since the add-on managed 
by EKS won't allow us to override the Corefile. If installed as an Amazon EKS managed add-on, follow the guide here to 
make it a self-managed add-on: https://docs.aws.amazon.com/eks/latest/userguide/managing-coredns.html#removing-coredns-eks-add-on

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

### Install the AWS Load Balancer Controller add-on
The AWS Load Balancer Controller manages the AWS Elastic Load Balancers for a Kubernetes cluster. The controller provisions
an AWS Network Load Balancer (NLB) when you create a Kubernetes service of type LoadBalancer. Follow the AWS doc to install 
the Load Balancer Controller add-on: https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html 

### Create a load balancer to access CoreDNS in each Kubernetes cluster
```
kubectl apply -f $TUTORIAL_HOME/networking/eks/dns-lb.yaml --context mrc-west

kubectl apply -f $TUTORIAL_HOME/networking/eks/dns-lb.yaml --context mrc-east

kubectl apply -f $TUTORIAL_HOME/networking/eks/dns-lb.yaml --context mrc-central
```

### Determine the loadBalancer ingress for each CoreDNS LoadBalancer
```
# For central region
kubectl get svc kube-dns-lb --namespace kube-system -o jsonpath='{.status.loadBalancer.ingress}' --context mrc-central

[{"hostname":"k8s-kubesyst-kubednsl-29c7e5470a-dd9bdd1bf4b464fe.elb.ca-central-1.amazonaws.com"}]
```

```
# For east region
kubectl get svc kube-dns-lb --namespace kube-system -o jsonpath='{.status.loadBalancer.ingress}' --context mrc-east

[{"hostname":"k8s-kubesyst-kubednsl-03e8facfed-b041e455f96a15ec.elb.us-east-2.amazonaws.com"}]
```

```
# For west region
kubectl get svc kube-dns-lb --namespace kube-system -o jsonpath='{.status.loadBalancer.ingress}' --context mrc-west

[{"hostname":"k8s-kubesyst-kubednsl-44b2adc140-16aa661d24a0790c.elb.us-west-2.amazonaws.com"}]
```

### Lookup the IP address(es) mapped to the LoadBalancer DNS names
```
dig k8s-kubesyst-kubednsl-29c7e5470a-dd9bdd1bf4b464fe.elb.us-west-1.amazonaws.com

...

;; ANSWER SECTION:
k8s-kubesyst-kubednsl-29c7e5470a-dd9bdd1bf4b464fe.elb.ca-central-1.amazonaws.com. 60 IN A 10.0.5.225

...
```

```
dig k8s-kubesyst-kubednsl-03e8facfed-b041e455f96a15ec.elb.us-east-2.amazonaws.com

...

;; ANSWER SECTION:
k8s-kubesyst-kubednsl-03e8facfed-b041e455f96a15ec.elb.us-east-2.amazonaws.com. 60 IN A 10.0.100.177

...
```

```
dig k8s-kubesyst-kubednsl-44b2adc140-16aa661d24a0790c.elb.us-west-2.amazonaws.com

...

;; ANSWER SECTION:
k8s-kubesyst-kubednsl-44b2adc140-16aa661d24a0790c.elb.us-west-2.amazonaws.com. 60 IN A 10.0.118.91

...
```

### Configure CoreDNS ConfigMap

Configure each cluster's DNS configuration with entries for the two other cluster's DNS load
balancer endpoints. In each region, don't include the endpoint for the region's own load balancer,
to protect against infinite recursion in DNS resolutions.
```
# For central cluster 

# coredns-configmap-central.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
    east.svc.cluster.local:53 {
        errors
        cache 30
        forward . 10.0.100.177 {
          force_tcp
        }
        reload
    }
    west.svc.cluster.local:53 {
        errors
        cache 30
        forward . 10.0.118.91 {
          force_tcp
        }
        reload
    }

kubectl apply -f $TUTORIAL_HOME/networking/eks/coredns-configmap-central.yaml --context mrc-central

kubectl rollout restart deployment/coredns -n kube-system --context mrc-central
```

```
# For east cluster

# coredns-configmap-east.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
    central.svc.cluster.local:53 {
        errors
        cache 30
        forward . 10.0.5.225 {
          force_tcp
        }
        reload
    }
    west.svc.cluster.local:53 {
        errors
        cache 30
        forward . 10.0.118.91 {
          force_tcp
        }
        reload
    }

kubectl apply -f $TUTORIAL_HOME/networking/eks/coredns-configmap-east.yaml --context mrc-east

kubectl rollout restart deployment/coredns -n kube-system --context mrc-east
```

```
# For west cluster

# coredns-configmap-west.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
    central.svc.cluster.local:53 {
        errors
        cache 30
        forward . 10.0.5.225 {
          force_tcp
        }
        reload
    }
    east.svc.cluster.local:53 {
        errors
        cache 30
        forward . 10.0.100.177 {
          force_tcp
        }
        reload
    }

kubectl apply -f $TUTORIAL_HOME/networking/eks/coredns-configmap-west.yaml --context mrc-west

kubectl rollout restart deployment/coredns -n kube-system --context mrc-west
```

## Update security groups

For each Kubernetes cluster, update its security group's inbound rules to allow traffic originating from other Kubernetes 
clusters.

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
