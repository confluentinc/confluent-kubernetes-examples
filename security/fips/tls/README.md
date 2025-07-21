
# Deploy CKF and CP in FIPS mode - example with TLS

In this workflow, we will deploy Confluent Platform cluster using CFK operator with the following options

- Deploy CFK in FIPS mode
- Deploy CP (KRaftController, Kafka, SchemaRegistry, Connect, KsqlDB) with FIPS-compliant TLS certificates
- Full TLS network encryption with user provided self-sign certificates

## Prerequisite

- Requires Kubernetes Access
&nbsp;

- `kubectl helm git openssl keytool cfssl jq` commands exist
  ```sh
  command -v kubectl helm git openssl keytool cfssl jq
  ```

- Git clone the repository
  ```sh
  git clone https://github.com/confluentinc/confluent-kubernetes-examples.git

  cd confluent-kubernetes-examples/security/fips/tls
  ```

- Set environment variables
  ```sh
  {
    export CP_HOME=$(pwd)
    export CP_NS='confluent'
    export CERTS_HOME="${CP_HOME}/../certs/generated"
    echo "CP_HOME=${CP_HOME} \nCP_NS=${CP_NS} \nCERTS_HOME=${CERTS_HOME}"
  }
  ```

- Create Confluent namespace
  ```sh
  {
    kubectl get ns ${CP_NS} 2>/dev/null || kubectl create ns ${CP_NS}
    kubectl config set-context --current --namespace=${CP_NS}
  }
  ```

- Generate FIPS-compliant TLS certificates
  ```sh
  ${CP_HOME}/../certs/generate-certs.sh
  ```
  **Note:** This script will generate the required certificates in the `generated` directory, please feel free to modify the variables in script to customize the certificates to your needs.
&nbsp;
- Create Kubernetes secrets for TLS certificates

  ```sh
  {
    kubectl create secret generic fips-tls \
        --from-file=keystore.bcfks=${CERTS_HOME}/confluent-ps-fips-keystore.bcfks \
        --from-file=truststore.bcfks=${CERTS_HOME}/confluent-ps-fips-truststore.bcfks \
        --from-file=keystore.jks=${CERTS_HOME}/confluent-ps-fips-keystore.jks \
        --from-file=truststore.jks=${CERTS_HOME}/confluent-ps-fips-truststore.jks \
        --from-literal=jksPassword.txt=jksPassword=mystorepassword
    kubectl get secret fips-tls -o jsonpath='{.data}' | jq .
    
    kubectl create secret generic tls-certs \
      --from-file=fullchain.pem=${CERTS_HOME}/confluent-ps-fips-fullchain.pem \
      --from-file=cacerts.pem=${CERTS_HOME}/cacerts.pem \
      --from-file=privkey.pem=${CERTS_HOME}/confluent-ps-fips-server-key.pem
    kubectl get secret tls-certs -o jsonpath='{.data}' | jq .
  }
  ```

## Deploy Confluent for Kubernetes

```sh
{
  helm repo add confluentinc https://packages.confluent.io/helm
  helm repo update confluentinc
  # 3.0.0 - 0.1263.8
  helm upgrade --install confluent-operator \
    confluentinc/confluent-for-kubernetes \
    --set kRaftEnabled=true \
    --set fipsmode=true \
    --version 0.1263.8
  helm ls
  kubectl wait pod -l app.kubernetes.io/name=confluent-operator --for=condition=ready --timeout=180s
}
```

## Deploy Confluent Platform

```sh
{
  kubectl apply -f confluent-platform.yaml
  echo "\n *** Waiting for all pods to be ready ***"
  kubectl wait pod --all --for=condition=ready --timeout=360s
  kubectl get pods
}
```

**FIPS Check**

```
kubectl exec kafka-0 -c kafka -- bash -c "cat /opt/confluentinc/etc/kafka/kafka.properties | grep -Ei 'fips|security.providers'; echo; ps -ef | grep java | grep 'jdk.tls.namedGroups';"
```

Verify

- In `/opt/confluentinc/etc/kafka/kafka.properties` file, following setting are in place
  - ` security.providers` is set to `io.confluent.kafka.security.fips.provider.BcFipsProviderCreator,io.confluent.kafka.security.fips.provider.BcFipsJsseProviderCreator`
  
- In JVM process `-Djdk.tls.namedGroups="secp256r1,secp384r1,ffdhe2048,ffdhe3072"` is set

Check in other CP components as well

### Access Control Center

Set up port forwarding to Control Center web UI

```sh
kubectl port-forward controlcenter-0 9021:9021 
```
Browse to Control Center https://localhost:9021

```
As we are using self-signed certificates, we will receive a warning in the Chrome browser **Your connection is not private**. 
Click on the "Advanced" button and click on "Proceed to localhost (unsafe)".
```

## Cleanup

```sh
{
  kubectl delete -f confluent-platform.yaml
  kubectl delete secret fips-tls tls-certs
  helm uninstall confluent-operator
  kubectl delete ns ${CP_NS}
}

And remove the **generated** directory under `../certs` to clean up the certificates.
```

That's it!

---

