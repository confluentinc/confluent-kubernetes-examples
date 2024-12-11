Deploy Confluent Platform
=========================

In this workflow scenario, you'll set up Control Center with LDAPs (ldap over TLS) based authentication to monitor and connect to a Confluent Platform with no security.

The goal for this scenario is for you to:

* Configure LDAP with TLS server for Control Center authentication (no RBAC).
* Quickly set up the complete Confluent Platform on the Kubernetes.
* Configure ldap authentication on the external listener (9092)
* Configure a producer to generate sample data.


To complete this scenario, you'll follow these steps:

#. Set the current tutorial directory.

#. Deploy Confluent For Kubernetes.

#. Deploy LDAPS server

#. Deploy Confluent Platform.

#. Deploy the Producer application.

#. Tear down Confluent Platform.

==================================
Set the current tutorial directory
==================================

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

::
   
  export TUTORIAL_HOME=<Tutorial directory>/security/plaintext-ldaps-auth-control-center

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

===============
Deploy OpenLDAP
===============

This repo includes a Helm chart for `OpenLdap
<https://github.com/osixia/docker-openldap>`__. The chart ``values.yaml``
includes the set of principal definitions that Confluent Platform needs for
RBAC.

#. Deploy OpenLdap

   ::

     helm upgrade --install -f $TUTORIAL_HOME/openldapssl/ldaps.yaml test-ldap $TUTORIAL_HOME/../../assets/openldap --namespace confluent

Note that it is assumed that your Kubernetes cluster has a ``confluent`` namespace available, otherwise you can create it by running ``kubectl create namespace confluent``. 

#. Validate that OpenLDAP is running:  
   
   ::

     kubectl get pods --namespace=confluent

#. Log in to the LDAP pod:

   ::

     kubectl --namespace=confluent exec -it ldap-0 -- bash

#. Run the LDAP search command:

   ::

     ldapsearch -LLL -x -H ldaps://ldap.confluent.svc.cluster.local:636 -b 'dc=test,dc=com' -D "cn=mds,dc=test,dc=com" -w 'Developer!'

#. Exit out of the LDAP pod:

   ::
   
     exit 

#. Create secret for Control Center to use 

   ::
   
    kubectl create secret generic ldaps-tls \
    --from-file=truststore.jks=$TUTORIAL_HOME/openldapssl/truststore.jks \
    --from-file=jksPassword.txt=$TUTORIAL_HOME/openldapssl/jksPassword.txt \
    --namespace confluent

#. Create Control Center `bindDn` and `bindPassword`

  ::

    kubectl create secret generic ldaps-user \
    --from-file=ldap.txt=$TUTORIAL_HOME/openldapssl/ldapbinds.txt \
    --namespace confluent


========================================
Review Confluent Platform configurations
========================================

You install Confluent Platform components as custom resources (CRs). 

You can configure all Confluent Platform components as custom resources. In this
tutorial, you will configure all components in a single file and deploy all
components with one ``kubectl apply`` command.

The entire Confluent Platform is configured in one configuration file:
``$TUTORIAL_HOME/confluent-platform-ccc-ldaps.yaml``

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
      application: confluentinc/cp-server:7.8.0
      init: confluentinc/confluent-init-container:2.10.0
    dataVolumeCapacity: 10Gi
    metricReporter:
      enabled: true
  ---
  
=========================
Deploy Confluent Platform
=========================

#. Deploy Confluent Platform with the above configuration:

::

  kubectl apply -f $TUTORIAL_HOME/confluent-platform-ccc-ldaps.yaml --namespace=confluent

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

Validate in Control Center
^^^^^^^^^^^^^^^^^^^^^^^^^^

Use Control Center to monitor the Confluent Platform, and see the created topic and data.

#. Set up port forwarding to Control Center web UI from local machine:

   ::

     kubectl port-forward controlcenter-0 9021:9021 --namespace=confluent

#. Browse to Control Center:

   ::
   
     http://localhost:9021


#. Users: 

    Full Control: Username:james Password:james-secret  

    Restricted Control: Username:alice Password:alice-secret

#. Check that the ``elastic-0`` topic was created and that messages are being produced to the topic.


Check external listener
^^^^^^^^^^^^^^^^^^^^^^^

We've configured ldap authentication on the external listener of Kafka. 
To validate it you can open a bash to one of the pods and try to connect to the `9092` port:  

::

  kubectl --namespace confluent exec -it kafka-0 -- bash

  cat <<EOF > /tmp/kafka.properties
  bootstrap.servers=kafka.confluent.svc.cluster.local:9092
  sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=kafka password=kafka-secret;
  sasl.mechanism=PLAIN
  security.protocol=SASL_PLAINTEXT
  EOF

  kafka-topics --bootstrap-server localhost:9092 --command-config /tmp/kafka.properties --list

Deploy producer application external listener
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

The producer app is packaged and deployed as a pod on Kubernetes. The required
topic is defined as a KafkaTopic custom resource in
``$TUTORIAL_HOME/producer-app-data-ldaps.yaml``.


      
Deploy the producer app and check Control Center topic ldaps-producer-test-0: 

::
   
  kubectl apply -f $TUTORIAL_HOME/producer-app-data-ldaps.yaml --namespace=confluent



=========
Tear Down
=========

Shut down Confluent Platform and the data:

::

  kubectl delete -f $TUTORIAL_HOME/producer-app-data-ldaps.yaml --namespace=confluent
  
::

  kubectl delete -f $TUTORIAL_HOME/producer-app-data.yaml --namespace=confluent

::

  kubectl delete -f $TUTORIAL_HOME/confluent-platform-ccc-ldaps.yaml --namespace=confluent

::

  helm delete operator --namespace=confluent

::

  helm delete test-ldap --namespace=confluent

::

  kubectl delete pvc ldap-config-ldap-0 --namespace=confluent

::

  kubectl delete pvc ldap-data-ldap-0 --namespace=confluent

::

  kubectl delete secret ldaps-tls --namespace=confluent

::

  kubectl delete secret ldaps-user --namespace=confluent

===============
Troubleshooting
===============

:: 

  openssl s_client -connect ldap.confluent.svc.cluster.local:636
  ldapsearch -H ldaps://dc.oholics.net:636 -b “DC=oholics,DC=net” -D “CN=svc-LDAPBind,OU=ServiceAccounts,DC=oholics,DC=net” -w “<MyPass>”
