# Deploy CFK with RBAC, mTLS, and Load Balancer using Blueprint

## Deployment Scenario
- mTLS authentication
- Confluent Platform RBAC 
- External Access using Load Balancer
- Custom Kafka listeners and its credential coming from deployment API

## Prerequisite
- Set the home directory for this tutorial:

  ```bash
  export SCENARIO_BASEPATH=<CFK examples directory>/confluent-kubernetes-examples/blueprints-early-access/scenario/cp-rbac-mtls-lb
  ```

  ```bash
  export MY_NAMESPACE=<your org namespace>
  ``` 

- [Deploy the Control Plane with the Orchestrator](../quickstart-deploy/local-deployment.rst#deploy-control-plane).

- [Deploy the Data Plane with the Agent](../quickstart-deploy/local-deployment.rst#deploy-local-data-plane).

- The namespace for the Blueprint system resources, `cpc-system`.

### Deploy OpenLDAP
This repo includes a Helm chart for OpenLdap. The chart `values.yaml` includes the set of principal definitions that Confluent Platform needs for Confluent Platform RBAC.

1. Deploy OpenLdap:

   ```bash
   helm upgrade --install -f $SCENARIO_BASEPATH/../../../assets/openldap/ldaps-rbac.yaml test-ldap    $SCENARIO_BASEPATH/../../../assets/openldap --namespace cpc-system
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

1. Create a secret `ca-key-pair-sce-2`

   ```bash
   kubectl -n cpc-system create secret tls  ca-key-pair-   sce-2 --cert=/tmp/cpc-ca.pem --key=/tmp/cpc-ca-key.pem
   ```

2. Create the CertificateStoreConfig to inject CA keypair generated as above:

   ```bash
   kubectl apply -f $SCENARIO_BASEPATH/blueprint/   certificatestoreconfig.yaml --namespace cpc-system
   ```

### Install Blueprint Credentials

- Create a secret object `cp-rbac-mtls-lb-bp-credentials` that contains all the required credential for the Blueprint:

  ```bash
  kubectl -n cpc-system create secret generic cp-rbac-mtls-lb-bp-credentials \
      --from-file=mds-token-key.txt=$SCENARIO_BASEPATH/blueprint/credentials/mds-token-key.txt \
      --from-file=mds-public-key.txt=$SCENARIO_BASEPATH/blueprint/credentials/mds-public-key.txt \
      --from-file=idp-simple.txt=$SCENARIO_BASEPATH/blueprint/credentials/idp-simple.txt  \
      --from-file=kafka-pwd-encoder.txt=$SCENARIO_BASEPATH/blueprint/credentials/kafka-pwd-encoder.txt  \
      --from-file=sr-pwd-encoder.txt=$SCENARIO_BASEPATH/blueprint/credentials/sr-pwd-encoder.txt  \
      --save-config --dry-run=client -oyaml | kubectl apply -f -
  ```

- Only used by the Blueprint and can't be shared with other resource and Blueprints:

  ```bash
  kubectl apply -f $SCENARIO_BASEPATH/blueprint/credentialstoreconfig.yaml --namespace cpc-system
  ```

- Install Blueprint:

  ```bash
  kubectl apply -f $SCENARIO_BASEPATH/blueprint/blueprint.yaml --namespace cpc-system
  ```


## Deploy Confluent Platform 

### Install Credentials

- Create a secret that contains all the required credential on namespace `MY_NAMESPACE`
  - We need to make sure to document key name as these keys can't be changed.

  ```bash
  kubectl -n ${MY_NAMESPACE} create secret generic cp-credentials \
      --from-file=mds-client-bearer.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/mds-client-bearer.txt \
      --from-file=connect-client-bearer.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/connect-client-bearer.txt \
      --from-file=controlcenter-client-bearer.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/controlcenter-client-bearer.txt \
      --from-file=kafkarestproxy-client-bearer.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/kafkarestproxy-client-bearer.txt \
      --from-file=ksqldb-client-bearer.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/ksqldb-client-bearer.txt \
      --from-file=schemaregistry-client-bearer.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/schemaregistry-client-bearer.txt \
      --save-config --dry-run=client -oyaml | kubectl apply -f -
  ```

- Install Confluent Platform Deployment Credential

  ```bash
  kubectl apply -f $SCENARIO_BASEPATH/cp-clusters/credentialstoreconfig.yaml -n ${MY_NAMESPACE}
  ```

### Install Confluent Platform in Single Site Deployment
- This installs Confluent Platform on the Control Plane K8s Cluster

  ```bash
  kubectl apply -f $SCENARIO_BASEPATH/cp-clusters/deployment_ss.yaml -n ${MY_NAMESPACE}
  ```
### Validate the Deployment

1. Check when the Confluent components are up and running:
   
   ```bash 
   kubectl get pods --namespace $MY_NAMESPACE -w
   ```

2. Navigate to Control Center in a browser and check the Confluent cluster:

   ```bash       
   kubectl confluent dashboard controlcenter --namespace $MY_NAMESPACE
