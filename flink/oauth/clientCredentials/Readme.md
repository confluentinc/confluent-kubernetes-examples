## Setup Certs

This playbook will generate the necessary certificates for the Confluent Manager for Apache Flink [mTLS].

## Internal

::

      assume cc-internal-devprod-prod-1/developer
      export USER=AWS
      export APIKEY=$(aws ecr get-login-password --region us-west-2)
      export EMAIL=abhsharma@confluent.io
      
      kubectl -n operator create secret docker-registry confluent-registry \
      --docker-server=519856050701.dkr.ecr.us-west-2.amazonaws.com       \
      --docker-username=$USER                                            \
      --docker-password=$APIKEY                                          \
      --docker-email=$EMAIL


## Prerequisites

1. Create ns
    ```bash
    kubectl create ns operator
    ```

2. Export current directory
    ```bash
    export TUTORIAL_HOME=$(pwd) # This will be used to refer to the current directory
    export CFK_EXAMPLES_REPO_HOME="https://raw.githubusercontent.com/confluentinc/confluent-kubernetes-examples/master" 
    ```
   
3. Deploy Keycloak
    ```bash
    kubectl apply -f $TUTORIAL_HOME/dependencies/keycloak/keycloak.yaml
    ```

## Keycloak Admin Console

1. Port Forward 
   ```bash
    while true; do kubectl port-forward service/keycloak 8080:8080 -n operator; done;
   ```
2. Access Keycloak Admin Console at `http://localhost:8080/` with the following credentials:
   - Username: `admin`
   - Password: `admin`
3. Go to clients http://localhost:8080/admin/master/console/#/sso_test/clients
4. Go to users http://localhost:8080/admin/master/console/#/sso_test/users
   a. Make sure to have test users, as we would create role bindings corresponding to this user
   b. user1 should exists, set password corresponding to user1 

### Provide authentication credentials

#. Create a Kubernetes secret object for Zookeeper, Kafka, and Control Center.

This secret object contains file based properties. These files are in the
format that each respective Confluent component requires for authentication
credentials.

::

     kubectl create secret generic credential \
       --from-file=plain-users.json=$TUTORIAL_HOME/creds/cp/creds-kafka-sasl-users.json \
       --from-file=digest-users.json=$TUTORIAL_HOME/creds/cp/creds-zookeeper-sasl-digest-users.json \
       --from-file=digest.txt=$TUTORIAL_HOME/creds/cp/creds-kafka-zookeeper-credentials.txt \
       --from-file=plain.txt=$TUTORIAL_HOME/creds/cp/creds-client-kafka-sasl-user.txt \
       --from-file=basic.txt=$TUTORIAL_HOME/creds/cp/creds-control-center-users.txt \
       --namespace operator

#. Create a Kubernetes secret object for MDS:

::

     kubectl create secret generic mds-token \
      --from-file=mdsPublicKey.pem=<(curl -sSL $CFK_EXAMPLES_REPO_HOME/assets/certs/mds-publickey.txt) \
      --from-file=mdsTokenKeyPair.pem=<(curl -sSL $CFK_EXAMPLES_REPO_HOME/assets/certs/mds-tokenkeypair.txt) \
      --namespace operator

#. Create ca-pair-sslcerts secret for operator autogen feature (can be turned off from helm chart not required for this playbook)

::

      openssl genrsa -out $TUTORIAL_HOME/certs/ca/ca-key.pem 2048

      openssl req -new -key $TUTORIAL_HOME/certs/ca/ca-key.pem -x509 \
        -days 1000 \
        -out $TUTORIAL_HOME/certs/ca/ca.pem \
        -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA"

      kubectl -n operator create secret tls ca-pair-sslcerts --cert=$TUTORIAL_HOME/certs/ca/ca.pem --key=$TUTORIAL_HOME/certs/ca/ca-key.pem

#. Create OAuth Creds

::

1. Create jass config secret for oauth and sso
    ```bash
    kubectl create -n operator secret generic oauth-jaas --from-file=oauth.txt=$TUTORIAL_HOME/creds/cp/oauth_jass.txt
    kubectl create -n operator secret generic oauth-jaas-sso --from-file=oidcClientSecret.txt=$TUTORIAL_HOME/creds/cp/oauth_jass.txt
    ```

#. C3 Next Gen Creds

::

1. Create basic credentials for prometheus & alertmanager server
   kubectl -n operator create secret generic prometheus-credentials --from-file=basic.txt=./creds/c3/prometheus-credentials-secret.txt
   kubectl -n operator create secret generic alertmanager-credentials --from-file=basic.txt=./creds/c3/alertmanager-credentials-secret.txt

2. Create basic credentials for prometheus & alertmanager client
   kubectl -n operator create secret generic prometheus-client-creds --from-file=basic.txt=./creds/c3/prometheus-client-credentials-secret.txt
   kubectl -n operator create secret generic alertmanager-client-creds --from-file=basic.txt=./creds/c3/alertmanager-client-credentials-secret.txt


### Provide Certificates

#. CP Certs

1. Currently we are using autogen certs for cp, if we want to use custom certs, go here https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/assets/certs

#. C3 Next Gen Certs

1. Generate certs for control center next gen
   ```bash
   cfssl gencert -ca=$TUTORIAL_HOME/certs/ca/ca.pem \
   -ca-key=$TUTORIAL_HOME/certs/ca/ca-key.pem \
   -config=$TUTORIAL_HOME/certs/server_configs/ca-config.json \
   -profile=server $TUTORIAL_HOME/certs/server_configs/c3-ng-server-config.json | cfssljson -bare $TUTORIAL_HOME/certs/generated/controlcenter-server
   ```

1. Create `prometheus-tls` & `alertmanager-tls` configMap
```bash
kubectl create secret generic prometheus-tls -n operator --from-file=fullchain.pem=./certs/generated/controlcenter-server.pem --from-file=privkey.pem=./certs/generated/controlcenter-server-key.pem --from-file=cacerts.pem=./certs/ca/ca.pem
kubectl create secret generic alertmanager-tls -n operator --from-file=fullchain.pem=./certs/generated/controlcenter-server.pem --from-file=privkey.pem=./certs/generated/controlcenter-server-key.pem --from-file=cacerts.pem=./certs/ca/ca.pem
```

2. Create client side certs against prometheus & alertmanager
```bash
kubectl create secret generic prometheus-client-tls -n operator --from-file=fullchain.pem=./certs/generated/controlcenter-server.pem --from-file=privkey.pem=./certs/generated/controlcenter-server-key.pem --from-file=cacerts.pem=./certs/ca/ca.pem
kubectl create secret generic alertmanager-client-tls -n operator --from-file=fullchain.pem=./certs/generated/controlcenter-server.pem --from-file=privkey.pem=./certs/generated/controlcenter-server-key.pem --from-file=cacerts.pem=./certs/ca/ca.pem
```

#. Confluent Manager for Apache Flink

1. Generate certs for confluent manager for apache flink
   ```bash
   cfssl gencert -ca=$TUTORIAL_HOME/certs/ca/ca.pem \
   -ca-key=$TUTORIAL_HOME/certs/ca/ca-key.pem \
   -config=$TUTORIAL_HOME/certs/server_configs/ca-config.json \
   -profile=server $TUTORIAL_HOME/certs/server_configs/cmf-server-config.json | cfssljson -bare $TUTORIAL_HOME/certs/generated/cmf-server
   ```

2. Make jks for confluent manager for apache flink
   ```bash
   curl -sSL $CFK_EXAMPLES_REPO_HOME/scripts/create-truststore.sh | bash -s -- $TUTORIAL_HOME/certs/ca/ca.pem allpassword
   curl -sSL $CFK_EXAMPLES_REPO_HOME/scripts/create-keystore.sh | bash -s --  $TUTORIAL_HOME/certs/generated/cmf-server.pem $TUTORIAL_HOME/certs/generated/cmf-server-key.pem allpassword
   rm -rf $TUTORIAL_HOME/certs/jks
   mv jks $TUTORIAL_HOME/certs
   ```

## Deploy CP With RBAC Enabled (OAuth)

### Deployment

1. apply cp_components.yaml
    ```bash
    kubectl apply -f $TUTORIAL_HOME/manifests/cp_components.yaml
    ```
2. Perform CURL
    ```bash
   ACCESS_TOKEN=$(curl --silent --location 'http://keycloak:8080/realms/sso_test/protocol/openid-connect/token' \
   --header 'Content-Type: application/x-www-form-urlencoded' \
   --header 'Authorization: Basic c3NvbG9naW46VzhWNGNxZXdDeTU0eDRnbTdVamhMa2swcnJGRGk2RFQ=' \
   --data-urlencode 'grant_type=client_credentials' | jq -r '.access_token')
   
   curl --cacert certs/ca/ca.pem \
   --header 'Accept: application/json' \
   --header "Authorization: Bearer $ACCESS_TOKEN" \
   https://kafka.operator.svc.cluster.local:8090/security/1.0/roles
   ```  

### Testing
1. Test Curl requests against CP (SR for example) cluster at 8081, after port forwarding
    ```bash
    curl --location 'https://localhost:8081/subjects' \
    --header 'Accept: application/json' \
    --header 'Authorization: Bearer <IDP_TOKEN_HERE>'    
    ```
   Note: Token passes here are issued by IDP like keycloak, and are valid for 5 minutes.

### Validate C3 UI
1. Port Forward Control Center
    ```bash
    while true; do kubectl port-forward service/controlcenter-ng 9021:9021 -n operator; done;
    ```
2. Access Control Center UI at `https://localhost:9021/` with the following credentials:

## Deploy CMF

1. Create certs under configMap
    ```bash
    kubectl create secret generic cmf-truststore -n operator --from-file=truststore.jks=$TUTORIAL_HOME/certs/jks/truststore.jks
    kubectl create secret generic cmf-keystore -n operator --from-file=keystore.jks=$TUTORIAL_HOME/certs/jks/keystore.jks
    ``` 
2. Deploy via HELM
    ```bash
   helm upgrade --install -f $TUTORIAL_HOME/dependencies/cmf/values.yaml cmf confluentinc/confluent-manager-for-apache-flink --namespace operator --version 2.0
   # To use for internal development
   # helm upgrade --install -f $TUTORIAL_HOME/dependencies/cmf/values.yaml cmf oci://519856050701.dkr.ecr.us-west-2.amazonaws.com/helm/dev/confluentinc/confluent-manager-for-apache-flink --namespace operator --version 2.0-SNAPSHOT 
   ```
4. Add apt local names in /etc/hosts and port forward
    ```
    127.0.0.1       confluent-manager-for-apache-flink.operator.svc.cluster.local
    ```
   
   ```
   while true; do kubectl port-forward service/cmf-service 8091:80 -n operator; done;
   ```
6. Perform CURL
    ```bash
   ACCESS_TOKEN=$(curl --silent --location 'http://keycloak:8080/realms/sso_test/protocol/openid-connect/token' \
   --header 'Content-Type: application/x-www-form-urlencoded' \
   --header 'Authorization: Basic c3NvbG9naW46VzhWNGNxZXdDeTU0eDRnbTdVamhMa2swcnJGRGk2RFQ=' \
   --data-urlencode 'grant_type=client_credentials' | jq -r '.access_token')
   
   curl --cacert certs/ca/ca.pem \
   --header 'Accept: application/json' \
   --header "Authorization: Bearer $ACCESS_TOKEN" \
   https://confluent-manager-for-apache-flink.operator.svc.cluster.local:8091/cmf/api/v1/environments
   ```  
   
### Deploy CMF Rest Class
1. Create `cmf-day2-tls` configMap
   ```bash
    kubectl create secret generic cmf-day2-tls -n operator \
   --from-file=fullchain.pem=$TUTORIAL_HOME/certs/generated/cmf-server.pem \
   --from-file=privkey.pem=$TUTORIAL_HOME/certs/generated/cmf-server-key.pem \
    --from-file=cacerts.pem=$TUTORIAL_HOME/certs/ca/ca.pem
   ```
2. Deploy CMFRestClass
    ```bash
        kubectl apply -f $TUTORIAL_HOME/manifests/cmfrestclass.yaml
    ```
2. Verify status has been populated
    ```bash
       kubectl get crc default  -n operator -oyaml
    ```
