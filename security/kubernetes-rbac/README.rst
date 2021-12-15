Configure Kubernetes RBAC RoleBindings
======================================

To allow a user who does not have cluster-level access to deploy Operator and Confluent 
Platform in a namespace, perform the following tasks as a **Kubernetes cluster admin** before 
deploying Operator and Confluent Platform. The snippets in this section uses the ``confluent``
namespace.

Before continuing with the scenario, ensure that you have set up the
`prerequisites </README.md#prerequisites>`_.

#. Pull the Helm Chart contents to get the CRDs:
   
   ::
  
     mkdir -p <confluent-operator-contents-dir>
   
   ::

     helm pull confluentinc_earlyaccess/confluent-for-kubernetes \
     --untar --untardir=<confluent-operator-contents-dir>

#. Pre-install the CRDs with the following command:

   ::

     kubectl apply -f <confluent-operator-directory>/crds -n confluent


#. Create the ``rolebinding.yaml`` file with the permissions required for a namespaced deployment. 

   The content contains the minimum permissions required. Add any other resource
   permissions you might additionally require.

   Also, if required to have a custom service-account setup, make sure to pass the custom service-account name
   when deploying Confluent Operator through helm command: ``--set serviceAccount.create=false --set serviceAccount.name=<reference-service-account-name>``,    and update the ``namespaced-rolebinding.yaml`` accordingly to reflect the ``reference-service-account-name``.

   The role and role binding should be in the same namespace as Confluent Operator.

   The ``subject`` in the role binding must be the user/account existing in the
   given namespace.

   ::

     kubectl apply -f namespaced-rolebinding.yaml


Cluster Role and Role Binding
-----------------------------

If you want to install Cluster Role and RoleBinding, then the file to apply is 
``cluster-role-rolebinding.yaml`` in this directory.
