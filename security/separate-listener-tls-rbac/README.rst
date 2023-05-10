===============================================
Separate listeners on confluent metadata server
===============================================

In this deployment scenario, we'll choose SASL/Plain for authentication and configure TLS encryption using CFK auto-generated component certificates.
You'll need to provide a certificate authority certificate for CFK to auto-generate the component certificates.
Specifically, you will set up mds(confluent metadata server) to use separate certs internal and external communication, so that you do not mix external and internal domains in the certificate SAN.

[Separate TLS certificates for internal and external communications](https://docs.confluent.io/operator/current/co-network-encryption.html#co-configure-separate-certificates) feature is supported for ksqlDB, Schema Registry, MDS, and Kafka REST services, starting in CFK 2.6.0 and Confluent Platform 7.4.0 release.

==================================
Set the current tutorial directory
==================================

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

::
   
  export TUTORIAL_HOME=<Tutorial directory>/security/separate-listener-tls-rbac
  
===============================
Deploy Confluent for Kubernetes
===============================

#. Set up the Helm Chart:

   ::

     helm repo add confluentinc https://packages.confluent.io/helm

   It is assumed that your Kubernetes cluster has the ``confluent`` namespace available. If not, you can create it by running 
   ``kubectl create namespace confluent``. 

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

* Certificate authority - private key and certificate

* Authentication credentials for Zookeeper, Kafka, Control Center, remaining CP components

* RBAC principal credentials
  
You can either provide your own CA key and certificates, or generate test certificates. Follow instructions
in the below `Appendix: Create your own certificates <#appendix-create-your-own-certificates>`_ section to see how to generate certificates
and set the appropriate SANs. 



Provide operator CA TLS certificates for self generating
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Use the provided CA certs: 

::
   
    kubectl create secret tls ca-pair-sslcerts \
      --cert=$TUTORIAL_HOME/ca.pem \
      --key=$TUTORIAL_HOME/ca-key.pem \
      --namespace confluent

**OR use the self created CA certs**: 

::
   
    kubectl create secret tls ca-pair-sslcerts \
      --cert=$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
      --key=$TUTORIAL_HOME/../../assets/certs/generated/ca-key.pem \
      --namespace confluent

Provide MDS TLS certificates 
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
In this scenario, you'll be allowing clients to connect with mds through the external-to-Kubernetes network.

For that purpose, you'll provide a server certificate that secures the external domain used to access mds.

::

    #If you don't have one, create a root certificate authority for the external component certs
    openssl genrsa -out $TUTORIAL_HOME/externalRootCAkey.pem 2048

    openssl req -x509  -new -nodes \
      -key $TUTORIAL_HOME/externalRootCAkey.pem \
      -days 3650 \
      -out $TUTORIAL_HOME/externalCacerts.pem \
      -subj "/C=US/ST=CA/L=MVT/O=TestOrg/OU=Cloud/CN=ExternalCA"

    # Create MDS server certificates
    cfssl gencert -ca=$TUTORIAL_HOME/externalCacerts.pem \
    -ca-key=$TUTORIAL_HOME/externalRootCAkey.pem \
    -config=$TUTORIAL_HOME/../../assets/certs/ca-config.json \
    -profile=server $TUTORIAL_HOME/kafka-server-domain.json | cfssljson -bare $TUTORIAL_HOME/mds-server


Provide the certificates to respective components through a Kubernetes Secret:

::

    kubectl create secret generic tls-mds \
      --from-file=fullchain.pem=$TUTORIAL_HOME/mds-server.pem \
      --from-file=cacerts.pem=$TUTORIAL_HOME/externalCacerts.pem \
      --from-file=privkey.pem=$TUTORIAL_HOME/mds-server-key.pem \
      --namespace confluent

Provide authentication credentials
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

#. Create a Kubernetes secret object for Zookeeper, Kafka, and Control Center.

   This secret object contains file based properties. These files are in the
   format that each respective Confluent component requires for authentication
   credentials.

   ::
   
     kubectl create secret generic credential \
       --from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
       --from-file=digest-users.json=$TUTORIAL_HOME/creds-zookeeper-sasl-digest-users.json \
       --from-file=digest.txt=$TUTORIAL_HOME/creds-kafka-zookeeper-credentials.txt \
       --from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
       --from-file=basic.txt=$TUTORIAL_HOME/creds-control-center-users.txt \
       --from-file=ldap.txt=$TUTORIAL_HOME/ldap.txt \
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
       --from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
       --namespace confluent
     # Control Center RBAC credential
     kubectl create secret generic c3-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/c3-mds-client.txt \
       --namespace confluent
     # Connect RBAC credential
     kubectl create secret generic connect-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/connect-mds-client.txt \
       --namespace confluent
     # Schema Registry RBAC credential
     kubectl create secret generic sr-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/sr-mds-client.txt \
       --namespace confluent
     # ksqlDB RBAC credential
     kubectl create secret generic ksqldb-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/ksqldb-mds-client.txt \
       --namespace confluent
     # Kafka Rest Proxy RBAC credential
     kubectl create secret generic krp-mds-client \
       --from-file=bearer.txt=$TUTORIAL_HOME/krp-mds-client.txt \
       --namespace confluent
     # Kafka REST credential
     kubectl create secret generic rest-credential \
       --from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
       --from-file=basic.txt=$TUTORIAL_HOME/bearer.txt \
       --namespace confluent

=========================
Deploy Confluent Platform
=========================

#. Deploy Confluent Platform:

   ::

     kubectl apply -f $TUTORIAL_HOME/confluent-platform-mds-separate-listener.yaml

#. Check that all Confluent Platform resources are deployed:

   ::
   
     kubectl get pods --namespace confluent

If any component does not deploy, it could be due to missing configuration information in secrets.
The Kubernetes events will tell you if there are any issues with secrets. For example:

::

  kubectl get events --namespace confluent
  Warning  KeyInSecretRefIssue  kafka/kafka  required key [ldap.txt] missing in secretRef [credential] for auth type [ldap_simple]

The default required RoleBindings for each Confluent component are created
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

  kubectl apply -f $TUTORIAL_HOME/controlcenter-testadmin-rolebindings.yaml

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

The ``testadmin`` user (``testadmin`` password) has the ``SystemAdmin`` role granted and will have access to the
cluster and broker information.

=========
Tear down
=========

::

  kubectl delete confluentrolebinding --all --namespace confluent
  
::

  kubectl delete -f $TUTORIAL_HOME/controlcenter-testadmin-rolebindings.yaml

::

  kubectl delete -f $TUTORIAL_HOME/confluent-platform-mds-separate-listener.yaml

::

  kubectl delete secret rest-credential ksqldb-mds-client sr-mds-client connect-mds-client krp-mds-client c3-mds-client mds-client ca-pair-sslcerts tls-mds --namespace confluent

::

  kubectl delete secret mds-token --namespace confluent

::

  kubectl delete secret credential --namespace confluent

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


Return to `step 1 <#provide-operator-ca-tls-certificates-for-self-generating>`_ now you've created your certificates  

=====================================
Appendix: Update authentication users
=====================================

In order to add users to the authenticated users list, you'll need to update the list in the following files:

- For Kafka users, update the list in ``creds-kafka-sasl-users.json``.
- For Control Center users, update the list in ``creds-control-center-users.txt``.

After updating the list of users, you'll update the Kubernetes secret.

::

  kubectl --namespace confluent create secret generic credential \
      --from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
      --from-file=digest-users.json=$TUTORIAL_HOME/creds-zookeeper-sasl-digest-users.json \
      --from-file=digest.txt=$TUTORIAL_HOME/creds-kafka-zookeeper-credentials.txt \
      --from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
      --from-file=basic.txt=$TUTORIAL_HOME/creds-control-center-users.txt \
      --from-file=ldap.txt=$TUTORIAL_HOME/ldap.txt \
      --save-config --dry-run=client -oyaml | kubectl apply -f -

In this above CLI command, you are generating the YAML for the secret, and applying it as an update to the existing secret ``credential``.

There's no need to restart the Kafka brokers or Control Center. The updates users list is picked up by the services.

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
