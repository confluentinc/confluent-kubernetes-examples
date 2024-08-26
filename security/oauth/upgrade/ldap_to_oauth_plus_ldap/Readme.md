## Introduction

In this example, we will upgrade a RBAC (by LDAP + SSO) cluster to RBAC (with OAuth+LDAP+SSO) cluster

## Pre-requisites

Follow [Sso](../../keycloak/) example to deploy keycloak

For this example I have added one of the SSO users to the LDAP server.

## Deploy Confluent for Kubernetes

1. Set up the Helm Chart:
```bash
   helm repo add confluentinc https://packages.confluent.io/helm
```
Note that it is assumed that your Kubernetes cluster has a ``confluent`` namespace available, otherwise you can create it by running ``kubectl create namespace confluent``. 

2.. Install Confluent For Kubernetes using Helm:
```bash
     helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace operator
```
3. Check that the Confluent For Kubernetes pod comes up and is running:
```bash    
     kubectl get pods --namespace operator
```

## Steps

1. Apply before.yaml to create a RBAC cluster with LDAP + SSO
2. Validate via login to C3 and make sure Kafka, connect & SR are visible
3. Apply after_1.yaml to create a RBAC cluster with OAuth + LDAP + SSO, this will upgrade the MDS cluster to validate both LDAP and OAuth tookens
4. After kafka role is complete, apply after_2.yaml to create a RBAC cluster with OAuth + LDAP + SSO, this will upgrade the rest of the components
4.1 Make sure `connect` configuration requires configOverride for sasl.jaas.config because of upgrade limiation in 7.7
5. We are doing upgrade in two steps to reduce failed restarts of components, one can do it in one step as well, but will face more restarts of components
6. Again login to C3, Kafka, SR & connect should be visible as before

Note:
1. We have disabled internal role binding creation for upgrade, as CFK as of today doesn't support updating role bindings, so we have to manually create role bindings for the users (internal for service to service communication)
2. We are using roll check disable for faster trying out this example, but this isn't required for this example.

## Tear down
1. delete setup 

    ```bash 
    kubectl delete -f after_1.yaml
    kubectl delete -f after_2.yaml
   ```