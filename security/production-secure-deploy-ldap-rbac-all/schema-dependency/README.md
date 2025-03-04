#### Create Namespace

kubectl create namespace operator

#### Deploy ldap
export TUTORIAL_HOME=<Tutorial directory>/security/production-secure-deploy-ldap-rbac-all/schema-dependency
helm upgrade --install -f $TUTORIAL_HOME/../../../assets/openldap/ldaps-rbac.yaml test-ldap $TUTORIAL_HOME/../../../assets/openldap --namespace operator


#### Deploy Operator (Namespaced Scope)

helm repo add confluentinc https://packages.confluent.io/helm

helm repo update

helm upgrade --install confluent-operator \
confluentinc/confluent-for-kubernetes \
--set kRaftEnabled=true \
--namespace operator


#### Create Secret Objects
##### Create ca key pair secret
To use auto-generated certificates for Destination components. You'll need to generate and provide a Root Certificate Authority (CA).

Generate a CA pair to use in this tutorial:

```
openssl genrsa -out $TUTORIAL_HOME/ca-key.pem 2048
openssl req -new -key $TUTORIAL_HOME/ca-key.pem -x509 \
  -days 1000 \
  -out $TUTORIAL_HOME/ca.pem \
  -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA"
```

Then, provide the certificate authority as a Kubernetes secret `ca-pair-sslcerts` to be used to 
generate the auto-generated certs, in both the source and destination namespaces:

```
kubectl -n operator create secret tls ca-pair-sslcerts \
  --cert=$TUTORIAL_HOME/ca.pem \
  --key=$TUTORIAL_HOME/ca-key.pem 
```

##### Secret Object Credentials
     kubectl create secret generic credential \
       --from-file=plain-users.json=$TUTORIAL_HOME/../creds/creds-kafka-sasl-users.json \
       --from-file=plain.txt=$TUTORIAL_HOME/../creds/creds-client-kafka-sasl-user.txt \
       --from-file=ldap.txt=$TUTORIAL_HOME/../creds/ldap.txt \
       --namespace operator

##### Secret Object for MDS TokenKeyPair

     kubectl create secret generic mds-token \
       --from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../../assets/certs/mds-publickey.txt \
       --from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../../assets/certs/mds-tokenkeypair.txt \
       --namespace operator



##### Other secrets for cp components

     # Kafka RBAC credential
     kubectl create secret generic mds-client-erp \
       --from-file=bearer.txt=$TUTORIAL_HOME/../creds/bearer.txt \
       --namespace operator
     # Control Center RBAC credential
     kubectl create secret generic mds-client-c3 \
       --from-file=bearer.txt=$TUTORIAL_HOME/../creds/c3-mds-client.txt \
       --namespace operator
     # Connect RBAC credential
     kubectl create secret generic mds-client-connect \
       --from-file=bearer.txt=$TUTORIAL_HOME/../creds/connect-mds-client.txt \
       --namespace operator
     # Schema Registry RBAC credential
     kubectl create secret generic mds-client-sr \
       --from-file=bearer.txt=$TUTORIAL_HOME/../creds/sr-mds-client.txt \
       --namespace operator
     # ksqlDB RBAC credential
     kubectl create secret generic mds-client-ksql \
       --from-file=bearer.txt=$TUTORIAL_HOME/../creds/ksqldb-mds-client.txt \
       --namespace operator
     # Kafka Rest Proxy RBAC credential
     kubectl create secret generic mds-client-krp \
       --from-file=bearer.txt=$TUTORIAL_HOME/../creds/krp-mds-client.txt \
       --namespace operator
     # Kafka REST credential
     kubectl create secret generic rest-credential \
       --from-file=bearer.txt=$TUTORIAL_HOME/../creds/bearer.txt \
       --from-file=basic.txt=$TUTORIAL_HOME/../creds/bearer.txt \
       --namespace operator



#### Deploy CP components

kubectl apply -f cp-components.yaml
kubectl apply -f cp-components-secondary.yaml


## Tear down
kubectl delete -f cp-components.yaml
kubectl delete -f cp-components-secondary.yaml

helm delete confluent-operator -n operator
helm delete test-ldap -n operator



