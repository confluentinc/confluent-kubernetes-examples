# Deploy CFK with mTLS and Load Balancer using Blueprint

This scenario uses the Control Plane and Data Plane you deployed in [Quick Start](../quickstart-deploy/single-site-deployment.rst) and creates a new Blueprint with the following features:

- mTLS authentication with encryption
- External access using Load Balancer

## Prerequisite
- Set the home directory for this tutorial:

  ```bash
  export SCENARIO_BASEPATH=<CFK examples directory>/confluent-kubernetes-examples/blueprints-early-access/scenario/cp-nonrbac-mtls-lb
  ```
  ```bash
  export MY_NAMESPACE=<your org namespace for this scenario>
  ``` 

- [Deploy the Control Plane with the Orchestrator](../quickstart-deploy/single-site-deployment.rst#deploy-control-plane).

- [Deploy the Data Plane with the Agent](../quickstart-deploy/single-site-deployment.rst#deploy-local-data-plane).

- The above setup creates the namespace for the Blueprint system resources, `cpc-system`.

## Install Blueprint

### Install Blueprint Certificate Authority (CA)

The Control Plane uses CA keypair to generate certificates for all the Confluent Platform component. Run the following commands:
1. Create a secret `ca-key-pair-sce-7` using the CA keypair generated when deploying [the Control Plane](../quickstart-deploy/single-site-deployment.rst#deploy-control-plane):

   ```bash 
   kubectl -n cpc-system create secret tls ca-key-pair-sce-7 --cert=/tmp/cpc-ca.pem --key=/tmp/cpc-ca-key.pem
   ```

1. Create the CertificateStoreConfig to inject CA keypair generated as above:

   ```bash 
   kubectl -n cpc-system apply -f $SCENARIO_BASEPATH/blueprint/certificatestoreconfig.yaml
   ```

### Install Blueprint Credentials

1. Create a secret object `cp-nonrbac-mtls-lb-bp-credentials` that contains all the required credential for the Blueprint:
   
   ```bash
   kubectl -n cpc-system create secret generic cp-nonrbac-mtls-lb-bp-credentials \
       --from-file=kafka-pwd-encoder.txt=$SCENARIO_BASEPATH/blueprint/credentials/kafka-pwd-encoder.txt  \
       --from-file=sr-pwd-encoder.txt=$SCENARIO_BASEPATH/blueprint/credentials/sr-pwd-encoder.txt  \
       --save-config --dry-run=client -oyaml | kubectl apply -f -
   ```

2. Create the credential store used by this Blueprint. The credential store is only used by this Blueprint and can't be share with other resource or Blueprints:

   ```bash
   kubectl apply -f $SCENARIO_BASEPATH/blueprint/credentialstoreconfig.yaml --namespace cpc-system
   ```

### Install Blueprint
  
```bash
kubectl apply -f $SCENARIO_BASEPATH/blueprint/blueprint.yaml --namespace cpc-system
```

## Deploy Confluent Platform in Single Site Deployment

1. Create the namespace for Confluent Platform:

   ```bash 
   kubectl create namespace $MY_NAMESPACE
   ```

1. Install Confluent Platform on the Control Plane cluster:
 
   ```bash 
   kubectl apply -f $SCENARIO_BASEPATH/cp-clusters/deployment_ss.yaml -n $MY_NAMESPACE
   ```

## Install Confluent Applications

### Topic
 
- Create a topic:

  ```bash 
  kubectl -n $MY_NAMESPACE apply -f $SCENARIO_BASEPATH/cp-apps/topics/topic.yaml
  ```
  
- Validate:

  ```bash 
  kubectl -n $MY_NAMESPACE get kafkatopics.apps topic-foo
  ```
  Verify that the `STATE` field is set to `Created`.

### Schema

- Create a schema: 

  ```bash
  kubectl -n $MY_NAMESPACE apply -f $SCENARIO_BASEPATH/cp-apps/schema/schema_ss.yaml
  ``` 
  
- Validate:

  ```bash
  kubectl -n $MY_NAMESPACE get schemas.app schema-foo-ss
  ``` 
  
  Verify that the `STATE` field is set to `Created`.

### Connector

- Create a connector:

  ```bash 
  kubectl -n $MY_NAMESPACE apply -f $SCENARIO_BASEPATH/cp-apps/connectors/connector_ss.yaml
  ```

- Validate:
  
  ```bash 
  kubectl -n $MY_NAMESPACE get connectors.apps
  ```
  
  Verify that the `STATE` field is set to `Created`.

## Validate the Deployment

1. Check when the Confluent components are up and running:
   
   ```bash 
   kubectl get pods --namespace $MY_NAMESPACE -w
   ```

1. Navigate to Control Center in a browser and check the cluster:

   1. Set up port forwarding to Control Center web UI from local machine:

      ```bash
      kubectl port-forward controlcenter-ss-0 9021:9021 --namespace $MY_NAMESPACE
      ```
      
   1. Navigate to Control Center in a browser and check the cluster:

      ```bash
      https://localhost:9021
      ```

   Log in as the `kafka` user with the `kafka-secret` password.
  
1. In Control Center, check if the `topic-foo-ss` topic exists.
