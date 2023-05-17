# Deploy CFK with RBAC, mTLS, and Load Balancer using Blueprint

This scenario uses the Control Plane and Data Plane you deployed in [Quick Start](../quickstart-deploy/single-site-deployment.rst) and creates a new Blueprint with the following features:

- mTLS authentication
- Confluent Platform RBAC 
- External access using Load Balancer
- Custom Kafka listeners and its credential coming from deployment API

## Prerequisite
- Set the home directory for this tutorial:

  ```bash
  export SCENARIO_BASEPATH=<CFK examples directory>/confluent-kubernetes-examples/blueprints/cp-rbac-mtls-lb
  ```

- Set the namespace to deploy Confluent Platform in:

  ```bash
  export MY_NAMESPACE=<your org namespace>
  ``` 

- Save the Kubernetes cluster domain name:
 
  In this document, `$DOMAIN` is used to denote your Kubernetes cluster domain name.
 
  ```bash
  export DOMAIN=<Your Kubernetes cluster domain name>
  ```

- [Deploy the Control Plane with the Orchestrator](../quickstart-deploy/single-site-deployment.rst#deploy-control-plane).

- [Deploy the Data Plane with the Agent](../quickstart-deploy/single-site-deployment.rst#deploy-local-data-plane).

- The above setup creates the namespace for the Blueprint system resources, `cpc-system`.

### Deploy OpenLDAP
This repo includes a Helm chart for OpenLdap. The chart `values.yaml` includes the set of principal definitions that Confluent Platform needs for Confluent Platform RBAC.

1. Deploy OpenLdap:

   ```bash
   helm upgrade --install -f $SCENARIO_BASEPATH/../../assets/openldap/ldaps-rbac.yaml test-ldap $SCENARIO_BASEPATH/../../assets/openldap --namespace cpc-system
   ```

1. Validate that OpenLDAP is running:

   ```bash
   kubectl get pods --namespace cpc-system
   ```

## Install Blueprint

### Install Blueprint Certificate Authority (CA)

The Control Plane uses CA keypair to generate the certificates for all the Confluent Platform
components. 

To create the required CA, run the following commands:

1. Create a secret `ca-key-pair-sce-2` using the CA keypair generated when deploying [the Control Plane](../quickstart-deploy/single-site-deployment.rst#deploy-control-plane):

   ```bash
   kubectl -n cpc-system create secret tls  ca-key-pair-sce-2 --cert=/tmp/cpc-ca.pem --key=/tmp/cpc-ca-key.pem
   ```

2. Create the CertificateStoreConfig to inject the CA keypair generated as above:

   ```bash
   kubectl apply -f $SCENARIO_BASEPATH/blueprint/certificatestoreconfig.yaml --namespace cpc-system
   ```

### Install Blueprint Credentials

- Create a secret object, `cp-rbac-mtls-lb-bp-credentials`, that contains all the required credential for the Blueprint:

  ```bash
  kubectl -n cpc-system create secret generic cp-rbac-mtls-lb-bp-credentials \
  --from-file=mds-token-key.txt=$SCENARIO_BASEPATH/blueprint/credentials/mds-token-key.txt \
  --from-file=mds-public-key.txt=$SCENARIO_BASEPATH/blueprint/credentials/mds-public-key.txt \
  --from-file=$SCENARIO_BASEPATH/blueprint/credentials/client-bearer.txt \
  --from-file=idp-simple.txt=$SCENARIO_BASEPATH/blueprint/credentials/idp-simple.txt  \
  --from-file=kafka-pwd-encoder.txt=$SCENARIO_BASEPATH/blueprint/credentials/kafka-pwd-encoder.txt  \
  --from-file=sr-pwd-encoder.txt=$SCENARIO_BASEPATH/blueprint/credentials/sr-pwd-encoder.txt  \
  --save-config --dry-run=client -oyaml | kubectl apply -f -
  ```

- Create the credential store used by this Blueprint. The credential store is only used by this Blueprint and can't be share with other resource or Blueprints:

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
2. Install Confluent Platform:

   ```bash
   kubectl apply -f $SCENARIO_BASEPATH/cp-clusters/deployment_ss.yaml -n $MY_NAMESPACE
   ```

## Install Confluent Applications

### Topic
 
1. Create a topic:

   ```bash 
   kubectl -n $MY_NAMESPACE apply -f $SCENARIO_BASEPATH/cp-apps/topics/topic_ss.yaml
   ```
  
1. Validate:

   ```bash 
   kubectl -n $MY_NAMESPACE get kafkatopics.apps topic-foo-ss
   ```
   Verify that the `STATE` field is set to `Created`.

### Rolebindings

1. Before creating role bindings, make sure that the cluster ids exist for Schema Registry, Connect, and ksqlDB:

   ```bash 
   kubectl -n $MY_NAMESPACE get schemaregistrycluster -oyaml | grep schemaRegistryClusterId
   ```
   
   ```bash 
   kubectl -n $MY_NAMESPACE get connectcluster -oyaml | grep connectClusterId
   ``` 
   
   ```bash 
   kubectl -n $MY_NAMESPACE get ksqldbcluster -oyaml | grep ksqlClusterId
   ``` 
1. Create role bindings: 

   ```bash 
   cat ${SCENARIO_BASEPATH}/cp-apps/rolebinding/rolebiding_ss.yaml | sed 's/__NAMESPACE__/'"${MY_NAMESPACE}"'/g' | kubectl apply -f -
   ```
 
1. Validate:
 
   ```bash
   kubectl -n $MY_NAMESPACE get confluentrolebindings.apps
   ```

   Verify that the `STATE` field is set to `Created`.

### Schema

1. Create the required role binding:

   ```bash
   cat $SCENARIO_BASEPATH/cp-apps/schema/rolebinding_ss.yaml | sed 's/__NAMESPACE__/'"$MY_NAMESPACE"'/g' | kubectl apply -f -
   ```
  
1. Check Resource and verify that the `STATE` field is set to `Created`:

   ```bash
   kubectl -n ${MY_NAMESPACE} get confluentrolebindings.apps user-kafka-rb-sr-ss
   ``` 
   
1. Create a schema: 

   ```bash
   kubectl -n $MY_NAMESPACE apply -f $SCENARIO_BASEPATH/cp-apps/schema/schema_ss.yaml
   ``` 
  
1. Validate:

   ```bash
   kubectl -n $MY_NAMESPACE get schemas.app schema-foo-ss
   ``` 
   
   Verify that the `STATE` field is set to `Created`.

### Connector

1. Create the required role binding:

   ```bash
   cat $SCENARIO_BASEPATH/cp-apps/connectors/rolebinding_ss.yaml | sed 's/__NAMESPACE__/'"$MY_NAMESPACE"'/g' | kubectl apply -n ${MY_NAMESPACE} -f -      
   ```
   
1. Check Resource and verify that the `STATE` field is set to `Created`:

   ```bash 
   kubectl -n ${MY_NAMESPACE} get confluentrolebindings.apps user-kafka-rb-connect-ss
   ``` 
   
1. Create a connector:

   ```bash 
   cat $SCENARIO_BASEPATH/cp-apps/connectors/connector_ss.yaml | sed 's/__NAMESPACE__/'"${MY_NAMESPACE}"'/g' | kubectl apply -n  ${MY_NAMESPACE} -f -
   ```
  
1. Validate:
  
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

1. In Control Center, check if the `topic-foo-ss` topic exists.
