## Introduction

As part of this setup we will move OAUTH + LDAP to just OAUTH

## Pre-requisite

Follow [Sso](../../keycloak/) example to deploy keycloak

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
1. follow the steps in [upgrade/oauth_plus_ldap_to_just_oauth](../oauth_plus_ldap_to_just_oauth/Readme.md)
2. remove ldap by applying just_oauth.yaml