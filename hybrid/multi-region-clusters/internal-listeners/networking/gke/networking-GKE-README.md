# Configure Networking: Google Kubernetes Engine

This is the architecture you'll achieve on Google Kubernetes Engine (GKE):

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

`export TUTORIAL_HOME=<Tutorial directory>/hybrid/multi-region-clusters/internal-listeners`

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
kubectl apply -f $TUTORIAL_HOME/networking/gke/dns-lb.yaml --context mrc-west

kubectl apply -f $TUTORIAL_HOME/networking/gke/dns-lb.yaml --context mrc-east

kubectl apply -f $TUTORIAL_HOME/networking/gke/dns-lb.yaml --context mrc-central
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

kubectl apply -f $TUTORIAL_HOME/networking/gke/dns-configmap-west.yaml --context mrc-west

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

kubectl apply -f $TUTORIAL_HOME/networking/gke/dns-configmap-central.yaml --context mrc-central

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

kubectl apply -f $TUTORIAL_HOME/networking/gke/dns-configmap-east.yaml --context mrc-east

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
