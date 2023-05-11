==========================================
Single-site Deployment using CFK Blueprint 
==========================================

This tutorial walks you through the configuration and deployment of Confluent
for Kubernetes (CFK) Blueprints in a single-site environment where the
Control Plane and Data Plane run in the same cluster. For clarity, we will call
out the Control Plane and Data Plane separately. You will go through the
following scenarios. 

#. Deploy the Control Plane.

#. Deploy the local Data Plane in the same cluster as the Control Plane.
   
#. Deploy the Blueprint in the Control Plane.

#. Using the Blueprint, deploy Confluent Platform in the Data Plane. 

Prepare  
-------------

#. Install Helm 3 on your local machine.

#. Install ``kubectl`` command-line tool on your local machine.

#. Install `cfssl <https://github.com/cloudflare/cfssl/releases/tag/v1.6.3>`__ 
   on your local machine.

#. Have the Kubernetes clusters you want to use for the Control Plane and the
   Data Plane. Kubernetes versions 1.22+ are required.
   
#. Rename the Kubernetes contexts for easy identification:

   .. sourcecode:: bash
   
      kubectl config rename-context <Kubernetes control plane context> control-plane
         
#. From the ``<CFK examples directory>`` on your local machine, clone the 
   example repo:

   .. sourcecode:: bash

      git clone git@github.com:confluentinc/confluent-kubernetes-examples.git

#. Set the tutorial directory for this tutorial:

   .. sourcecode:: bash

      export TUTORIAL_HOME=<CFK examples directory>/blueprints/quickstart-deploy
        
.. _deploy-control-plane: 

Deploy Control Plane  
----------------------

In the Kubernetes cluster you want to install the Control Plane, take the
following steps:

#. Create a namespace for the Blueprint system resources. ``cpc-system`` is used 
   in these examples:

   .. sourcecode:: bash

      kubectl create namespace cpc-system --context control-plane

#. Create a CA key pair to be used for the Blueprint and the Orchestrator:

   .. sourcecode:: bash

      cat << EOF > openssl.cnf
      [req]
      distinguished_name=dn
      [ dn ]
      [ v3_ca ]
      basicConstraints = critical,CA:TRUE
      subjectKeyIdentifier = hash
      authorityKeyIdentifier = keyid:always,issuer:always
      EOF
      
   If ``/tmp`` does not exist in your local system, create the folder:
     
   .. sourcecode:: bash
   
      mkdir /tmp

   Generate a CA key pair: 
   
   .. sourcecode:: bash

      openssl req -x509 -new -nodes -newkey rsa:4096 -keyout /tmp/cpc-ca-key.pem \
        -out /tmp/cpc-ca.pem \
        -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=CPC/CN=CPC-CA" \
        -reqexts v3_ca \
        -config openssl.cnf

#. Install the Orchestrator Helm chart:

   .. sourcecode:: bash

      helm repo add confluentinc https://packages.confluent.io/helm
      helm repo update

   .. sourcecode:: bash

      helm upgrade --install confluent-orchestrator confluentinc/cfk-blueprint \
        --set orchestrator.enabled=true \
        --namespace cpc-system \
        --kube-context control-plane 
        
.. _deploy-local-data-plane: 

Deploy Local Data Plane
-------------------------- 

For the local deployment, install the Data Plane in the same Kubernetes cluster
where the Control Plane is installed.

#. Install the Agent Helm chart in the ``Local`` mode:
   
   .. sourcecode:: bash

      helm upgrade --install confluent-agent confluentinc/cfk-blueprint \
       --set agent.mode=Local \
       --set agent.enabled=true \
       --namespace cpc-system \
       --kube-context control-plane 
 
#. Register the Data Plane Kubernetes cluster.
   
   #. Get the Kubernetes ID:
   
      .. sourcecode:: bash
   
         kubectl get namespace kube-system -oyaml | grep uid

   #. Edit ``$TUTORIAL_HOME/registration/control-plane-k8s.yaml`` 
      and set ``spec.k8sID`` to the Kubernetes ID retrieved in the previous 
      step.
      
   #. Create the KubernetesCluster custom resource (CR) and the HealthCheck CR 
      in the Control Plane Kubernetes cluster:
   
      .. sourcecode:: bash

         kubectl apply -f $TUTORIAL_HOME/registration/control-plane-k8s.yaml \
           --context control-plane --namespace cpc-system
           
   #. Verify that the Agent is up and running:
   
      .. sourcecode:: bash

         kubectl get cpcHealthCheck \
           --context control-plane --namespace cpc-system

#. Install the CFK Helm chart in the cluster mode (``--set namespaced=false``):
  
   .. sourcecode:: bash

      helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
        --set namespaced="false" \
        --namespace cpc-system \
        --kube-context control-plane 

.. _deploy-blueprint: 

Deploy Blueprint
---------------- 

Deploy the Blueprint and the Confluent cluster class CRs:

.. sourcecode:: bash

   kubectl apply -f $TUTORIAL_HOME/deployment/confluentplatform_blueprint.yaml \
     --context control-plane --namespace cpc-system

.. _deploy-local-cp:

Deploy Confluent Platform in Local Data Plane 
----------------------------------------------

#. Create the namespace to deploy Confluent components into.  ``org-confluent`` 
   is used in these examples:

   .. sourcecode:: bash
     
      kubectl create namespace org-confluent --context control-plane

#. Deploy Confluent Platform: 

   .. sourcecode:: bash

      kubectl apply -f $TUTORIAL_HOME/deployment/control-plane/confluentplatform_prod.yaml \
        --namespace org-confluent \
        --context control-plane
      
#. Validate the deployment.

   #. Check when the Confluent components are up and running:
   
      .. sourcecode:: bash

         kubectl get pods --namespace org-confluent --context control-plane -w

   #. Set up port forwarding to Control Center web UI from local machine:

      .. sourcecode:: bash

         kubectl port-forward controlcenter-prod-0 9021:9021 --context control-plane --namespace org-confluent

   #. Navigate to Control Center in a browser and check the cluster:

      `http://localhost:9021 <http://localhost:9021>`__

#. Uninstall Confluent Platform:

   .. sourcecode:: bash

      kubectl delete -f $TUTORIAL_HOME/deployment/control-plane/confluentplatform_prod.yaml \
        --namespace org-confluent \
        --context control-plane

