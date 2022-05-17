#!/bin/bash
# Flat pod networking test

# shellcheck disable=SC2128
#TUTORIAL_HOME=$(dirname "$BASH_SOURCE")

# Apply the yamls to create busybox test pods on all the clusters
echo "Creating test pods to run network tests"
kubectl apply -f "$TUTORIAL_HOME"/networking/network-test/busybox-central.yaml --context mrc-central
kubectl apply -f "$TUTORIAL_HOME"/networking/network-test/busybox-east.yaml --context mrc-east
kubectl apply -f "$TUTORIAL_HOME"/networking/network-test/busybox-west.yaml --context mrc-west

# Get the busybox pod IPs from all the clusters
printf "\nGetting pod IPs of the test pods\n"
sleep 10
centralIP=$(kubectl get po busybox-0 -n central -o jsonpath='{.status.podIP}' --context mrc-central)
eastIP=$(kubectl get po busybox-0 -n east -o jsonpath='{.status.podIP}' --context mrc-east)
westIP=$(kubectl get po busybox-0 -n west -o jsonpath='{.status.podIP}' --context mrc-west)

printf "\nTesting connectivity from central to east\n"
kubectl exec -it busybox-0 -n central --context mrc-central -- ping -c 3 "$eastIP"

printf "\nTesting connectivity from central to west\n"
kubectl exec -it busybox-0 -n central --context mrc-central -- ping -c 3 "$westIP"

printf "\nTesting connectivity from east to central\n"
kubectl exec -it busybox-0 -n east --context mrc-east -- ping -c 3 "$centralIP"

printf "\nTesting connectivity from east to west\n"
kubectl exec -it busybox-0 -n east --context mrc-east -- ping -c 3 "$westIP"

printf "\nTesting connectivity from west to central\n"
kubectl exec -it busybox-0 -n west --context mrc-west -- ping -c 3 "$centralIP"

printf "\nTesting connectivity from west to east\n"
kubectl exec -it busybox-0 -n west --context mrc-west -- ping -c 3 "$eastIP"

printf "\nTesting Kubernetes DNS setup"
printf "\nTesting DNS forwarding from central to east\n"
kubectl exec -it busybox-0 -n central --context mrc-central -- ping -c 3 busybox-0.busybox.east.svc.cluster.local

printf "\nTesting DNS forwarding from central to west\n"
kubectl exec -it busybox-0 -n central --context mrc-central -- ping -c 3 busybox-0.busybox.west.svc.cluster.local

printf "\nTesting DNS forwarding from east to central\n"
kubectl exec -it busybox-0 -n east --context mrc-east -- ping -c 3 busybox-0.busybox.central.svc.cluster.local

printf "\nTesting DNS forwarding from east to west\n"
kubectl exec -it busybox-0 -n east --context mrc-east -- ping -c 3 busybox-0.busybox.west.svc.cluster.local

printf "\nTesting DNS forwarding from west to central\n"
kubectl exec -it busybox-0 -n west --context mrc-west -- ping -c 3 busybox-0.busybox.central.svc.cluster.local

printf "\nTesting DNS forwarding from west to east\n"
kubectl exec -it busybox-0 -n west --context mrc-west -- ping -c 3 busybox-0.busybox.east.svc.cluster.local

# Delete busybox pods
printf "\nTest complete. Deleting test pods\n"
kubectl delete -f "$TUTORIAL_HOME"/networking/network-test/busybox-central.yaml --context mrc-central
kubectl delete -f "$TUTORIAL_HOME"/networking/network-test/busybox-east.yaml --context mrc-east
kubectl delete -f "$TUTORIAL_HOME"/networking/network-test/busybox-west.yaml --context mrc-west