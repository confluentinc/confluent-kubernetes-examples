# Deploy CFK with SASL/PLAIN and Ingress using Blueprint

This scenario uses the Control Plane and Data Plane you deployed in [Quick Start](../quickstart-deploy/single-site-deployment.rst) and creates a new Blueprint with the following features:

- SASL/PLAIN authentication with encryption
- External access using Ingress

## Prerequisite
1. Set the home directory for this tutorial:

   ```bash
   export SCENARIO_BASEPATH=<CFK examples directory>/confluent-kubernetes-examples/blueprints/cp-nonrbac-saslplain-ingress
   ```
  
1. Set the namespace to deploy Confluent Platform in:

   ```bash
   export MY_NAMESPACE=<your org namespace for this scenario>
   ``` 

1. Save the Kubernetes cluster domain name:
 
   In this document, `$DOMAIN` is used to denote your Kubernetes cluster domain name.
  
   ```bash
   export DOMAIN=<Your Kubernetes cluster domain name>
   ```

1. [Deploy the Control Plane with the Orchestrator](../quickstart-deploy/single-site-deployment.rst#deploy-control-plane).

1. [Deploy the Data Plane with the Agent](../quickstart-deploy/single-site-deployment.rst#deploy-local-data-plane).

   The above setup creates the namespace for the Blueprint system resources, `cpc-system`.

1. Install Ingress controller:

   ```bash
   helm repo add nginx-stable https://helm.nginx.com/stable
   
   helm repo update
   
   helm upgrade --install my-nginx nginx-stable/nginx-ingress \
     --set controller.publishService.enabled=true \
     --set controller.extraArgs.enable-ssl-passthrough="true"
   ```

## Install Blueprint

### Install Blueprint Certificate Authority (CA)

The Control Plane uses CA keypair to generate certificates for all the Confluent Platform component. Run the following commands:
1. Create a secret `ca-key-pair-sce-5` using the CA keypair generated when deploying [the Control Plane](../quickstart-deploy/single-site-deployment.rst#deploy-control-plane):

   ```bash 
      kubectl -n cpc-system create secret tls  ca-key-pair-sce-5 --cert=/tmp/cpc-ca.pem --key=/tmp/cpc-ca-key.pem
   ```

1. Create the CertificateStoreConfig to inject CA keypair generated as above:

   ```bash 
   kubectl -n cpc-system apply -f $SCENARIO_BASEPATH/blueprint/certificatestoreconfig.yaml
   ```

### Install Blueprint Credentials

1. Create a secret object `cp-nonrbac-saslplain-ingress-bp credentials` that contains all the required credential for for the Blueprint:
   
   ```bash
    kubectl create secret generic cp-nonrbac-saslplain-ingress-bp-credentials \
    --from-file=kafka-pwd-encoder.txt=$SCENARIO_BASEPATH/blueprint/credentials/kafka-pwd-encoder.txt  \
    --from-file=sr-pwd-encoder.txt=$SCENARIO_BASEPATH/blueprint/credentials/sr-pwd-encoder.txt  \
    --from-file=kafka-server-listener-internal-plain-users.json=$SCENARIO_BASEPATH/blueprint/credentials/kafka-server-listener-internal-plain-users.json \
    --from-file=kafka-server-listener-external-plain-users.json=$SCENARIO_BASEPATH/blueprint/credentials/kafka-server-listener-external-plain-users.json \
    --save-config --dry-run=client -oyaml | kubectl apply -f -
   ```

1. Create the credential store used by this Blueprint. The credential store is only used by this Blueprint and can't be share with other resource or Blueprints:

   ```bash
   kubectl apply -f $SCENARIO_BASEPATH/blueprint/credentialstoreconfig.yaml --namespace cpc-system
   ```

### Install Blueprint
  
1. Edit the `$SCENARIO_BASEPATH/blueprint/blueprint.yaml` file and set the Kubernetes domain to the value of `$DOMAIN`:

   ```yaml
   apiVersion: core.cpc.platform.confluent.io/v1beta1
   kind: ConfluentPlatformBlueprint
   spec:
     dnsConfig:
       domain: #Set this to the value of $DOMAIN
   ```

1. Install the Blueprint:

   ```bash
   kubectl apply -f $SCENARIO_BASEPATH/blueprint/blueprint.yaml --namespace cpc-system
   ```

## Deploy Confluent Platform in Single Site Deployment

1. Create the namespace for Confluent Platform:

   ```bash 
   kubectl create namespace $MY_NAMESPACE
   ```
   
1. Create a secret that contains all the required credential on namespace `MY_NAMESPACE`:

   ```bash 
   kubectl -n $MY_NAMESPACE create secret generic cp-credentials \
   --from-file=connect-client-plain.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/connect-client-plain.txt \
   --from-file=controlcenter-clientplain.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/controlcenter-client-plain.txt \
   --from-file=kafkarestproxy-clientplain.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/kafkarestproxy-client-plain.txt \
   --from-file=ksqldb-client-plain.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/ksqldb-client-plain.txt \
   --from-file=schemaregistry-clientplain.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/schemaregistry-client-plain.txt \
   --save-config --dry-run=client -oyaml | kubectl apply -f -
   ```

1. Install CP Deployment Credential:

   ```bash 
   kubectl apply -f $SCENARIO_BASEPATH/cp-clusters/credentialstoreconfig.yaml -n $MY_NAMESPACE
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

      [https://localhost:9021](https://localhost:9021)

     Log in as the `kafka` user with the `kafka-secret` password.
  
1. In Control Center, check if the `topic-foo` topic exists.
