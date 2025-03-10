Deploy Confluent Platform
=========================

In this workflow scenario, you'll set up Connect, Schema Registry, ksqlDB, Rest Proxy, and Confluent Control Center with basic authentication.

NOTE: Control Center does not support basic authentication to the Connect and ksqlDB Cluster till CFK 2.4.0 and you will not be able to connect to it via the UI.
Starting with CFK 2.4.1, Control Center supports connecting to the Connect and ksqlDB cluster using basic authentication. Please check the `release notes from CFK 2.4.1 <https://docs.confluent.io/operator/2.4/release-notes.html#co-long-2-4-1-release-notes>`__

The goal for this scenario is for you to:

* Configure basic authentication for Connect authentication (no RBAC).
* Configure basic authentication for Schema Registry authentication (no RBAC).
* Configure basic authentication for ksqlDB authentication (no RBAC).
* Configure basic authentication for Rest Proxy authentication (no RBAC).
* Configure basic authentication for Confluent Control Center authentication (no RBAC).
* Quickly set up the complete Confluent Platform on the Kubernetes.
* Configure a Avro producer to generate sample data.
* Configure a Avro consumer to generate sample data.
* Use Control Center to monitor and connect to a Confluent Platform.



To complete this scenario, you'll follow these steps:

#. Set the current tutorial directory.

#. Deploy Confluent For Kubernetes.

#. Deploy server-side and client-side secrets for basic authentication.

#. Deploy Confluent Platform.

#. Deploy the Producer application.

#. Validate authentication

#. Tear down Confluent Platform.

==================================
Set the current tutorial directory
==================================

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

::
   
  export TUTORIAL_HOME=<Tutorial directory>/security/plaintext-basic-auth

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

Create directories
^^^^^^^^^^^^^^^^^^
* mkdir -p $TUTORIAL_HOME/server-side $TUTORIAL_HOME/client-side

Create Server-side basic authentication for Confluent components
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

::

  kubectl create secret generic basicsecretconnect \
   --from-file=basic.txt=$TUTORIAL_HOME/server-side/basicConnect.txt \
   --namespace confluent

  kubectl create secret generic basicwithrolesr \
   --from-file=basic.txt=$TUTORIAL_HOME/server-side/basicwithroleSR.txt \
   --namespace confluent

  kubectl create secret generic basicwithroleksql \
   --from-file=basic.txt=$TUTORIAL_HOME/server-side/basicwithroleKSQL.txt \
   --namespace confluent

  kubectl create secret generic basicwithrolec3 \
   --from-file=basic.txt=$TUTORIAL_HOME/server-side/basicwithroleC3.txt \
   --namespace confluent

  kubectl create secret generic basicwithrolerp \
   --from-file=basic.txt=$TUTORIAL_HOME/server-side/basicwithroleRP.txt \
   --namespace confluent

Create Client-side basic authentication for Confluent components
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

::

  kubectl create secret generic basicsecretconnectclient \
   --from-file=basic.txt=$TUTORIAL_HOME/client-side/basicsecretConnect.txt \
   --namespace confluent

  kubectl create secret generic basicsecretsrclient \
   --from-file=basic.txt=$TUTORIAL_HOME/client-side/basicsecretSR.txt \
   --namespace confluent

  kubectl create secret generic basicsecretksqlclient \
   --from-file=basic.txt=$TUTORIAL_HOME/client-side/basicsecretksql.txt \
   --namespace confluent

========================================
Review Confluent Platform configurations
========================================

Install Confluent Platform components as custom resources (CRs).

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
      application: confluentinc/cp-server:7.9.0
      init: confluentinc/confluent-init-container:2.11.0
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
Deploy producer application
========

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
      
Deploy the producer/consumer app

::

  kubectl apply -f $TUTORIAL_HOME/producer-consumer-app-data.yaml --namespace=confluent

Validate the consumer, the output will indicate that the produce was able to produce avro value: 

::

  kubectl logs consumer-example --namespace=confluent

Note that the following is expected in the end of the log

::

  [2022-02-23 11:15:35,545] ERROR Error processing message, terminating consumer process:  (kafka.tools.ConsoleConsumer$:43)
org.apache.kafka.common.errors.TimeoutException

========
Validate
========

Validate authentication with Connect
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

::

  kubectl --namespace=confluent exec -it connect-0 -- curl -u connectUser:thisismypass http://0.0.0.0:8083


The above command would return similar output:

::

  {"version":"7.8.0-ce","commit":"be816cdb62b83d78","kafka_cluster_id":"SjW1_kcORW-nSsU2Yy1R1Q"}

Validate authentication with Schema Registry
^^^^^^^^^^^^^^^^^^^^^^^^^^

::

 kubectl --namespace=confluent exec -it schemaregistry-0 -- curl -u srUser:thisismypass http://0.0.0.0:8081/schemas

The above command would return similar output:
::

  [{"subject":"producer-example-0-value","version":1,"id":1,"schema":"{\"type\":\"record\",\"name\":\"myrecord\",\"fields\":[{\"name\":\"f1\",\"type\":\"string\"}]}"}]


Validate authentication with ksqlDB
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

::

  kubectl --namespace=confluent exec -it ksqldb-0 -- curl -u ksqlUser:thisismypass http://0.0.0.0:8088/info

This command returns an output similar to as follows:

::

{"KsqlServerInfo":{"version":"7.8.0","kafkaClusterId":"WqIyB4VZRHObFuBPHdtzJQ","ksqlServiceId":"confluent.ksqldb_","serverStatus":"RUNNING"}}%

Validate authentication with Rest Proxy
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

::

  kubectl --namespace=confluent exec -it kafkarestproxy-0 -- curl -u restproxyUser:thisismypass http://localhost:8082/brokers

This command returns the list of the brokers in the cluster:

::

{"brokers":[0,1,2]}%

Validate authentication with Control Center
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

#. Set up port forwarding to Control Center web UI from local machine:

   ::

     kubectl port-forward controlcenter-0 9021:9021 --namespace=confluent

#. Browse to Control Center:

   ::

     http://localhost:9021

#. Login to the control center UI using any of the following users depending on the role you would like to use:

* Users:
    * Full Control: Username:c3admin Password:password1
    * Restricted Control: Username:c3restricted Password:password2

Monitor the Confluent Platform Components using Control Center
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Use Control Center to monitor the Confluent Platform, and monitor the created topic and data.

Once logged into the Control Center UI, check the ``producer-example-0`` topic, and messages which are being produced to this topic.

=========
Tear Down
=========

Shut down Confluent Platform and the data:

::

  kubectl delete -f $TUTORIAL_HOME/producer-consumer-app-data.yaml --namespace=confluent

::

  kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml --namespace=confluent

::

  kubectl delete secrets basicsecretconnect basicwithrolesr basicwithroleksql basicwithrolec3 basicwithrolerp basicsecretconnectClient basicsecretsrClient basicsecretksqlClient  --namespace=confluent

::

  helm delete operator --namespace=confluent

::



