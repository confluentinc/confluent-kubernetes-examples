Deploy Confluent Platform with NodePort
=======================================

In this scenario workflow, you'll set up Confluent Platform clusters with the
Kubernetes NodePort service type to enable external clients to access Confluent
Platform, including Kafka and other components.

With the NodePort services, Kubernetes will allocate a port on all nodes of the
Kubernetes cluster and will make sure that all traffic to this port is routed to
the pods.

Before continuing with the scenario, ensure that you have set up the
`prerequisites </README.md#prerequisites>`_.

To complete this scenario, you'll follow these steps:

#. Set up the Kubernetes cluster.

#. Set the current tutorial directory.

#. Deploy Confluent For Kubernetes.

#. Deploy Confluent Platform.

#. Deploy the producer application.

#. Tear down Confluent Platform.

===========================
Set up a Kubernetes cluster
===========================

Set up a Kubernetes cluster for this tutorial.

#. Get the Kubernetes cluster domain name. 

   In this document, ``$NPHOST`` will be used to denote the following node port
   hostname, with ``myoperator2`` hard-coded for this tutorial.

   ::
   
     export NPHOST=myoperator2.<Your Kubernetes cluster domain name>

#. Create a firewall rule in your Kubernetes cloud provider to allow the ports used in this tutorial, 30000 through 30500, to be reachable from outside of your Kubernetes cluster.
     
==================================
Set the current tutorial directory
==================================

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

::
   
  export TUTORIAL_HOME=<Tutorial directory>/external-access-nodeport

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
     
============================
Configure Confluent Platform
============================

You install Confluent Platform components as custom resources (CRs). 

You can configure all Confluent Platform components as custom resources. In this
tutorial, you will configure all components in a single file and apply the
configuration with one ``kubectl apply`` command.

The CR configuration file contains a custom resource specification for each
Confluent Platform component, including replicas, image to use, resource
allocations.

Edit the Confluent Platform CR file: ``$TUTORIAL_HOME/confluent-platform.yaml``

Specifically, note that external accesses to Confluent Platform components are
configured using the NodePort services.

The Kafka section of the file is set as follows for node port access:

::

  spec:  
    listeners:
      external:
        externalAccess:
          type: nodePort
          nodePort:
            host:                 --- [1]
            nodePortOffset: 30000 --- [2]

Component section of the confluent-platform.yaml file is set as follows for node port access:

::

  spec:
    externalAccess:
      type: nodePort
      nodePort:
        host:                    --- [1]
        nodePortOffset:          --- [2]

* [1]  Set this to the value of $NPHOST. You need to provide this value for this tutorial.
* [2]  In this tutorial, you will use the ``nodePortOffset`` as specified in ``confluent-platform.yaml``, starting with 30000 for Kafka.

The access endpoint of each Confluent Platform component will be:

$NPHOST:<nodeport offset of the component (as set in ``metadata.name`` in the CR
file)>

For example, you will access Control Center at: 

::

  http://$NPHOST:30200

=========================
Deploy Confluent Platform
=========================

#. Deploy Confluent Platform with the above configuration:

   ::

     kubectl apply -f $TUTORIAL_HOME/confluent-platform.yaml

#. Check that all Confluent Platform resources are deployed:

   ::
   
     kubectl get confluent

#. Get the status of any component. For example, to check Kafka:

   ::
   
     kubectl describe kafka

#. Verify that the NodePort services have been created:

   ::
   
     kubectl get services

===============
Add DNS records
===============

Create DNS records for the externally exposed components:

#. Get the node IP addresses of your cluster. 

   For example, on Google Cloud, use the following command to retrieve you node IPs:

   ::
   
    gcloud compute instances list \
      --project <Google Cloud project id> \
    | grep <your GKE cluster name>

#. Get the node names of your Confluent Platform components:

   ::
   
     kubectl get pods -owide
     
#. Cross-referencing the outputs from Step 1 and Step 2 above, get one of the external IP addresses of your component nodes.

#. Add a DNS record for the components as following:

   * DNS name: myoperator2.<Your Kubernetes cluster domain name>
   
   * IP address: The IP address you got in Step 3.

========
Validate
========

Deploy producer application
^^^^^^^^^^^^^^^^^^^^^^^^^^^

Now that we've got the Confluent Platform set up, let's deploy the producer
client app.

The producer app is packaged and deployed as a pod on Kubernetes. The required
topic is defined as a KafkaTopic custom resource in
``$TUTORIAL_HOME/producer-app-data.yaml``.

In a single CR configuration file, you do all of the following:

* Provide client credentials.
* Deploy the producer app.
* Create a topic for it to write to.

The ``$TUTORIAL_HOME/producer-app-data.yaml`` defines the ``elastic-0`` topic as
follows:

::
  
  apiVersion: platform.confluent.io/v1beta1
  kind: KafkaTopic
  metadata:
    name: elastic-0
    namespace: confluent
  spec:
    replicas: 1
    partitionCount: 1
    configs:
      cleanup.policy: "delete"
      
**To deploy the producer application:**

#. Generate an encrypted ``kafka.properties`` file content:

   ::
   
     echo bootstrap.servers=$NPHOST:30000 | base64
   
#. Provide the output from the previous step for ``kafka.properties`` in the 
   ``$TUTORIAL_HOME/producer-app-data.yaml`` file:

   ::
   
     apiVersion: v1
     kind: Secret
     metadata:
       name: kafka-client-config
       namespace: confluent
     type: Opaque
     data:
       kafka.properties: # Provide the base64-encoded kafka.properties
  
#. Deploy the producer app:

   ::
   
     kubectl apply -f $TUTORIAL_HOME/producer-app-data.yaml

Validate in Control Center
^^^^^^^^^^^^^^^^^^^^^^^^^^

Use Control Center to monitor the Confluent Platform, and see the created topic and data.

#. Browse to Control Center using the external access you set up for Control Center:

   ::
   
     http://$NPHOST:30200

#. Check that the ``elastic-0`` topic was created and that messages are being produced to the topic.

=========
Tear Down
=========

Shut down Confluent Platform and the data:

::

  kubectl delete -f $TUTORIAL_HOME/producer-app-data.yaml

::

  kubectl delete -f $TUTORIAL_HOM/confluent-platform.yaml

::

  helm delete operator
  
