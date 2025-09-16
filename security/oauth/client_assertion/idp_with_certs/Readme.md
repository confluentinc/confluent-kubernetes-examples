## Introduction

follow Sso example to deploy keycloak

### Create truststore with CA cert
```bash
kubectl create secret generic mycustomtruststore --from-file=truststore.jks=./jks/truststore.jks -n operator

kubectl create secret generic cacert --from-file=cacerts.pem=./certs/ca/ca.pem -n operator 

kubectl -n operator create secret tls ca-pair-sslcerts \
    --cert=ca.pem \
    --key=ca-key.pem
    
kubectl create configmap "keycloak-certs" \
  --namespace "$NAMESPACE" \
  --from-file=tls.pem="certs/ca/generated/server.pem" \
  --from-file=tls-key.pem="certs/ca/generated/server-key.pem" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Deployment

1. Deploy keycloak with HTTPS
   ```bash
    sh deploy_keycloak.sh
    ```
2. Create jass config secret
    ```bash
    kubectl create -n operator secret generic oauth-jass --from-file=oauth.txt=oauth_jass.txt
    ```
2. apply cp_components.yaml
    ```bash
    kubectl apply -f cp_components.yaml
    ```
   
## Testing

1. Copy updated kafka.properties in /tmp
    ```bash
    kubectl cp -n operator kafka.properties  kafka-0:/tmp/kafka.properties
    ```
2. Do Shell
   ```bash
   kubectl -n operator exec kafka-0 -it /bin/bash
   ```
3. Run topic command
   ```bash
   kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9071 --topic test-topic-internal --create --replication-factor 3 --command-config /tmp/kafka.properties
   kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9092 --topic test-topic-external --create --replication-factor 3 --command-config /tmp/kafka.properties
   kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9072 --topic test-topic-replication --create --replication-factor 3 --command-config /tmp/kafka.properties
   kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9094 --topic test-topic-custom --create --replication-factor 3 --command-config /tmp/kafka.properties
   ```
