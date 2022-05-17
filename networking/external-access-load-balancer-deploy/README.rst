Deploy Confluent Platform with Load Balancer
============================================

In this scenario workflow, you'll set up Confluent Platform component clusters
with the Kubernetes LoadBalancer service type to enable external clients to
access Confluent Platform, including Kafka and other components.

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

Set up a Kubernetes cluster for this tutorial.

#. Save the Kubernetes cluster domain name. 
 
   In this document, ``$DOMAIN`` is used to denote your Kubernetes cluster
   domain name.
  
   ::

     export DOMAIN=<Your Kubernetes cluster domain name>

#. Create a namespace for the test client to deploy the producer application: 

   ::
   
     kubectl create namespace myclient

==================================
Set the current tutorial directory
==================================

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

::
   
  export TUTORIAL_HOME=<Tutorial directory>/external-access-load-balancer

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
tutorial, you will configure all components in a single file and deploy all
components with one ``kubectl apply`` command.

The CR configuration file contains a custom resource specification for each
Confluent Platform component, including replicas, image to use, resource
allocations.

Edit the Confluent Platform CR file: ``$TUTORIAL_HOME/confluent-platform.yaml``

Specifically, note that external accesses to Confluent Platform components are
configured using the Load Balance services.

The Kafka section of the file is set as follow for load balancer access:

:: 

  Spec:
    listeners:
      external:
        externalAccess:
          type: loadBalancer
          loadBalancer:
            domain:      --- [1]

Component section of the file is set as follows for load balancer access:

::

  spec:
    externalAccess:
      type: loadBalancer
      loadBalancer:
        domain:          --- [1]

* [1]  Set this to the value of ``$DOMAIN``, Your Kubernetes cluster domain. You need to provide this value for this tutorial.

* The prefixes are used for external DNS hostnames. In this tutorial,  Kafka bootstrap server will use the default prefix, ``kafka``, and the brokers will use the default prefix, ``b``. 

Kafka is configured with 3 replicas in this tutorial. So, the access endpoints
of Kafka will be:

* kafka.$DOMAIN for the bootstrap server
* b0.$DOMAIN for the broker #1
* b1.$DOMAIN for the broker #2
* b2.$DOMAIN for the broker #3

The access endpoint of each Confluent Platform component will be: 

::

  <Component CR name>.$DOMAIN

For example, in a brower, you will access Control Center at:

::

  http://controlcenter.$DOMAIN

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

#. Verify that the external Load Balancer services have been created:

   ::
   
     kubectl get services
     
===============
Add DNS records
===============

Create DNS records for the externally exposed components:

#. Retrieve the external IP addresses of bootstrap load balancers of the brokers and components:

   ::
   
     kubectl get svc
     
   Get the ``EXTERNAL-IP`` values of the following services from the output:
   
   * ``connect-bootstrap-lb``          
   * ``controlcenter-bootstrap-lb``   
   * ``kafka-0-lb``               
   * ``kafka-1-lb``                  
   * ``kafka-2-lb``                    
   * ``kafka-bootstrap-lb``          
   * ``ksqldb-bootstrap-lb``           
   * ``schemaregistry-bootstrap-lb`` 

#. Add DNS records for the components and the brokers using the IP addresses and the hostnames above, replacing ``$DOMAIN`` with the actual domain name of your Kubernetes cluster.

   In this tutorial, we are using the default prefixes for components and brokers as shown below:
   
   ====================== ====================================================================
   DNS name               IP address
   ====================== ====================================================================
   kafka.$DOMAIN          The ``EXTERNAL-IP`` value of ``kafka-bootstrap-lb`` service
   b0.$DOMAIN             The ``EXTERNAL-IP`` value of ``kafka-0-lb`` service
   b1.$DOMAIN             The ``EXTERNAL-IP`` value of ``kafka-1-lb`` service
   b2.$DOMAIN             The ``EXTERNAL-IP`` value of ``kafka-2-lb`` service
   controlcenter.$DOMAIN  The ``EXTERNAL-IP`` value of ``controlcenter-bootstrap-lb`` service
   ksqldb.$DOMAIN         The ``EXTERNAL-IP`` value of ``ksqldb-bootstrap-lb`` service
   connect.$DOMAIN        The ``EXTERNAL-IP`` value of ``connect-bootstrap-lb`` service
   schemaregistry.$DOMAIN The ``EXTERNAL-IP`` value of ``schemaregistry-bootstrap-lb`` service
   ====================== ====================================================================

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
   
     echo bootstrap.servers=kafka.$DOMAN:9092 | base64
   
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
   
     http://controlcenter.$DOMAIN

#. Check that the ``elastic-0`` topic was created and that messages are being produced to the topic.

=========
Tear Down
=========

Shut down Confluent Platform and the data:

::

  kubectl delete -f $TUTORIAL_HOME/producer-app-data.yaml

::

  kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml

::

  helm delete operator
  
::

  kubectl delete namespace myclient

