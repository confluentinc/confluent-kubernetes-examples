Deploy Confluent Platform with Load Balancer (IPv6)
============================================

In this scenario workflow, you'll set up Confluent Platform component clusters
with the Kubernetes LoadBalancer service type to enable external clients to
access Confluent Platform, including Kafka and other components, using IPv6 addressing.

Before continuing with the scenario, ensure that you have set up the
`prerequisites </README.md#prerequisites>`_.

Prerequisites
------------

1. An AWS EKS cluster with IPv6 enabled
2. AWS Load Balancer Controller installed in your cluster
3. External DNS configured for IPv6 records
4. Proper IAM roles and policies for AWS Load Balancer Controller
5. VPC with IPv6 CIDR block configured

To complete this tutorial, you'll follow these steps:

#. Set up the IPv6-enabled Kubernetes cluster for this tutorial.

#. Configure AWS Load Balancer Controller.

#. Set the current tutorial directory.

#. Deploy Confluent For Kubernetes.

#. Deploy Confluent Platform.

#. Tear down Confluent Platform.

===========================
Set up a Kubernetes cluster
===========================

Set up an IPv6-enabled Kubernetes cluster for this tutorial.

#. Ensure your EKS cluster has IPv6 enabled:

   ::

     aws eks describe-cluster --name <cluster-name> --query "cluster.kubernetesNetworkConfig.ipFamily"

   The output should show "ipv6"

#. Save the Kubernetes cluster domain name. 
 
   In this document, ``$DOMAIN`` is used to denote your Kubernetes cluster
   domain name.
  
   ::

     export DOMAIN=<Your Kubernetes cluster domain name>

#. Create a namespace for the test client to deploy the producer application: 

   ::
   
     kubectl create namespace confluent

==================================
Configure AWS Load Balancer Controller
==================================

#. Set up IAM permissions for AWS Load Balancer Controller:

   a. Create an IAM policy for the AWS Load Balancer Controller:
   
      - Create a new policy
      - Use the AWS Load Balancer Controller policy template or create a custom policy
      - The policy should include permissions for:
        * EC2 operations (describe instances, subnets, security groups, etc.)
        * Elastic Load Balancing operations (create/describe/modify load balancers and target groups)
        * IAM operations (create service-linked roles)
        * Route53 operations (if using DNS management)

   b. Create an IAM role for the AWS Load Balancer Controller:
   
      - Create a new IAM role
      - Select EKS as the trusted entity
      - Attach the policy created in step a
      - Note the role ARN for use in the next step

   c. Associate the IAM role with the AWS Load Balancer Controller service account:
   
      - Create a service account for the AWS Load Balancer Controller:
        ::

          eksctl create iamserviceaccount \
            --name aws-load-balancer-controller \
            --namespace kube-system \
            --cluster <cluster-name> \
            --attach-policy-arn arn:aws:iam::<AWS_ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
            --approve \
            --override-existing-serviceaccounts

      - Verify the service account was created and annotated with the IAM role:
        ::

          kubectl describe serviceaccount aws-load-balancer-controller -n kube-system

      - The output should show the IAM role ARN in the annotations section

#. Install AWS Load Balancer Controller:

   ::

    # Add and update the Helm repository for EKS charts
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update

    # Install or upgrade the AWS Load Balancer Controller using Helm
    # Note: serviceAccount.create=false because we created the service account using eksctl
    helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=${cluster_name}\
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region=${region} \
    --set vpcId=${vpc_id} \
    --set image.repository=602401143452.dkr.ecr.${region}.amazonaws.com/amazon/aws-load-balancer-controller

#. Verify the controller is running:

   ::

     kubectl get deployment -n kube-system aws-load-balancer-controller

==================================
Set the current tutorial directory
==================================

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

::
   
  export TUTORIAL_HOME=<Tutorial directory>/external-access-load-balancer-deploy-ipv6

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
Configure Confluent Platform
============================

You install Confluent Platform components as custom resources (CRs). 

You can configure all Confluent Platform components as custom resources. In this
tutorial, you will configure all components in a single file and deploy all
components with one ``kubectl apply`` command.

The CR configuration file contains a custom resource specification for each
Confluent Platform component, including replicas, image to use, resource
allocations.

Edit the Confluent Platform CR file: ``$TUTORIAL_HOME/confluent-platform.yaml``

Specifically, note that external accesses to Confluent Platform components are
configured using the AWS Load Balancer services with IPv6 support.

The Kafka section of the file is set as follow for load balancer access:

:: 

  Spec:
    listeners:
      external:
        externalAccess:
          type: loadBalancer
          loadBalancer:
            domain:      --- [1]
            annotations:
              service.beta.kubernetes.io/aws-load-balancer-type: "external"
              service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
              service.beta.kubernetes.io/aws-load-balancer-ip-address-type: "ipv4"
              service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"

Component section of the file is set as follows for load balancer access:

::

  spec:
    externalAccess:
      type: loadBalancer
      loadBalancer:
        domain:          --- [1]
        annotations:
          service.beta.kubernetes.io/aws-load-balancer-type: "external"
          service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
          service.beta.kubernetes.io/aws-load-balancer-ip-address-type: "ipv4"
          service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
          
* [1]  Set this to the value of ``$DOMAIN``, Your Kubernetes cluster domain. You need to provide this value for this tutorial.

* The prefixes are used for external DNS hostnames. In this tutorial,  Kafka bootstrap server will use the default prefix, ``kafka``, and the brokers will use the default prefix, ``b``. 

Kafka is configured with 3 replicas in this tutorial. So, the access endpoints
of Kafka will be:

* kafka.$DOMAIN for the bootstrap server
* b0.$DOMAIN for the broker #1
* b1.$DOMAIN for the broker #2
* b2.$DOMAIN for the broker #3

The access endpoint of each Confluent Platform component will be: 

::

  <Component CR name>.$DOMAIN

For example, in a browser, you will access Control Center at:

::

  http://controlcenter.$DOMAIN

=========================
Deploy Confluent Platform
=========================

#. Deploy Confluent Platform with the above configuration:

::

  kubectl apply -f $TUTORIAL_HOME/confluent-platform.yaml

#. Check that all Confluent Platform resources are deployed:

   ::
   
     kubectl get confluent

#. Get the status of any component. For example, to check Kafka:

   ::
   
     kubectl describe kafka

#. Verify that the external Load Balancer services have been created:

   ::
   
     kubectl get services
     
===============
Add DNS records
===============

Create DNS records for the externally exposed components:

#. Retrieve the external IPv6 addresses of bootstrap load balancers of the brokers and components:

   ::
   
     kubectl get svc
     
   Get the ``EXTERNAL-IP`` values (IPv6 addresses) of the following services from the output:
   
   * ``connect-bootstrap-lb``          
   * ``controlcenter-bootstrap-lb``   
   * ``kafka-0-lb``               
   * ``kafka-1-lb``                  
   * ``kafka-2-lb``                    
   * ``kafka-bootstrap-lb``          
   * ``ksqldb-bootstrap-lb``           
   * ``schemaregistry-bootstrap-lb`` 

#. Add AAAA DNS records for the components and the brokers using the IPv6 addresses and the hostnames above, replacing ``$DOMAIN`` with the actual domain name of your Kubernetes cluster.

   In this tutorial, we are using the default prefixes for components and brokers as shown below:
   
   ====================== ====================================================================
   DNS name               IPv6 address
   ====================== ====================================================================
   kafka.$DOMAIN          The IPv6 address of ``kafka-bootstrap-lb`` service
   b0.$DOMAIN             The IPv6 address of ``kafka-0-lb`` service
   b1.$DOMAIN             The IPv6 address of ``kafka-1-lb`` service
   b2.$DOMAIN             The IPv6 address of ``kafka-2-lb`` service
   controlcenter.$DOMAIN  The IPv6 address of ``controlcenter-bootstrap-lb`` service
   ksqldb.$DOMAIN         The IPv6 address of ``ksqldb-bootstrap-lb`` service
   connect.$DOMAIN        The IPv6 address of ``connect-bootstrap-lb`` service
   schemaregistry.$DOMAIN The IPv6 address of ``schemaregistry-bootstrap-lb`` service
   ====================== ====================================================================

Note: Ensure your DNS provider supports AAAA records for IPv6 addresses.

=========
Tear Down
=========

Shut down Confluent Platform and the data:

::

  kubectl delete -f $TUTORIAL_HOME/producer-app-data.yaml

::

  kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml

::

  helm delete operator
  
::

  kubectl delete namespace myclient
