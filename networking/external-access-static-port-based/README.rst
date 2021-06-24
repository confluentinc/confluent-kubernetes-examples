Deploy Confluent Platform with Static Port-based Routing
========================================================

In this scenario workflow, you'll set up Confluent Platform component clusters
with the static port-based routing to enable external clients to access Kafka.

Before continuing with the scenario, ensure that you have set up the
`prerequisites </README.md#prerequisites>`_.

To complete this tutorial, you'll follow these steps:

#. Set up the Kubernetes cluster for this tutorial.

#. Set the current tutorial directory.

#. Deploy Confluent For Kubernetes.

#. Deploy Confluent Platform.

#. Deploy the producer application.

#. Tear down Confluent Platform.

===========================
Set up a Kubernetes cluster
===========================

Set up a Kubernetes cluster for this tutorial, and save the Kubernetes cluster
domain name. 
 
In this document, ``$DOMAIN`` will be used to denote your Kubernetes cluster
domain name.
  
::

  export DOMAIN=<Your Kubernetes cluster domain name>

==================================
Set the current tutorial directory
==================================

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

::
   
  export TUTORIAL_HOME=<Tutorial directory>/external-access-static-port-based

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

In this tutorial, you will configure Zookeeper, Kafka, and Control Center in a
single file and deploy the components with one ``kubectl apply`` command.

The CR configuration file contains a custom resource specification for each
Confluent Platform component, including replicas, image to use, resource
allocations.

Edit the Confluent Platform CR file: ``$TUTORIAL_HOME/confluent-platform.yaml``

Specifically, note that external accesses to Confluent Platform components are
configured using port-based static routing.

The Kafka section of the file is set as follow for external access:

:: 

  Spec:
    listeners:
      external:
        externalAccess:
          type: staticForPortBasedRouting
          staticForPortBasedRouting:
            host: myoperator2.<Kubernetes domain>   --- [1]
            portOffset: 9094
        tls:
          enabled: true

* [1] Set this to the value of ``myoperator2.$DOMAIN`` where ``$DOMAIN`` is your Kubernetes cluster domain name.

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
     
=========================
Deploy Ingress controller
=========================

An Ingress controller is required to access Kafka using the static port-based
routing. In this tutorial, we will use Nginx Ingress controller.

#. Clone the Nginx Github repo:

   ::
   
     git clone https://github.com/helm/charts/tree/master/stable/nginx-ingress

#. Install the Ngix controller:

   ::
   
      helm upgrade --install nginx-operator stable/nginx-ingress \
        --set controller.ingressClass=kafka \
        --set tcp.9094="operator/kafka-0-internal:9092" \
        --set tcp.9095="operator/kafka-1-internal:9092" \
        --set tcp.9096="operator/kafka-2-internal:9092" \
        --set tcp.9093="operator/kafka-bootstrap:9092"
       
================================
Create a Kafka bootstrap service
================================

When using staticForPortBasedRouting as externalAccess type, the bootstrap
endpoint is not configured to access Kafka. 

If you want to have a bootstrap endpoint to access Kafka instead of using each
broker's endpoint, you need to provide the bootstrap endpoint, create a
DNS record pointing to Ingress controller load balancer's external IP, and
define the Ingress rule for it.

Create the Kafka bootstrap service to access Kafka:

::

  kubectl apply -f $TUTORIAL_HOME/kafka-bootstrap-service.yaml
  
Note that this bootstrap service will use the port 9093 as set using the ``--set
tcp.9093="operator/kafka-bootstrap:9092"`` flag while installing the Ingress
controller in the previous section. 

======================  
Create Ingress service
======================

Create an Ingress resource that includes a collection of rules that the Ingress
control uses to route the inbound traffic to Kafka:

#. In the resource file, ``ingress-service-portbased.yaml``, replace 
   ``<Kubernetes cluster domain>`` with the value of your ``$DOMAIN``.

#. Create the Ingress resource:

   ::

     kubectl apply -f $TUTORIAL_HOME/ingress-service-portbased.yaml

===============
Add DNS records
===============

Create a DNS records for Kafka using the Ingress controller load balancer externalIP.

#. Retrieve the external IP addresses of Nginx load balancer:

   ::
   
     kubectl get svc
     
#. Add a DNS record for Kafka, replacing ``$DOMAIN`` with the actual domain name 
   of your Kubernetes cluster:
   
   ::
   
     DNS name              IP Address
     -------------------   -----------------------------------------
   
     myoperator2.$DOMAIN   Nginx controller load balancer externalIP
  
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

In a single configuration file, you do all of the following:

* Provide client credentials.

  Create a Kubernetes secret with the ``kafka.properties`` file.
  
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
   
     echo bootstrap.servers=myoperator2.$DOMAIN:9093 | base64

#. Provide the output from the previous step in the 
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

#. Set up port forwarding to Control Center web UI from local machine:

   ::

     kubectl port-forward controlcenter-0 9021:9021

#. Browse to `Control Center <http://localhost:9021>`__.

#. Check that the ``elastic-0`` topic was created and that messages are being produced to the topic.

=========
Tear Down
=========

Shut down Confluent Platform and the data:

::

  kubectl delete -f $TUTORIAL_HOME/producer-app-data.yaml
  
::

  kubectl delete -f $TUTORIAL_HOME/ingress-service-portbased.yaml
  
::

  kubectl delete -f $TUTORIAL_HOME/kafka-bootstrap-service.yaml

::

  kubectl delete -f $TUTORIAL_HOM/confluent-platform.yaml
    
::

  helm delete nginx-operator

::

  helm delete operator
  
