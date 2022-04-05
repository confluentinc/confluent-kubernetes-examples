Configure Rack Awareness
=========================

In this workflow scenario, you'll deploy Confluent Platform to a multi-zone Kubernetes cluster, with Kafka rack awareness configured.

Each zone will be treated as a rack. Kafka brokers will be round-robin scheduled across the zones. 
Each Kafka broker will be configured with it's broker.rack setting to the corresponding zone it's scheduled on.

Read more about Kafka rack awareness: `Confluent Docs <https://docs.confluent.io/platform/current/kafka/post-deployment.html#balancing-replicas-across-racks>`__.

Before continuing with the scenario, ensure that you have set up the
`prerequisites </README.md#prerequisites>`_.

==================================
Set the current tutorial directory
==================================

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

::
   
  export TUTORIAL_HOME=<Tutorial directory>/rackawareness

===========================================================
Pre-requisites: Node Labels and Service Account Rolebinding
===========================================================

The Kubernetes cluster must have node labels set for the fault domain. The nodes in each zone should have the same node label.

Note that Kubernetes v1.17 and newer use label ``topology.kubernetes.io/zone``. Older versions use the ``failure-domain.beta.kubernetes.io/zone`` label instead.


#. Check the Node Labels for ``topology.kubernetes.io/zone``:

   ::

    kubectl get node \
     -o=custom-columns=NODE:.metadata.name,ZONE:.metadata.labels."topology\.kubernetes\.io/zone" \
       | sort -k2


#. Configure your Kubernetes cluster with a service account that is configured with a clusterrole/role that provides get/list access to both the pods and nodes resources. This is required as Kafka pods will curl kubernetes api for the node it is scheduled on using the mounted serviceAccountToken.

   ::

     kubectl apply -f $TUTORIAL_HOME/service-account-rolebinding.yaml

===============================
Deploy Confluent for Kubernetes
===============================

#. Set up the Helm Chart:

   ::

     helm repo add confluentinc https://packages.confluent.io/helm


#. Install Confluent For Kubernetes using Helm:

   ::

     helm upgrade --install operator confluentinc/confluent-for-kubernetes
  
#. Check that the Confluent For Kubernetes pod comes up and is running:

   ::
     
     kubectl get pods

=======================================
Configure and Deploy Confluent Platform
=======================================

#. Configure rack awareness - see the example file `rackawareness/confluent-platform.yaml`

   ::

     ...
     kind: Kafka
     ...
     spec:
       replicas: 6
       rackAssignment:
         nodeLabels:
         - topology.kubernetes.io/zone # <-- The node label that your Kubernetes uses for the rack fault domain
       podTemplate:
        serviceAccountName: kafka # <-- The service account with the needed clusterrole/role
       oneReplicaPerNode: true # <-- Ensures that only one Kafka broker per node is scheduled
       ...

#. Deploy the Confluent Platform

   ::

     kubectl apply -f $TUTORIAL_HOME/confluent-platform.yaml

#. Check that all Confluent Platform resources are deployed:

   ::
   
     kubectl get confluent

#. Get the status of any component. For example, to check Kafka:

   ::
   
     kubectl describe kafka

============================
Check Pod and Rack Placement
============================

With rack awareness enabled, broker pods will be scheduled so
there is one broker per node, and at the Kafka layer, Kafka will
make smart decisions about where to place data for maximum fault tolerance.
For example, Kafka will avoid placing all replicas for a partition on brokers
in the same zone.

#. Check the Node labels for ``topology.kubernetes.io/zone`` again:

   ::

    kubectl get node \
     -o=custom-columns=NODE:.metadata.name,ZONE:.metadata.labels."topology\.kubernetes\.io/zone" \
       | sort -k2

#. Check that the ``broker.rack`` property has been set inside broker 0.

   ::
    
     kubectl exec -it kafka-0 -- \
       grep 'broker.rack' confluentinc/etc/kafka/kafka.properties

#. Verify that there is only one broker per node.

   ::

     kubectl get pod \
       -o=custom-columns=NODE:.spec.nodeName,NAME:.metadata.name \
         | grep kafka | sort
      
