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
      --from-file=controlcenter-client-bearer.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/controlcenter-client-  bearer.txt \
      --from-file=kafkarestproxy-client-bearer.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/kafkarestproxy-client-  bearer.txt \
      --from-file=ksqldb-client-bearer.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/ksqldb-client-bearer.txt \
      --from-file=schemaregistry-client-bearer.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/schemaregistry-client-  bearer.txt \
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

### Install Confluent Platform in Multi Site Deployment
- Make sure to add the `k8sClusterRef` and point to your k8s resource  in `$SCENARIO_BASEPATH/cp-clusters `deployment_ms.yaml` file before running

  ```bash
  kubectl apply -f $SCENARIO_BASEPATH/cp-clusters/deployment_ms.yaml -n ${MY_NAMESPACE}
  ```

### Confluent Platform Deployment Validation


## Install Confluent Platform APPs

## Pre-requisite

- Make sure single & multi-site Confluent Platform deployment is running
    - You can validate by checking status

## Single Site Deployment

- First install all the single site yaml and make sure to check the validation section
    - Topic
        - `kubectl -n ${MY_NAMESPACE} apply -f $SCENARIO_BASEPATH/cp-apps/topics/topic.yaml`
        - Check Resource
            - `kubectl -n ${MY_NAMESPACE} get kafkatopics.apps topic-foo`
        - Validation:
            - Make sure the `state` is in `Created` mode
    - Rolebinding
        - Make sure to find id for schemaregistry/connect cluster before applying
            - To get `schemaRegistryClusterId`
                - `kubectl -n ${MY_NAMESPACE} get schemaregistrycluster -oyaml | grep schemaRegistryClusterId`
            - To get `connectClusterId`
                - `kubectl -n ${MY_NAMESPACE} get connectcluster -oyaml | grep connectClusterId`
            - To get `ksqldbClusterId`
                - `kubectl -n ${MY_NAMESPACE} get ksqldbcluster -oyaml | grep ksqlClusterId`
        - `cat $SCENARIO_BASEPATH/cp-apps/rolebinding/rolebiding_ss.yaml | sed 's/__NAMESPACE__/'"$MY_NAMESPACE"'/g' | kubectl apply -f -`
        - Check Resource
            - `kubectl -n ${MY_NAMESPACE} get confluentrolebindings.apps`
        - Validation:
            - Make sure the `state` is in `Created` mode
    - SchemaExporter
        - `kubectl -n ${MY_NAMESPACE} apply -f $SCENARIO_BASEPATH/cp-apps/schemaexporter/schemaexporter_ss.yaml`
        - Check Resource
            - `kubectl -n ${MY_NAMESPACE} get schemaexporters.apps schema-exporter-ss`
        - Validation:
            - Make sure the `state` is in `Created` mode
    - Schema
        - `kubectl -n ${MY_NAMESPACE} apply -f $SCENARIO_BASEPATH/cp-apps/schema/schema_ss.yaml`
        - Check Resource
            - `kubectl -n ${MY_NAMESPACE} get schemas.app schema-foo-ss`
        - Validation:
            - Make sure the `state` is in `Running` mode
    - Connectors
        - `kubectl -n ${MY_NAMESPACE} apply -f $SCENARIO_BASEPATH/cp-apps/schema/connector_ss.yaml`
        - Check Resource
            - `kubectl -n ${MY_NAMESPACE} get connectors.apps`
        - Validation:
            - Make sure the `state` is in `Created` mode

### Confluent Platform APP Validation
- Update Workflow
- Delete Workflow

## Multi Site Deployment

- First install all the single site yaml and make sure to check the validation section
    - Topic
        - `kubectl apply -f $SCENARIO_BASEPATH/cp-apps/topics/global.yaml --namespace `
        - Check Resource
            - `kubectl -n ${MY_NAMESPACE} get kafkatopics.apps topic-global`
        - Validation:
            - Make sure the `state` is in `Created` mode
    - Rolebinding
      - Make sure to find id for schemaregistry/connect cluster before applying
        - To get `schemaRegistryClusterId`
          - `kubectl -n ${MY_NAMESPACE} get schemaregistrycluster -oyaml | grep schemaRegistryClusterId`
        - To get `connectClusterId`
          - `kubectl -n ${MY_NAMESPACE} get connectcluster -oyaml | grep connectClusterId`
        - To get `ksqldbClusterId`
          - `kubectl -n ${MY_NAMESPACE} get ksqldbcluster -oyaml | grep ksqlClusterId`
      - `cat $SCENARIO_BASEPATH/cp-apps/rolebinding/rolebiding_ms.yaml | sed 's/__NAMESPACE__/'"$MY_NAMESPACE"'/g' | kubectl apply -f -`
      - Check Resource
        - `kubectl -n ${MY_NAMESPACE} get confluentrolebindings.apps`
      - Validation:
        - Make sure the `state` is in `Created` mode
    - SchemaExporter
        - `kubectl -n ${MY_NAMESPACE} apply -f $SCENARIO_BASEPATH/cp-apps/schemaexporter/schemaexporter_ms.yaml`
        - Check Resource
            - `kubectl -n ${MY_NAMESPACE} get schemaexporters.apps | grep schema-exporter-ms`
        - Validation:
            - Make sure the `state` is in `Created` mode
    - Schema
        - `kubectl  -n ${MY_NAMESPACE} apply -f $SCENARIO_BASEPATH/cp-apps/schema/schema_ms.yaml`
        - Check Resource
            - `kubectl -n ${MY_NAMESPACE} get schemas.apps schema-config-ms`
        - Validation:
            - Make sure the `state` is in `Running` mode
    - Connectors
        - `kubectl -n ${MY_NAMESPACE} apply -f $SCENARIO_BASEPATH/cp-apps/connectors/connector_ms.yaml`
        - Check Resource
            - `kubectl -n ${MY_NAMESPACE} get connectors.apps datagen-connector-ms`
        - Validation:
            - Make sure the `state` is in `Created` mode

