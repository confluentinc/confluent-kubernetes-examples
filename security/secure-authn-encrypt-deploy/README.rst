Deploy Secure Confluent Platform
================================

In this workflow scenario, you'll set up secure Confluent Platform clusters with
SASL PLAIN authentication, no authorization, and inter-component TLS.

Watch the walkthrough: `Secure Deploy Demonstration <https://youtu.be/gC28r-qLbAs>`_

Before continuing with the scenario, ensure that you have set up the
`prerequisites </README.md#prerequisites>`_.

To complete this scenario, you'll follow these steps:

#. Set the current tutorial directory.

#. Deploy Confluent For Kubernetes.

#. Deploy configuration secrets.

#. Deploy Confluent Platform.

#. Deploy the Producer application.

#. Validate.

#. Tear down Confluent Platform.

==================================
Set the current tutorial directory
==================================

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

::
   
  export TUTORIAL_HOME=<Tutorial directory>/security/secure-authn-encrypt-deploy

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
Deploy configuration secrets
============================

You'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.

In this tutorial, you will deploy a secure Zookeeper, Kafka and Control Center,
and the rest of Confluent Platform components as shown below:

.. figure:: ../../images/20210428-Security_Architecture.png
   :width: 200px
   
To support the above deployment scenario, you need to provide the following
credentials:

* Root Certificate Authority to auto-generate certificates

* Authentication credentials for Zookeeper, Kafka, and Control Center

Provide a Root Certificate Authority
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Confluent For Kubernetes provides auto-generated certificates for Confluent Platform
components to use for inter-component TLS. You'll need to generate and provide a
Root Certificate Authority (CA).

#. Generate a CA pair to use in this tutorial:

   ::

     openssl genrsa -out $TUTORIAL_HOME/ca-key.pem 2048
    
   ::

     openssl req -new -key $TUTORIAL_HOME/ca-key.pem -x509 \
       -days 1000 \
       -out $TUTORIAL_HOME/ca.pem \
       -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA"

#. Create a Kuebernetes secret for inter-component TLS:

   ::

     kubectl create secret tls ca-pair-sslcerts \
       --cert=$TUTORIAL_HOME/ca.pem \
       --key=$TUTORIAL_HOME/ca-key.pem
  
Provide authentication credentials
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Create a Kubernetes secret object for Zookeeper, Kafka, and Control Center. This
secret object contains file based properties. These files are in the format that
each respective Confluent component requires for authentication credentials.

::

  kubectl create secret generic credential \
  --from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
  --from-file=digest-users.json=$TUTORIAL_HOME/creds-zookeeper-sasl-digest-users.json \
  --from-file=digest.txt=$TUTORIAL_HOME/creds-kafka-zookeeper-credentials.txt \
  --from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
  --from-file=basic.txt=$TUTORIAL_HOME/creds-control-center-users.txt

In this tutorial, we use one credential for authenticating all client and server
communication to Kafka brokers. In production scenarios, you'll want to specify
different credentials for each of them.

========================================
Review Confluent Platform configurations
========================================

You install Confluent Platform components as custom resources (CRs). 

The Confluent Platform components are configured in one file for secure
authentication and encryption for:
``$TUTORIAL_HOME/confluent-platform-secure.yaml``

Let's take a look at how these components are configured.

* Configure SASL PLAIN authentication for Kafka, with a pointer to the externally managed secrets object for credentials:

  ::
  
    spec:
      listeners:
        internal:
          authentication:
            type: plain
            jaasConfig:
              secretRef: credential
          tls:
            enabled: true

* Configure SASL PLAIN authentication to Kafka for other components, using a pointer to the externally managed secrets object for credentials:
 
  ::
  
    spec:
      dependencies:
        kafka:
          bootstrapEndpoint: kafka.confluent.svc.cluster.local:9071
          authentication:
            type: plain
            jaasConfig:
              secretRef: credential
          tls:
            enabled: true

* Configure auto generated certificates for all server components:

  :: 
  
    spec:
      tls:
        autoGeneratedCerts: true
  
=========================
Deploy Confluent Platform
=========================

#. Deploy Confluent Platform with the above configuration:

   ::

     kubectl apply -f $TUTORIAL_HOME/confluent-platform-secure.yaml

#. Check that all Confluent Platform resources are deployed:

   ::
   
     kubectl get confluent

#. Get the status of any component. For example, to check Control Center:

   ::
   
     kubectl describe controlcenter

=============================
Provide client configurations
=============================

You'll need to provide the client configurations to use. This can be provided as
a Kubernetes secret that client applications can use.

#. Get the status of Kafka:

   ::
   
     kubectl describe kafka
  
#. In the output of the previous command, validate the internal client config:

   ::
   
     Listeners:
       Internal:
         Authentication Type: plain
         Client: bootstrap.servers=kafka.confluent.svc.cluster.local:9071

#. Create the ``kafka.properties`` file in $TUTORIAL_HOME. Add the above endpoint and the credentials as follows:
  
   ::
   
     bootstrap.servers=kafka.confluent.svc.cluster.local:9071
     sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=kafka_client password=kafka_client-secret;
     sasl.mechanism=PLAIN
     security.protocol=SASL_SSL
     ssl.truststore.location=/mnt/sslcerts/truststore.jks
     ssl.truststore.password=mystorepassword

#. Create a configuration secret for client applications to use:

   ::

     kubectl create secret generic kafka-client-config-secure \
       --from-file=$TUTORIAL_HOME/kafka.properties
  
========
Validate
========

Deploy the producer application
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Now that we've got the infrastructure set up, let's deploy the producer client
app.

The producer app is packaged and deployed as a pod on Kubernetes. The required
topic is defined as a KafkaTopic custom resource in
``$TUTORIAL_HOME/secure-producer-app-data.yaml``.

This app takes the above client configuration as a Kubernetes secret. The secret
is mounted to the app pod file system, and the client application reads the
configuration as a file.

::

  kubectl apply -f $TUTORIAL_HOME/secure-producer-app-data.yaml

Validate in Control Center
^^^^^^^^^^^^^^^^^^^^^^^^^^

Use Control Center to monitor the Confluent Platform, and see the created topic
and data.

#. Set up port forwarding to Control Center web UI from local machine:

   ::

     kubectl port-forward controlcenter-0 9021:9021

#. Browse to Control Center and log in as the ``admin`` user with the ``Developer1`` password:

   ::
   
     https://localhost:9021

#. Check that the ``elastic-0`` topic was created and that messages are being produced to the topic.

=========
Tear down
=========

::

  kubectl delete -f $TUTORIAL_HOME/secure-producer-app-data.yaml

::

  kubectl delete -f $TUTORIAL_HOME/confluent-platform-secure.yaml

::

  kubectl delete secret kafka-client-config-secure

::

  kubectl delete secret credential

::

  kubectl delete secret ca-pair-sslcerts

::

  helm delete operator
  
