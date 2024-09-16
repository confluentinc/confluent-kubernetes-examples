Deploy Confluent Platform
=========================

In this workflow scenario, you'll set up Connect with basic authentication.  
You will use Control Center to monitor and connect to a Confluent Platform.

NOTE: Control Center does not support basic authentication to the Connect Cluster and you will not be able to connect to it via the UI. 



The goal for this scenario is for you to:

* Configure basic authentication for Connect authentication (no RBAC).
* Quickly set up the complete Confluent Platform on the Kubernetes.
* Configure a producer to generate sample data.


To complete this scenario, you'll follow these steps:

#. Set the current tutorial directory.

#. Deploy Confluent For Kubernetes.

#. Deploy secret for basic authentication.

#. Deploy Confluent Platform.

#. Deploy the Producer application.

#. Tear down Confluent Platform.

==================================
Set the current tutorial directory
==================================

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

::
   
  export TUTORIAL_HOME=<Tutorial directory>/security/plaintext-basic-auth-Connect

===============================
Deploy Confluent for Kubernetes
===============================

#. Set up the Helm Chart:

   ::

     helm repo add confluentinc https://packages.confluent.io/helm


#. Install Confluent For Kubernetes using Helm:

   ::

     helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace=confluent
  
#. Check that the Confluent For Kubernetes pod comes up and is running:

   ::
     
     kubectl get pods --namespace=confluent


==================================
Create Basic authentication secret 
==================================

::

  kubectl create secret generic basicsecret \
   --from-file=basic.txt=$TUTORIAL_HOME/basic.txt \
   --namespace confluent


========================================
Review Confluent Platform configurations
========================================

You install Confluent Platform components as custom resources (CRs). 

You can configure all Confluent Platform components as custom resources. In this
tutorial, you will configure all components in a single file and deploy all
components with one ``kubectl apply`` command.

The entire Confluent Platform is configured in one configuration file:
``$TUTORIAL_HOME/confluent-platform.yaml``

In this configuration file, there is a custom Resource configuration spec for
each Confluent Platform component - replicas, image to use, resource
allocations.

For example, the Kafka section of the file is as follows:

::
  
  ---
  apiVersion: platform.confluent.io/v1beta1
  kind: Kafka
  metadata:
    name: kafka
    namespace: operator
  spec:
    replicas: 3
    image:
      application: confluentinc/cp-server:7.6.0
      init: confluentinc/confluent-init-container:2.9.0
    dataVolumeCapacity: 10Gi
    metricReporter:
      enabled: true
  ---
  
=========================
Deploy Confluent Platform
=========================

#. Deploy Confluent Platform with the above configuration:

::

  kubectl apply -f $TUTORIAL_HOME/confluent-platform.yaml --namespace=confluent

#. Check that all Confluent Platform resources are deployed:

   ::
   
     kubectl get confluent --namespace=confluent

#. Get the status of any component. For example, to check Kafka:

   ::
   
     kubectl describe kafka --namespace=confluent

========
Validate
========

Deploy producer application
^^^^^^^^^^^^^^^^^^^^^^^^^^^

Now that we've got the infrastructure set up, let's deploy the producer client
app.

The producer app is packaged and deployed as a pod on Kubernetes. The required
topic is defined as a KafkaTopic custom resource in
``$TUTORIAL_HOME/secure-producer-app-data.yaml``.

The ``$TUTORIAL_HOME/secure-producer-app-data.yaml`` defines the ``elastic-0``
topic as follows:

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
      
Deploy the producer app:

::
   
  kubectl apply -f $TUTORIAL_HOME/producer-app-data.yaml --namespace=confluent


Validate authentication with Connect
^^^^^^^^^^^^^^^^^^^^^^^^^^

::

  kubectl --namespace=confluent exec -it connect-0 -- curl -u thisismyusername:thisismypass http://0.0.0.0:8083


The above should return something like this: 

::

  {"version":"6.1.0-ce","commit":"958ad0f3c7030f1c","kafka_cluster_id":"SjW1_kcORW-nSsU2Yy1R1Q"}


Validate in Control Center
^^^^^^^^^^^^^^^^^^^^^^^^^^

Use Control Center to monitor the Confluent Platform, and see the created topic and data.

#. Set up port forwarding to Control Center web UI from local machine:

   ::

     kubectl port-forward controlcenter-0 9021:9021 --namespace=confluent

#. Browse to Control Center:

   ::
   
     http://localhost:9021





#. Check that the ``elastic-0`` topic was created and that messages are being produced to the topic.

=========
Tear Down
=========

Shut down Confluent Platform and the data:

::

  kubectl delete -f $TUTORIAL_HOME/producer-app-data.yaml --namespace=confluent

::

  kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml --namespace=confluent

::

  helm delete operator --namespace=confluent

::

  helm delete secret basicsecret --namespace=confluent

::


