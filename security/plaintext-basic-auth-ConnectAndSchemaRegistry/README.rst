Deploy Confluent Platform
=========================

In this workflow scenario, you'll set up Connect and Schema Registry with basic authentication.  
You will use Control Center to monitor and connect to a Confluent Platform.

NOTE: Control Center does not support basic authentication to the Connect Cluster and you will not be able to connect to it via the UI. 



The goal for this scenario is for you to:

* Configure basic authentication for Connect authentication (no RBAC).
* Configure basic authentication for Schema Registry authentication (no RBAC).
* Quickly set up the complete Confluent Platform on the Kubernetes.
* Configure a Avro producer to generate sample data.
* Configure a Avro consumer to generate sample data.



To complete this scenario, you'll follow these steps:

#. Set the current tutorial directory.

#. Deploy Confluent For Kubernetes.

#. Deploy secrets for basic authentication.

#. Deploy Confluent Platform.

#. Deploy the Producer application.

#. Tear down Confluent Platform.

==================================
Set the current tutorial directory
==================================

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

::
   
  export TUTORIAL_HOME=<Tutorial directory>/security/plaintext-basic-auth-ConnectAndSchemaRegistry

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

  kubectl create secret generic basicsecretconnect \
   --from-file=basic.txt=$TUTORIAL_HOME/basicConnect.txt \
   --namespace confluent

  kubectl create secret generic basicwithrolesr \
   --from-file=basic.txt=$TUTORIAL_HOME/basicwithroleSR.txt \
   --namespace confluent

  kubectl create secret generic basicsecretsrccc \
   --from-file=basic.txt=$TUTORIAL_HOME/basicsecretSRC3.txt \
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
      application: confluentinc/cp-server:7.4.0
      init: confluentinc/confluent-init-container:2.6.0
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

Now that we've got the infrastructure set up, let's deploy the avro producer and consumer client
app.

The avro producer and consumer app is packaged and deployed as a pod on Kubernetes. The required
topic is defined as a KafkaTopic custom resource in
``$TUTORIAL_HOME/producer-consumer-app-data.yaml``.

The ``$TUTORIAL_HOME/producer-consumer-app-data.yaml`` defines the ``producer-example-0``
topic as follows:

::

  apiVersion: platform.confluent.io/v1beta1
  kind: KafkaTopic
  metadata:
    name: producer-example-0
    namespace: confluent
  spec:
    replicas: 1
    partitionCount: 1
    configs:
      cleanup.policy: "delete"
      
Deploy the producer/consumer app:

::
   
  kubectl apply -f $TUTORIAL_HOME/producer-consumer-app-data.yaml --namespace=confluent

Validate the consumer, the output will indicate that the produce was able to produce avro value: 

::
   
  kubectl logs consumer-example --namespace=confluent

Note that the following is expected in the end of the log:

::
  [2022-02-23 11:15:35,545] ERROR Error processing message, terminating consumer process:  (kafka.tools.ConsoleConsumer$:43)
org.apache.kafka.common.errors.TimeoutException


Validate authentication with Connect
^^^^^^^^^^^^^^^^^^^^^^^^^^

::

  kubectl --namespace=confluent exec -it connect-0 -- curl -u thisismyusername:thisismypass http://0.0.0.0:8083


The above should return something like this: 

::

  {"version":"6.1.0-ce","commit":"958ad0f3c7030f1c","kafka_cluster_id":"SjW1_kcORW-nSsU2Yy1R1Q"}

Validate authentication with Schema Registry
^^^^^^^^^^^^^^^^^^^^^^^^^^

::

 kubectl --namespace=confluent exec -it schemaregistry-0 -- curl -u thisismyusername:thisismypass http://0.0.0.0:8081/schemas

The above should return something like this: 

::

  [{"subject":"producer-example-0-value","version":1,"id":1,"schema":"{\"type\":\"record\",\"name\":\"myrecord\",\"fields\":[{\"name\":\"f1\",\"type\":\"string\"}]}"}]


Validate in Control Center
^^^^^^^^^^^^^^^^^^^^^^^^^^

Use Control Center to monitor the Confluent Platform, and see the created topic and data.

#. Set up port forwarding to Control Center web UI from local machine:

   ::

     kubectl port-forward controlcenter-0 9021:9021 --namespace=confluent

#. Browse to Control Center:

   ::
   
     http://localhost:9021





#. Check that the ``producer-example-0`` topic was created and that messages are being produced to the topic.

=========
Tear Down
=========

Shut down Confluent Platform and the data:

::

  kubectl delete -f $TUTORIAL_HOME/producer-consumer-app-data.yaml --namespace=confluent

::

  kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml --namespace=confluent

::

  kubectl delete secrets basicsecretconnect basicsecretsrccc basicwithrolesr  --namespace=confluent

::

  helm delete operator --namespace=confluent

::

  helm delete secret basicsecret --namespace=confluent

::


