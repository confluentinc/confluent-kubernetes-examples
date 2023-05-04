==========================================
Multi-site Deployment using CFK Blueprint
==========================================

This tutorial walks you through the configuration and deployment of Confluent
for Kubernetes (CFK) Blueprints in a multi-cluster environment. You will go
through the following scenarios:

#. Deploy the Control Plane.

#. Deploy the Data Plane in a separate cluster.

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
      
   .. sourcecode:: bash

      kubectl config rename-context <Kubernetes data plane context> data-plane
   
#. From the ``<CFK examples directory>`` on your local machine, clone the 
   example repo:

   .. sourcecode:: bash

      git clone git@github.com:confluentinc/confluent-kubernetes-examples.git

#. Set the tutorial directory for this tutorial:

   .. sourcecode:: bash

      export TUTORIAL_HOME=<CFK examples directory>/confluent-kubernetes-examples/blueprints-early-access/scenarios/quickstart-deploy
        
.. _deploy-control-plane: 

Deploy Control Plane  
----------------------

In the Kubernetes cluster you want to install the Control Plane, take the
following steps:

#. Set the current context to the Control Plane cluster:

   .. sourcecode:: bash
   
      kubectl config use-context control-plane

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

#. Create the Webhook certificate secret. ``webhooks-tls`` is used in this 
   tutorial:
      
   .. sourcecode:: bash

      $TUTORIAL_HOME/scripts/generate-keys.sh cpc-system /tmp
      
   .. sourcecode:: bash
    
      kubectl create secret generic webhooks-tls \
          --from-file=ca.crt=/tmp/cpc-ca.pem \
          --from-file=tls.crt=/tmp/server.pem \
          --from-file=tls.key=/tmp/server-key.pem \
          --namespace cpc-system \
          --context control-plane \
          --save-config --dry-run=client -oyaml | \
          kubectl apply -f -                     
 
#. Install the Orchestrator Helm chart:

   .. sourcecode:: bash

      helm repo add confluentinc https://packages.confluent.io/helm
      helm repo update

   .. sourcecode:: bash

      helm upgrade --install cpc-orchestrator confluentinc/cpc-orchestrator \
        --set image.pullPolicy="IfNotPresent" \
        --set debug=true \
        --namespace cpc-system \
        --kube-context control-plane 

.. _deploy-remote-data-plane: 

Deploy Remote Data Plane 
---------------------------

In the remote deployment mode, the Data Plane is installed in a different
Kubernetes cluster from the Control Plane cluster.

#. In the Control Plane, generate the Kubeconfig for the Agent to communicate 
   with the Orchestrator:

   .. sourcecode:: bash

      kubectl config use-context control-plane
      
   .. sourcecode:: bash

      $TUTORIAL_HOME/scripts/kubeconfig_generate.sh control-plane-sa cpc-system /tmp

#. In the Data Plane, create the KubeConfig secret:
   
   .. sourcecode:: bash
   
      kubectl config use-context data-plane

      kubectl create secret generic control-plane-kubeconfig \
        --from-file=kubeconfig=/tmp/kubeconfig \
        --context data-plane \
        --namespace cpc-system \
        --save-config --dry-run=client -oyaml | kubectl apply -f -

#. In the Data Plane, install the Agent.

   #. Create the namespace for the Blueprint system resources:

      .. sourcecode:: bash 
      
         kubectl create namespace cpc-system --context data-plane

   #. Install the Agent Helm chart in the ``Remote`` mode:

      .. sourcecode:: bash

         helm upgrade --install cpc-agent confluentinc/cpc-agent \
           --set image.pullPolicy="IfNotPresent" \
           --set mode=Remote \
           --set remoteKubeConfig.secretRef=control-plane-kubeconfig \
           --set debug=true \
           --kube-context data-plane \
           --namespace cpc-system

#. In the Data Plane, install the CFK Helm chart in the cluster mode 
   (``--set namespaced=false``):

   .. sourcecode:: bash

      helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
        --set namespaced="false" \
        --set debug=true \
        --kube-context data-plane \
        --namespace cpc-system

#. Register the Data Plane Kubernetes cluster with the Control Plane.
   
   #. In the Data Plane cluster, get the Kubernetes ID:
   
      .. sourcecode:: bash
   
         kubectl get namespace kube-system -oyaml --context data-plane | grep uid

   #. Edit ``$TUTORIAL_HOME/registration/data-plane-k8s.yaml`` and set 
      ``spec.k8sID`` to the Kubernetes ID from the previous step.
      
   #. In the Control Plane, create the KubernetesCluster and the HealthCheck 
      custom resource (CR):
   
      .. sourcecode:: bash

         kubectl apply -f $TUTORIAL_HOME/registration/data-plane-k8s.yaml \
           --context control-plane


.. _deploy-blueprint: 

Deploy Blueprint
---------------- 

Deploy the Blueprint and the Confluent cluster class CRs:

.. sourcecode:: bash

   kubectl apply -f $TUTORIAL_HOME/deployment/confluentplatform_blueprint.yaml \
     --context control-plane


.. _deploy-remote-cp:

Deploy Confluent Platform in Remote Data Plane 
----------------------------------------------

From the Control Plane cluster, deploy Confluent Platform.

#. Create the namespace ``org-confluent`` to deploy the Confluent Platform 
   clusters CR into:

   .. sourcecode:: bash

      kubectl create namespace org-confluent --context control-plane

#. Deploy Confluent Platform: 

   .. sourcecode:: bash

      kubectl create namespace confluent-dev --context data-plane

   .. sourcecode:: bash

      kubectl apply -f $TUTORIAL_HOME/deployment/data-plane/confluentplatform_dev.yaml \
        --context control-plane

   The Confluent components are installed into the ``confluent-dev`` namespace
   in the Data Plane.
   
#. In the Data Plane, validate the deployment using Control Center.

   #. Check when the Confluent components are up and running:
   
      .. sourcecode:: bash

         kubectl get pods --namespace confluent-dev --context data-plane -w
   
   #. Set up port forwarding to Control Center web UI from local machine:

      .. sourcecode:: bash

         kubectl port-forward controlcenter-0 9021:9021 --context data-plane --namespace confluent-dev

   #. Navigate to Control Center in a browser and check the cluster:

      .. sourcecode:: bash

         http://localhost:9021

#. In the Control Plane, uninstall Confluent Platform:

   .. sourcecode:: bash

      kubectl delete -f $TUTORIAL_HOME/deployment/data-plane/confluentplatform_dev.yaml \
        --context control-plane

Troubleshoot
-------------

* To check the states of the Operator and the Agent, run:

  .. sourcecode:: bash 

     kubectl get agent cpc-agent-install --namespace cpc-system --context control-plane -oyaml
     
  .. sourcecode:: bash 

     kubectl get cpchealthcheck --namespace cpc-system --context control-plane
