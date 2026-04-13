# Bidirectional Cluster Linking - ZooKeeper with SASL-SSL

This example demonstrates **Bidirectional Cluster Linking** with ZooKeeper mode using **SASL/PLAIN authentication and TLS encryption**. This is the production-ready configuration for Confluent Platform 7.x.

- [Set the current tutorial directory](#set-the-current-tutorial-directory)
- [Prerequisites](#prerequisites)
- [Deploy Confluent for Kubernetes](#deploy-confluent-for-kubernetes)
- [Generate TLS certificates](#generate-tls-certificates)
- [Create secrets](#create-secrets)
- [Deploy the source and destination clusters](#deploy-the-source-and-destination-clusters)
- [Create ClusterLinks](#create-clusterlinks)
- [Validate](#validate)
- [Tear down](#tear-down)

> **Availability**: CFK 3.2.0+ and Confluent Platform 7.4+

## Overview

This example sets up:
- Two Kafka clusters with ZooKeeper using SASL/PLAIN + TLS
- Secure inter-cluster communication
- Bidirectional cluster link with authentication

## Key Requirements for ZooKeeper Mode

### inter.broker.protocol.version=3.1

**Required** for bidirectional cluster linking with ZooKeeper:

```yaml
spec:
  configOverrides:
    server:
      - inter.broker.protocol.version=3.1
```

### TLS Trust Between Clusters

ClusterLink must trust the remote cluster's TLS certificates.

### SASL Credentials for ClusterLink

The ClusterLink needs SASL credentials to authenticate to both local and remote clusters.

## Set the current tutorial directory

```bash
export TUTORIAL_HOME=<Github repo directory>/hybrid/clusterlink-bidirectional/zookeeper/sasl-ssl
```

## Prerequisites

Before continuing with this scenario, ensure that you have:

- A Kubernetes cluster with kubectl configured
- Helm 3.x installed
- OpenSSL (for certificate generation)
- [CFK prerequisites](/README.md#prerequisites)

## Deploy Confluent for Kubernetes

**Important**: Bidirectional cluster linking across namespaces requires a single CFK watching all namespaces (`namespaced=false`).

1. Set up the Helm Chart:

```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
```

2. Install CFK to watch all namespaces:

```bash
kubectl create namespace confluent
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --namespace confluent \
  --set namespaced=false
```

3. Check that the CFK pod comes up and is running:

```bash
kubectl get pods -n confluent
```

## Generate TLS certificates

1. Create the certs directory:

```bash
mkdir -p $TUTORIAL_HOME/certs
```

2. Generate the CA key and certificate:

```bash
openssl genrsa -out $TUTORIAL_HOME/certs/ca-key.pem 4096

openssl req -x509 -new -nodes -key $TUTORIAL_HOME/certs/ca-key.pem -sha256 -days 365 \
  -out $TUTORIAL_HOME/certs/ca.pem \
  -subj "/CN=confluent-ca/O=Confluent/C=US"
```

3. Generate the server private key:

```bash
openssl genrsa -out $TUTORIAL_HOME/certs/privkey.pem 2048
```

4. Create the SAN extensions file. Note the ZooKeeper-specific SANs:

```bash
cat > $TUTORIAL_HOME/certs/ext.cnf << 'EOF'
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = *.svc.cluster.local
DNS.2 = kafka.src.svc.cluster.local
DNS.3 = kafka.dest.svc.cluster.local
DNS.4 = zookeeper.src.svc.cluster.local
DNS.5 = zookeeper.dest.svc.cluster.local
DNS.6 = *.kafka.src.svc.cluster.local
DNS.7 = *.kafka.dest.svc.cluster.local
DNS.8 = *.zookeeper.src.svc.cluster.local
DNS.9 = *.zookeeper.dest.svc.cluster.local
EOF
```

5. Create the CSR and sign the server certificate:

```bash
openssl req -new -key $TUTORIAL_HOME/certs/privkey.pem \
  -out $TUTORIAL_HOME/certs/server.csr \
  -subj "/CN=*.svc.cluster.local"

openssl x509 -req -in $TUTORIAL_HOME/certs/server.csr \
  -CA $TUTORIAL_HOME/certs/ca.pem -CAkey $TUTORIAL_HOME/certs/ca-key.pem \
  -CAcreateserial -out $TUTORIAL_HOME/certs/server.pem \
  -days 365 -sha256 -extfile $TUTORIAL_HOME/certs/ext.cnf -extensions v3_req
```

6. Create the fullchain and cacerts files:

```bash
cat $TUTORIAL_HOME/certs/server.pem $TUTORIAL_HOME/certs/ca.pem > $TUTORIAL_HOME/certs/fullchain.pem
cp $TUTORIAL_HOME/certs/ca.pem $TUTORIAL_HOME/certs/cacerts.pem
```

## Create secrets

### Create namespaces

```bash
kubectl create namespace src
kubectl create namespace dest
```

### Create TLS secrets

Create the TLS secret and CA keypair in both namespaces (shared CA):

```bash
for ns in src dest; do
  kubectl create secret generic tls-certs -n $ns \
    --from-file=fullchain.pem=$TUTORIAL_HOME/certs/fullchain.pem \
    --from-file=cacerts.pem=$TUTORIAL_HOME/certs/cacerts.pem \
    --from-file=privkey.pem=$TUTORIAL_HOME/certs/privkey.pem \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret tls ca-pair-sslcerts -n $ns \
    --cert=$TUTORIAL_HOME/certs/ca.pem --key=$TUTORIAL_HOME/certs/ca-key.pem \
    --dry-run=client -o yaml | kubectl apply -f -
done
```

### Create SASL credential secrets

**Important**: Use different credentials for source and destination clusters.

Source cluster credentials:

```bash
kubectl create secret generic credential -n src \
  --from-literal=plain.txt="$(printf 'username=src-kafka\npassword=src-kafka-secret')" \
  --from-literal=plain-users.json='{"src-kafka":"src-kafka-secret","src-admin":"src-admin-secret"}' \
  --from-literal=plain-interbroker.txt="$(printf 'username=src-kafka\npassword=src-kafka-secret')" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic rest-credential -n src \
  --from-literal=basic.txt="$(printf 'username=src-admin\npassword=src-admin-secret')" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic password-encoder-secret -n src \
  --from-literal=password-encoder.txt="password=src-encoder-secret" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Destination cluster credentials:

```bash
kubectl create secret generic credential -n dest \
  --from-literal=plain.txt="$(printf 'username=dest-kafka\npassword=dest-kafka-secret')" \
  --from-literal=plain-users.json='{"dest-kafka":"dest-kafka-secret","dest-admin":"dest-admin-secret"}' \
  --from-literal=plain-interbroker.txt="$(printf 'username=dest-kafka\npassword=dest-kafka-secret')" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic rest-credential -n dest \
  --from-literal=basic.txt="$(printf 'username=dest-admin\npassword=dest-admin-secret')" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic password-encoder-secret -n dest \
  --from-literal=password-encoder.txt="password=dest-encoder-secret" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Create cross-namespace credential secrets for ClusterLink

```bash
# Source credentials in dest namespace (for dest-cluster-link to auth to src)
kubectl create secret generic src-credential -n dest \
  --from-literal=plain.txt="$(printf 'username=src-kafka\npassword=src-kafka-secret')" \
  --dry-run=client -o yaml | kubectl apply -f -

# Dest credentials in src namespace (for src-cluster-link to auth to dest)
kubectl create secret generic dest-credential -n src \
  --from-literal=plain.txt="$(printf 'username=dest-kafka\npassword=dest-kafka-secret')" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Deploy the source and destination clusters

1. Deploy all source cluster resources (ZooKeeper, Kafka, KafkaRestClass, topics):

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/
```

2. Deploy all destination cluster resources:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/
```

3. Wait for ZooKeeper clusters to be ready:

```bash
kubectl wait --for=condition=Ready pod -l app=zookeeper -n src --timeout=300s
kubectl wait --for=condition=Ready pod -l app=zookeeper -n dest --timeout=300s
```

4. Wait for Kafka clusters to be ready:

```bash
kubectl wait --for=condition=Ready pod -l app=kafka -n src --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kafka -n dest --timeout=300s
```

## Create ClusterLinks

1. Wait for the REST API to become available:

```bash
sleep 15
```

2. Create both ClusterLinks:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/clusterlinks/
```

3. Monitor ClusterLink status until both show `CREATED`:

```bash
kubectl get clusterlink -n src
kubectl get clusterlink -n dest
```

## Validate

1. Verify both ClusterLinks are in `CREATED` state:

```bash
kubectl get clusterlink src-cluster-link -n src -o jsonpath='{.status.state}'
kubectl get clusterlink dest-cluster-link -n dest -o jsonpath='{.status.state}'
```

2. Create SASL-SSL client configuration on each cluster. On the source cluster:

```bash
kubectl exec -n src kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="src-kafka" password="src-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF'
```

On the destination cluster:

```bash
kubectl exec -n dest kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="dest-kafka" password="dest-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
EOF'
```

3. Test forward mirroring (source to destination). Produce a SASL-authenticated message:

```bash
kubectl exec -n src kafka-0 -- bash -c \
  "echo 'hello-from-source' | kafka-console-producer --topic forward-topic --bootstrap-server kafka.src.svc.cluster.local:9071 --producer.config /tmp/client.properties"
```

4. Consume the mirrored message from the destination cluster:

```bash
kubectl exec -n dest kafka-0 -- kafka-console-consumer \
  --topic forward-topic \
  --bootstrap-server kafka.dest.svc.cluster.local:9071 \
  --consumer.config /tmp/client.properties \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 30000
```

## Tear down

1. Delete all Confluent Platform resources:

```bash
for ns in src dest; do
  for resource in clusterlink kafkatopic kafkarestclass kafka zookeeper; do
    kubectl delete $resource --all -n $ns --ignore-not-found=true
  done
  kubectl delete secret tls-certs ca-pair-sslcerts credential rest-credential password-encoder-secret -n $ns --ignore-not-found=true
done
```

2. Clean up generated certificates:

```bash
rm -rf $TUTORIAL_HOME/certs
```

3. Optionally delete the namespaces:

```bash
kubectl delete namespace src
kubectl delete namespace dest
```

4. Uninstall CFK:

```bash
helm uninstall confluent-operator -n confluent
kubectl delete namespace confluent
```

## Secrets Required

| Secret | Purpose |
|--------|---------|
| `tls-certs` | TLS certificates (fullchain, privkey, cacerts) |
| `ca-pair-sslcerts` | CA keypair for auto-generated certificates |
| `credential` | SASL/PLAIN credentials |
| `rest-credential` | REST API Basic Auth |
| `password-encoder-secret` | Password encoding for cluster link |
| `src-credential` | Source cluster credentials in dest namespace |
| `dest-credential` | Dest cluster credentials in src namespace |

## Troubleshooting

### "SSL handshake failed"
- Verify TLS secrets are properly shared across namespaces
- Check certificate chain is complete

### "Authentication failed"
- Verify SASL credentials are correct
- Check jaasConfig secret format

### "UnsupportedVersionException"
- Ensure `inter.broker.protocol.version=3.1` is set on both clusters

## References

- [Kafka TLS Configuration](https://docs.confluent.io/operator/current/co-network-encryption.html)
- [SASL Authentication](https://docs.confluent.io/operator/current/co-authenticate.html)
- [Bidirectional Cluster Linking](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/configs.html#bidirectional-mode)
