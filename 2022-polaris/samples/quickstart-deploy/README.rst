==============
Deploy Polaris
==============

This example will walk you through configuration of Polaris, including
deployment of the Control Plane, the Data Plane, and Blueprints.

#. Deploy the Control Plane in the control plane Kubernetes cluster.

#. Deploy the Data Plane.
  
   - To install and follow the local Data Plane scenario, deploy the Data
     Plane  in the same cluster as the Control Plane.
   
   - To install and follow the remote Data Plane scenario, deploy the Data 
     Plane in a separate Data Plane Kubernetes cluster.

Prepare  
-------------

#. Install Helm 3 on your local machine.

#. Install ``kubectl`` command-line tool on your local machine.

#. Set up the Kubernetes clusters you want to use for the Control Plane and the
   Data Plane. Kubernetes versions 1.22+ are required.
   
#. Rename the Kubernetes contexts for easy identification:

   .. sourcecode:: bash
   
      kubectl config rename-context <Kubernetes control plane context> control-plane
      
      kubectl config rename-context <Kubernetes data plane context> data-plane
   
#. Set the Polaris home directory:

   .. sourcecode:: bash
   
      export CPC_HOME=<Directory to install Polaris>

#. From the ``<CFK examples directory>`` on your local machine, clone this 
   example repo:

   .. sourcecode:: bash

      git clone git@github.com:confluentinc/confluent-kubernetes-examples.git

#. Set the tutorial directory for this tutorial:

   .. sourcecode:: bash

      export TUTORIAL_HOME=<CFK examples directory>/confluent-kubernetes-examples/2022-polaris/samples/quickstart-deploy
   
.. _deploy-control-plane: 

Install Control Plane  
----------------------

In the Kubernetes cluster you want to install the Control Plane on, take the
following steps:

#. Set the current context to the Control Plane cluster:

   .. sourcecode:: bash
   
      kubectl config use-context control-plane

#. Create a namespace for the Polaris system resources. ``cpc-system`` is used 
   in these examples:

   .. sourcecode:: bash

      kubectl create namespace cpc-system 

#. Install the Orchestrator CRDs:

   .. sourcecode:: bash

      kubectl apply -f $CPC_HOME/cpc-orchestrator/charts/cpc-orchestrator/crds

#. Generate the KubeConfig file for the remote Data Planes to connect:

   .. sourcecode:: bash

      $TUTORIAL_HOME/scripts/kubeconfig_generate.sh mothership-sa cpc-system /tmp

#. Create a Docker Registry secret for the image repository. 
   ``confluent-registry`` is used in these examples.

   #. Get a token:
   
      .. sourcecode:: bash

         gimme-aws-creds 

   #. Create a Docker registry secret:

      .. sourcecode:: bash

         export ECR_USERNAME=AWS 
         export ECR_PASSWORD=$(aws ecr get-login-password --region us-west-2 --profile devprod-prod) 
         export EMAIL=@confluent.io

         kubectl -n cpc-system create secret docker-registry confluent-registry \
           --docker-server=519856050701.dkr.ecr.us-west-2.amazonaws.com \
           --docker-username=$ECR_USERNAME \
           --docker-password=$ECR_PASSWORD \
           --docker-email=$EMAIL \
           --context control-plane \
           --namespace cpc-system                                
 
#. Create a Webhook certificate secret. ``webhooks-tls`` is used in these 
   examples:

   .. sourcecode:: bash
   
      mkdir /tmp
      
      $TUTORIAL_HOME/scripts/generate-keys.sh cpc-system /tmp
      
      kubectl create secret generic webhooks-tls \
          --from-file=ca.crt=/tmp/ca.pem \
          --from-file=tls.crt=/tmp/server.pem \
          --from-file=tls.key=/tmp/server-key.pem \
          --namespace cpc-system \
          --context control-plane \
          --save-config --dry-run=client -oyaml | \
          kubectl apply -f -                     
 
#. Install the Orchestrator Helm chart:

   .. sourcecode:: bash

      helm upgrade --install cpc-orchestrator $CPC_HOME/cpc-orchestrator/charts/cpc-orchestrator \
        --namespace cpc-system \
        --set image.registry="519856050701.dkr.ecr.us-west-2.amazonaws.com/docker/prod" \
        --set image.repository="confluentinc/cp-cpc-operator" \
        --set image.tag="latest" \
        --set image.pullPolicy="IfNotPresent" \
        --set imagePullSecretRef="confluent-registry"

#. Review and deploy the Blueprint and the Confluent cluster class CRs:

   .. sourcecode:: bash

      kubectl apply -f $TUTORIAL_HOME/deployment/confluentplatform_blueprint.yaml
      kubectl apply -f $TUTORIAL_HOME/deployment/zookeepercluster_class.yaml
      kubectl apply -f $TUTORIAL_HOME/deployment/controlcentercluster_class.yaml
      kubectl apply -f $TUTORIAL_HOME/deployment/connectcluster_class.yaml
      kubectl apply -f $TUTORIAL_HOME/deployment/ksqldbcluster_class.yaml
      kubectl apply -f $TUTORIAL_HOME/deployment/schemaregistrycluster_class.yaml
      kubectl apply -f $TUTORIAL_HOME/deployment/kafkacluster_class.yaml

.. _deploy-local-data-plane: 

Deploy a local Data Plane
-------------------------- 

For the local deployment, install the Data Plane in the same Kubernetes cluster
where the Control Plane was installed.

#. Register the Data Plane Kubernetes cluster.
   
   #. Get the Kubernetes ID:
   
      .. sourcecode:: bash
   
         kubectl get namespace kube-system -oyaml | grep uid

   #. Edit ``$TUTORIAL_HOME/registration/kubernetes_cluster_mothership.yaml`` 
      and set ``spec.k8sID`` to the Kubernetes ID retrieved in the previous 
      step.
      
   #. Create the KubernetesCluster CR in the control Plane Kubernetes cluster:
   
      .. sourcecode:: bash

         kubectl apply -f $TUTORIAL_HOME/registration/kubernetes_cluster_mothership.yaml

   #. Create the HealthCheck CR in the Control Plane Kubernetes cluster. Its 
      spec has the reference to the Kubernetes Cluster reference you created in 
      the previous step:
      
      .. sourcecode:: bash

         kubectl apply -f $TUTORIAL_HOME/registration/healthcheck_mothership.yaml

#. Install the Agent.

   #. Apply the Agent CRDs:

      .. sourcecode:: bash

         kubectl apply -f $CPC_HOME/cpc-agent/charts/cpc-agent/crds

   #. Install the Agent Helm chart in the ``Local`` mode:
   
      .. sourcecode:: bash
   
         helm upgrade --install cpc-agent $CPC_HOME/cpc-agent/charts/cpc-agent \
           --namespace cpc-system \
           --set mode=Local \
           --set image.registry="519856050701.dkr.ecr.us-west-2.amazonaws.com/docker/prod" \
           --set image.repository="confluentinc/cp-cpc-operator" \
           --set image.tag="latest" \
           --set image.pullPolicy="IfNotPresent" \
           --set imagePullSecretRef="confluent-registry"

#. Install the CFK Helm chart in the cluster mode (``--set namespaced=false``):
  
   .. sourcecode:: bash

      helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
        --set namespaced=false \
        --namespace cpc-system

--------------------------
Install Confluent Platform 
-------------------------- 

From the Control Plane cluster, deploy Confluent Platform.

#. Create the namespace to deploy Confluent components into.  ``org-confluent`` 
   is used in these examples:

   .. sourcecode:: bash
     
      kubectl create namespace org-confluent

#. Deploy Confluent Platform: 

   .. sourcecode:: bash

      kubectl apply -f $TUTORIAL_HOME/deployment/mothership/zookeeper_cluster_mothership.yaml
      kubectl apply -f $TUTORIAL_HOME/deployment/mothership/kafka_cluster_mothership.yaml
      kubectl apply -f $TUTORIAL_HOME/deployment/mothership/connect_cluster_mothership.yaml
      kubectl apply -f $TUTORIAL_HOME/deployment/mothership/ksqldb_cluster_mothership.yaml
      kubectl apply -f $TUTORIAL_HOME/deployment/mothership/schemaregistry_cluster_mothership.yaml
      kubectl apply -f $TUTORIAL_HOME/deployment/mothership/controlcenter_cluster_mothership.yaml
      
#. Validate the deployment using Control Center.

   #. Check when the Confluent components are up and running.
   
   #. Set up port forwarding to Control Center web UI from local machine:

      .. sourcecode:: bash

         kubectl port-forward controlcenter-prod-0 9021:9021 --namespace org-confluent

   #. Navigate to Control Center in a browser:

      .. sourcecode:: bash

         http://localhost:9021
   
#. Uninstall Confluent Platform:

   .. sourcecode:: bash

      kubectl delete -f $TUTORIAL_HOME/deployment/mothership/zookeeper_cluster_mothership.yaml
      kubectl delete -f $TUTORIAL_HOME/deployment/mothership/kafka_cluster_mothership.yaml
      kubectl delete -f $TUTORIAL_HOME/deployment/mothership/connect_cluster_mothership.yaml
      kubectl delete -f $TUTORIAL_HOME/deployment/mothership/ksqldb_cluster_mothership.yaml
      kubectl delete -f $TUTORIAL_HOME/deployment/mothership/schemaregistry_cluster_mothership.yaml
      kubectl delete -f $TUTORIAL_HOME/deployment/mothership/controlcenter_cluster_mothership.yaml

.. _deploy-remote-data-plane: 

Deploy a remote Data Plane 
---------------------------

In the remote deployment mode, the Data Plane is installed in a different
Kubernetes cluster from the Control Plane cluster.

#. Register the Data Plane Kubernetes cluster with the Control Plane.
   
   #. In the Data Plane cluster, get the Kubernetes ID:
   
      .. sourcecode:: bash
   
         kubectl get namespace kube-system -oyaml --context data-plane | grep uid

   #. In the Control Plane, edit 
      ``registration/kubernetes_cluster_sat-1.yaml`` and set ``spec.k8sID`` 
      to the Kubernetes ID from previous step.
      
   #. In the Control Plane, create the KubernetesCluster CR:
   
      .. sourcecode:: bash

         kubectl apply -f $TUTORIAL_HOME/registration/kubernetes_cluster_sat-1.yaml --context control-plane

   #. In the Control Plane, create the HealthCheck CR in the Control Plane 
      Kubernetes cluster. Its spec has the reference to the Kubernetes Cluster 
      reference you created in the previous step:
      
      .. sourcecode:: bash

         kubectl apply -f $TUTORIAL_HOME/registration/healthcheck_sat-1.yaml --context control-plane

#. In the Data Plane, create the required secrets.

   #. Create a Docker Registry secret for the image repository. 
      ``confluent-registry`` is used in these examples.
   
      #. Get a token:
      
         .. sourcecode:: bash
   
            gimme-aws-creds 
   
      #. Create a Docker registry secret:
   
         .. sourcecode:: bash
   
            export ECR_USERNAME=AWS 
            export ECR_PASSWORD=$(aws ecr get-login-password --region us-west-2 --profile devprod-prod) 
            export EMAIL=@confluent.io
   
            kubectl -n cpc-system create secret docker-registry confluent-registry \
              --docker-server=519856050701.dkr.ecr.us-west-2.amazonaws.com \
              --docker-username=$ECR_USERNAME \
              --docker-password=$ECR_PASSWORD \
              --docker-email=$EMAIL \
              --context data-plane \
              --namespace cpc-system                                
   
   #. Create the KubeConfig secret:
   
      .. sourcecode:: bash
      
         kubectl create secret generic mothership-kubeconfig \
           --from-file=kubeconfig=/tmp/kubeconfig \
           --context data-plane \
           --namespace cpc-system 

#. In the Data Plane, install the Agent.

   #. Create the namespace for the Polaris system resources:

      .. sourcecode:: bash 
      
         kubectl create namespace cpc-system --context data-plane

   #. Apply the Agent CRDs:

      .. sourcecode:: bash

         kubectl apply -f $CPC_HOME/cpc-agent/charts/cpc-agent/crds --context data-plane

   #. Install the Agent Helm chart in the ``Remote`` mode:

      .. sourcecode:: bash

         helm upgrade --install \
           cpc-agent $CPC_HOME/cpc-agent/charts/cpc-agent \
           --set mode=Remote \
           --set remoteKubeConfig.secretRef=mothership-kubeconfig \
           --kube-context data-plane \
           --set image.registry="519856050701.dkr.ecr.us-west-2.amazonaws.com/docker/prod" \
           --set image.repository="confluentinc/cp-cpc-operator" \
           --set image.tag="latest" \
           --set image.pullPolicy="IfNotPresent" \
           --set imagePullSecretRef="confluent-registry" \
           --namespace cpc-system

#. In the Data Plane, install the CFK Helm chart in the cluster mode 
   (``--set namespaced=false``):

   .. sourcecode:: bash

      helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
        --set namespaced=false \
        --kube-context data-plane \
        --namespace cpc-system

--------------------------
Install Confluent Platform 
-------------------------- 

From the Control Plane cluster, deploy Confluent Platform.

#. Create the namespace ``org-confluent`` to deploy Confluent Platform clusters 
   CR into:

   .. sourcecode:: bash

      kubectl create namespace org-confluent --context control-plane

#. Deploy Confluent Platform: 

   .. sourcecode:: bash

      kubectl apply -f $TUTORIAL_HOME/deployment/sat-1/zookeeper_cluster_sat-1.yaml --context control-plane
      kubectl apply -f $TUTORIAL_HOME/deployment/sat-1/kafka_cluster_sat-1.yaml --context control-plane
      kubectl apply -f $TUTORIAL_HOME/deployment/sat-1/connect_cluster_sat-1.yaml --context control-plane
      kubectl apply -f $TUTORIAL_HOME/deployment/sat-1/ksqldb_cluster_sat-1.yaml --context control-plane
      kubectl apply -f $TUTORIAL_HOME/deployment/sat-1/schemaregistry_cluster_sat-1.yaml --context control-plane
      kubectl apply -f $TUTORIAL_HOME/deployment/sat-1/controlcenter_cluster_sat-1.yaml --context control-plane

   The Confluent components are installed into the ``confluent-dev`` namespace
   in the Data Plane.
   
#. In the Data Plane, validate the deployment using Control Center.

   #. Check when the Confluent components are up and running.
   
   #. Set up port forwarding to Control Center web UI from local machine:

      .. sourcecode:: bash

         kubectl port-forward controlcenter-dev-0 9021:9021 --context data-plane --namespace confluent-dev

   #. Navigate to Control Center in a browser:

      .. sourcecode:: bash

         http://localhost:9021

#. In the Control Plane, uninstall Confluent Platform:

   .. sourcecode:: bash

      kubectl delete -f $TUTORIAL_HOME/deployment/sat-1/zookeeper_cluster_sat-1.yaml --context control-plane
      kubectl delete -f $TUTORIAL_HOME/deployment/sat-1/kafka_cluster_sat-1.yaml --context control-plane
      kubectl delete -f $TUTORIAL_HOME/deployment/sat-1/connect_cluster_sat-1.yaml --context control-plane
      kubectl delete -f $TUTORIAL_HOME/deployment/sat-1/ksqldb_cluster_sat-1.yaml --context control-plane
      kubectl delete -f $TUTORIAL_HOME/deployment/sat-1/schemaregistry_cluster_sat-1.yaml --context control-plane
      kubectl delete -f $TUTORIAL_HOME/deployment/sat-1/controlcenter_cluster_sat-1.yaml --context control-plane

