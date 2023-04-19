Production secured setup LDAP on all Broker's listeners
=======================================================

Confluent recommends these security mechanisms for a production deployment:

- Enable Kafka client authentication. Choose one of:

  - SASL/Plain or mTLS

  - For SASL/Plain, the identity can come from LDAP server

- Enable Confluent Role Based Access Control for authorization, with user/group identity coming from LDAP server

- Enable TLS for network encryption - both internal (between CP components) and external (Clients to CP components)

In this deployment scenario, we will setup CP components SASL/LDAP for authentication, using user provided custom certificates.

Before continuing with the scenario, ensure that you have set up the
`prerequisites </README.md#prerequisites>`_.

==================================
Set the current tutorial directory
==================================

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

::
   
  export TUTORIAL_HOME=<Tutorial directory>/security/production-secure-deploy-ldap-rbac-all
  
===============================
Deploy Confluent for Kubernetes
===============================

#. Set up the Helm Chart:

   ::

     helm repo add confluentinc https://packages.confluent.io/helm

Note that it is assumed that your Kubernetes cluster has a ``confluent`` namespace available, otherwise you can create it by running ``kubectl create namespace confluent``. 


#. Install Confluent For Kubernetes using Helm:

   ::

     helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace confluent
  
#. Check that the Confluent For Kubernetes pod comes up and is running:

   ::
     
     kubectl get pods --namespace confluent

===============
Deploy OpenLDAP
===============

This repo includes a Helm chart for `OpenLdap
<https://github.com/osixia/docker-openldap>`__. The chart ``values.yaml``
includes the set of principal definitions that Confluent Platform needs for
RBAC.

#. Deploy OpenLdap

   ::

     helm upgrade --install -f $TUTORIAL_HOME/../../assets/openldap/ldaps-rbac.yaml test-ldap $TUTORIAL_HOME/../../assets/openldap --namespace confluent

#. Validate that OpenLDAP is running:  
   
   ::

     kubectl get pods --namespace confluent

#. Log in to the LDAP pod:

   ::

     kubectl --namespace confluent exec -it ldap-0 -- bash

#. Run the LDAP search command:

   ::

     ldapsearch -LLL -x -H ldap://ldap.confluent.svc.cluster.local:389 -b 'dc=test,dc=com' -D "cn=mds,dc=test,dc=com" -w 'Developer!'

#. Exit out of the LDAP pod:

   ::
   
     exit 
     
============================
Deploy configuration secrets
============================

You'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.
   
To support the above deployment scenario, you need to provide the following
credentials:

* Component TLS Certificates

* Authentication credentials for Zookeeper, Kafka, Control Center, remaining CP components

* RBAC principal credentials
  
You can either provide your own certificates, or generate test certificates. Follow instructions
in the below `Appendix: Create your own certificates <#appendix-create-your-own-certificates>`_ section to see how to generate certificates
and set the appropriate SANs. 



Provide component TLS certificates
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

::
   
    kubectl create secret generic tls-group1 \
      --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/generated/server.pem \
      --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
      --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/generated/server-key.pem \
      --namespace confluent


Provide authentication credentials
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

#. Create a Kubernetes secret object for Zookeeper, Kafka, and Control Center.

   This secret object contains file based properties. These files are in the
   format that each respective Confluent component requires for authentication
   credentials.

   ::
   
     kubectl create secret generic credential \
       --from-file=plain-users.json=$TUTORIAL_HOME/creds/creds-kafka-sasl-users.json \
       --from-file=digest-users.json=$TUTORIAL_HOME/creds/creds-zookeeper-sasl-digest-users.json \
       --from-file=digest.txt=$TUTORIAL_HOME/creds/creds-kafka-zookeeper-credentials.txt \
       --from-file=plain.txt=$TUTORIAL_HOME/creds/creds-client-kafka-sasl-user.txt \
       --from-file=basic.txt=$TUTORIAL_HOME/creds/creds-control-center-users.txt \
       --from-file=plain-interbroker.txt=$TUTORIAL_HOME/creds/creds-client-kafka-sasl-user.txt \
       --from-file=ldap.txt=$TUTORIAL_HOME/creds/ldap.txt \
       --namespace confluent

   In this tutorial, we use one credential for authenticating all client and
   server communication to Kafka brokers. In production scenarios, you'll want
   to specify different credentials for each of them.

Provide RBAC principal credentials
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

#. Create a Kubernetes secret object for MDS:

   ::
   
     kubectl create secret generic mds-token \
       --from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../assets/certs/mds-publickey.txt \
       --from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../assets/certs/mds-tokenkeypair.txt \
       --namespace confluent
   
   ::
   
     # Kafka RBAC credential
     kubectl create secret generic mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/creds/bearer.txt \
       --namespace confluent
     # Control Center RBAC credential
     kubectl create secret generic c3-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/creds/c3-mds-client.txt \
       --namespace confluent
     # Connect RBAC credential
     kubectl create secret generic connect-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/creds/connect-mds-client.txt \
       --namespace confluent
     # Schema Registry RBAC credential
     kubectl create secret generic sr-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/creds/sr-mds-client.txt \
       --namespace confluent
     # ksqlDB RBAC credential
     kubectl create secret generic ksqldb-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/creds/ksqldb-mds-client.txt \
       --namespace confluent
     # Kafka Rest Proxy RBAC credential
     kubectl create secret generic krp-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/creds/krp-mds-client.txt \
       --namespace confluent
     # Kafka REST credential
     kubectl create secret generic rest-credential \
       --from-file=bearer.txt=$TUTORIAL_HOME/creds/bearer.txt \
       --from-file=basic.txt=$TUTORIAL_HOME/creds/bearer.txt \
       --namespace confluent

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

Edit the Confluent Platform CR file: ``$TUTORIAL_HOME/confluent-platform-production.yaml``

Specifically, note that external accesses to Confluent Platform components are
configured using the nodePort services.

The Kafka section of the file is set as follow for Node Port access:

:: 

  Spec:
    listeners:
      external:
        externalAccess:
          type: nodePort
          nodePort:
            host: <hostname>
            nodePortOffset: 30000

Component section of the file is set as follows for Node Port access:

::

  spec:
    externalAccess:
      type: nodePort
      nodePort:
        host: <hostname>
        nodePortOffset: 30200


=========================
Deploy Confluent Platform
=========================

#. Deploy Confluent Platform:

   ::

     kubectl apply -f $TUTORIAL_HOME/confluent-platform-production.yaml --namespace confluent

#. Check that all Confluent Platform resources are deployed:

   ::
   
     kubectl get pods --namespace confluent

   If any component does not deploy, it could be due to missing configuration information in secrets.
   The Kubernetes events will tell you if there are any issues with secrets. For example:

   ::

     kubectl get events --namespace confluent
     Warning  KeyInSecretRefIssue  kafka/kafka  required key [ldap.txt] missing in secretRef [credential] for auth type [ldap_simple]

#. The default required RoleBindings for each Confluent component are created
   automatically, and maintained as `confluentrolebinding` custom resources.

   ::

     kubectl get confluentrolebinding --namespace confluent

If you'd like to see how the RoleBindings custom resources are structured, so that
you can create your own RoleBindings, take a look at the custom resources in this 
directory: $TUTORIAL_HOME/internal-rolebindings
     

=================================================
Create RBAC Rolebindings for Control Center admin
=================================================

Create Control Center Role Binding for a Control Center ``testadmin`` user.

::

  kubectl apply -f $TUTORIAL_HOME/controlcenter-testadmin-rolebindings.yaml --namespace confluent

========
Validate
========

Validate in Control Center
^^^^^^^^^^^^^^^^^^^^^^^^^^

Use Control Center to monitor the Confluent Platform, and see the created topic
and data. You can visit the external URL you set up for Control Center, or visit the URL
through a local port forwarding like below:

#. Set up port forwarding to Control Center web UI from local machine:

   ::

     kubectl port-forward controlcenter-0 9021:9021 --namespace confluent

#. Browse to Control Center. You will log in as the ``testadmin`` user, with ``testadmin`` password.

   ::
   
     https://localhost:9021


#. Using the port node 

   ::
   
     export POD_NAME=controlcenter-0
     export NODE_PORT=$(kubectl get -o jsonpath="{.spec.ports[0].nodePort}" services controlcenter-bootstrap-np)
     export NODE_IP=$(kubectl get nodes  -o jsonpath="{.items[0].status.addresses[1].address}")
     echo https://$NODE_IP:$NODE_PORT




The ``testadmin`` user (``testadmin`` password) has the ``SystemAdmin`` role granted and will have access to the
cluster and broker information.


====
TEST
====

Test via CLI
^^^^^^^^^^^^
#. Using the one of the kafka pods

   ::

     kubectl  exec kafka-2 -it -- bash             
     
     # kafka user 
     cat <<EOF > /tmp/kafka_kafka_user.properties
     sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=kafka password=kafka-secret;
     sasl.mechanism=PLAIN
     security.protocol=SASL_SSL
     ssl.truststore.location=/mnt/sslcerts/truststore.p12
     ssl.truststore.password=mystorepassword
     EOF
     
     kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 --command-config /tmp/kafka_kafka_user.properties --list
     
     # testadmin (RBAC via the apply yaml steps before)
     
     cat <<EOF > /tmp/kafka_testadmin_user.properties
     sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=testadmin password=testadmin;
     sasl.mechanism=PLAIN
     security.protocol=SASL_SSL
     ssl.truststore.location=/mnt/sslcerts/truststore.p12
     ssl.truststore.password=mystorepassword
     EOF
     
     kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 --command-config /tmp/kafka_testadmin_user.properties --list

     # Test a user does did not get authorization yet: james
     
     cat <<EOF > /tmp/kafka_james_user.properties
     sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=james password=james-secret;
     sasl.mechanism=PLAIN
     security.protocol=SASL_SSL
     ssl.truststore.location=/mnt/sslcerts/truststore.p12
     ssl.truststore.password=mystorepassword
     EOF
      
     kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 --command-config /tmp/kafka_james_user.properties  --list
          

#. Using the port node 

   ::
     
    kubectl cp confluent/kafka-0:/mnt/sslcerts/..data/truststore.p12 /tmp/truststore.p12
    kubectl cp confluent/kafka-0:/mnt/sslcerts/..data/keystore.p12  /tmp/keystore.p12
     
    (expect - tar: Removing leading `/' from member names )
     
    # kafka user 
     
     
     cat <<EOF > /tmp/kafka_kafka_user.properties
     sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=kafka password=kafka-secret;
     sasl.mechanism=PLAIN
     security.protocol=SASL_SSL
     ssl.truststore.location=/tmp/truststore.p12
     ssl.truststore.password=mystorepassword
     EOF
     
     kafka-topics --bootstrap-server <host>:30000 --command-config /tmp/kafka_kafka_user.properties  --list
      
     # testadmin (RBAC via the apply yaml steps before)
      
      
     cat <<EOF > /tmp/kafka_testadmin_user.properties
     sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=testadmin password=testadmin;
     sasl.mechanism=PLAIN
     security.protocol=SASL_SSL
     ssl.truststore.location=/tmp/truststore.p12
     ssl.truststore.password=mystorepassword
     EOF
      
     kafka-topics --bootstrap-server <host>:30000 --command-config /tmp/kafka_testadmin_user.properties  --list
      
     # Test a user does did not get authorization yet: james
 
     cat <<EOF > /tmp/kafka_james_user.properties
     sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=james password=james-secret;
     sasl.mechanism=PLAIN
     security.protocol=SASL_SSL
     ssl.truststore.location=/tmp/truststore.p12
     ssl.truststore.password=mystorepassword
     EOF
     
    kafka-topics --bootstrap-server <host>:30000 --command-config /tmp/kafka_james_user.properties  --list
     
    You can also query endpoint of connect:
    curl -X GET -k -u connect:connect-secret https://<host>:30300 



=========
Tear down
=========

::

  kubectl delete confluentrolebinding --all --namespace confluent
  
::

  kubectl delete -f $TUTORIAL_HOME/confluent-platform-production.yaml --namespace confluent

::

  kubectl delete secret rest-credential ksqldb-mds-client sr-mds-client connect-mds-client krp-mds-client c3-mds-client mds-client ca-pair-sslcerts --namespace confluent

::

  kubectl delete secret mds-token --namespace confluent

::

  kubectl delete secret credential --namespace confluent

::

 kubectl delete secret tls-group1 --namespace confluent

::

  helm delete test-ldap --namespace confluent

::

  helm delete operator --namespace confluent

======================================
Appendix: Create your own certificates
======================================

When testing, it's often helpful to generate your own certificates to validate the architecture and deployment.

You'll want both these to be represented in the certificate SAN:

- external domain names
- internal Kubernetes domain names

The internal Kubernetes domain name depends on the namespace you deploy to. If you deploy to `confluent` namespace, 
then the internal domain names will be: 

- *.kafka.confluent.svc.cluster.local
- *.zookeeper.confluent.svc.cluster.local
- *.confluent.svc.cluster.local

::

  # Install libraries on Mac OS
  brew install cfssl

::
  
  # Create Certificate Authority
  mkdir $TUTORIAL_HOME/../../assets/certs/generated && cfssl gencert -initca $TUTORIAL_HOME/../../assets/certs/ca-csr.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/ca -

::

  # Validate Certificate Authority
  openssl x509 -in $TUTORIAL_HOME/../../assets/certs/generated/ca.pem -text -noout

::

  # Create server certificates with the appropriate SANs (SANs listed in server-domain.json)
  # Don't forget to add your SAN
  cfssl gencert -ca=$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
  -ca-key=$TUTORIAL_HOME/../../assets/certs/generated/ca-key.pem \
  -config=$TUTORIAL_HOME/../../assets/certs/ca-config.json \
  -profile=server $TUTORIAL_HOME/../../assets/certs/server-domain.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/server

  # Validate server certificate and SANs
  openssl x509 -in $TUTORIAL_HOME/../../assets/certs/generated/server.pem -text -noout

Return to `step 1 <#provide-component-tls-certificates>`_ now you've created your certificates  

=====================================
Appendix: Update authentication users
=====================================

In order to add users to the authenticated users list, you'll need to update the list in the following files:

- For Kafka users, update the list in ``creds-kafka-sasl-users.json``.
- For Control Center users, update the list in ``creds-control-center-users.txt``.

After updating the list of users, you'll update the Kubernetes secret.

::

  kubectl create secret generic credential \
    --from-file=plain-users.json=$TUTORIAL_HOME/creds/creds-kafka-sasl-users.json \
    --from-file=digest-users.json=$TUTORIAL_HOME/creds/creds-zookeeper-sasl-digest-users.json \
    --from-file=digest.txt=$TUTORIAL_HOME/creds/creds-kafka-zookeeper-credentials.txt \
    --from-file=plain.txt=$TUTORIAL_HOME/creds/creds-client-kafka-sasl-user.txt \
    --from-file=basic.txt=$TUTORIAL_HOME/creds/creds-control-center-users.txt \
    --from-file=plain-interbroker.txt=$TUTORIAL_HOME/creds/creds-client-kafka-sasl-user.txt \
    --from-file=ldap.txt=$TUTORIAL_HOME/creds/ldap.txt \
      --save-config --dry-run=client -oyaml | kubectl apply -f -

In this above CLI command, you are generating the YAML for the secret, and applying it as an update to the existing secret ``credential``.

There's no need to restart the Kafka brokers or Control Center. The updates users list is picked up by the services.

=======================================
Appendix: Configure mTLS authentication
=======================================

Kafka supports mutual TLS (mTLS) authentication for client applications. With mTLS, principals are taken from the 
Common Name of the certificate used by the client application.

This example deployment spec ($TUTORIAL_HOME/confluent-platform-production-mtls.yaml) configures the Kafka external listener 
for mTLS authentication.

When using mTLS, you'll need to provide a different certificate for each component, so that each component
has the principal in the Common Name. In the example deployment spec, each component refers to a different
TLS certificate secret.

=========================
Appendix: Troubleshooting
=========================

Gather data
^^^^^^^^^^^

::

  # Check for any error messages in events
  kubectl get events --namespace confluent

  # Check for any pod failures
  kubectl get pods --namespace confluent

  # For pod failures, check logs
  kubectl logs <pod-name> --namespace confluent
