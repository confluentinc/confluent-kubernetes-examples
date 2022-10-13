# Deploy CFK with SASL/PLAIN and Load Balancer using Blueprint

## Deployment Scenario
- SASL/PLAIN authentication with encryption
- External Access using Load Balancer
- Custom Kafka Listeners and its credential coming from deployment API

## Prerequisite
- Set the home directory for this tutorial:

  ```bash
  export SCENARIO_BASEPATH=<CFK examples directory>/confluent-kubernetes-examples/blueprints-early-access/scenario/cp- nonrbac-saslplain-lb
  ```
  ```bash
  export MY_NAMESPACE=<your org namespace>
  ``` 

- [Deploy the Control Plane with the Orchestrator](../quickstart-deploy/single-site-deployment.rst#deploy-control-plane).

- [Deploy the Data Plane with the Agent](../quickstart-deploy/single-site-deployment.rst#deploy-local-data-plane).

- The above setup creates the namespace for the Blueprint system resources, `cpc-system`.

## Install Blueprint

### Install Blueprint Certificate Authority (CA)

The Control Plane uses CA keypair to generate certificates for all the Confluent Platform component. Run the following commands:
1. Create a secret `ca-key-pair-sce-4` using the CA keypair generated in when deploying [the Control Plane](../quickstart-deploy/single-site-deployment.rst#deploy-control-plane).

   ```bash 
   kubectl -n cpc-system create secret tls  ca-key-pair-sce-4 --cert=/tmp/cpc-ca.pem --key=/tmp/cpc-ca-key.pem
   ```

1. Create the CertificateStoreConfig to inject CA keypair generated as above:

   ```bash 
   kubectl -n cpc-system apply -f $SCENARIO_BASEPATH/blueprint/certificatestoreconfig.yaml
   ```

### Install Blueprint Credentials

1. Create a secret object `cp-nonrbac-saslplain-lb-bp-credentials` that contains all the required credential for the Blueprint:
   
   ```bash
   kubectl -n cpc-system create secret generic cp-nonrbac-saslplain-lb-bp-credentials \
       --from-file=kafka-pwd-encoder.txt=$SCENARIO_BASEPATH/blueprint/credentials/kafka-pwd-encoder.txt  \
       --from-file=sr-pwd-encoder.txt=$SCENARIO_BASEPATH/blueprint/credentials/sr-pwd-encoder.txt  \
       --from-file=kafka-server-listener-internal-plain-users.json=$SCENARIO_BASEPATH/blueprint/credentials/kafka-server-listener-internal-plain-users.json \
       --from-file=kafka-server-listener-external-plain-users.json=$SCENARIO_BASEPATH/blueprint/credentials/kafka-server-listener-external-plain-users.json \
       --save-config --dry-run=client -oyaml | kubectl apply -f -
   ```

2. Create the credential store used by this Blueprint. The credential store is only used by this Blueprint and can't be share with other resource and Blueprints:

   ```bash
   kubectl apply -f $SCENARIO_BASEPATH/blueprint/credentialstoreconfig.yaml --namespace cpc-system
   ```

### Install Blueprint
  
```bash
kubectl apply -f $SCENARIO_BASEPATH/blueprint/blueprint.yaml --namespace cpc-system
```

## Deploy Confluent Platform 

### Create Namespace

```bash 
kubectl create namespace $MY_NAMESPACE
```

### Install Credentials

1. Create a secret that contains all the required credential on namespace `MY_NAMESPACE`. 
   The key names can't be changed once the secret is created.

   ```bash
   kubectl -n ${MY_NAMESPACE} create secret generic cp-credentials \
       --from-file=connect-client-plain.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/connect-client-plain.txt \
       --from-file=controlcenter-client-plain.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/controlcenter-client-plain.txt \
       --from-file=kafkarestproxy-client-plain.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/kafkarestproxy-client-plain.txt \
       --from-file=ksqldb-client-plain.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/ksqldb-client-plain.txt \
       --from-file=schemaregistry-client-plain.txt=$SCENARIO_BASEPATH/cp-clusters/credentials/schemaregistry-client-plain.txt \
       --save-config --dry-run=client -oyaml | kubectl apply -f -
   ```

1. Install Confluent Platform Deployment credential:

   ```bash 
   kubectl apply -f $SCENARIO_BASEPATH/cp-clusters/credentialstoreconfig.yaml -n ${MY_NAMESPACE}
   ```

### Install Confluent Platform in Single Site Deployment

Install Confluent Platform on the Control Plane cluster:
 
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
   ```

