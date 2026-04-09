# Bidirectional Cluster Linking - KRaft with SASL-SSL

This example demonstrates **Bidirectional Cluster Linking** with KRaft mode using **SASL/PLAIN authentication and TLS encryption**. This is the recommended configuration for production environments.

- [Set the current tutorial directory](#set-the-current-tutorial-directory)
- [Prerequisites](#prerequisites)
- [Deploy Confluent for Kubernetes](#deploy-confluent-for-kubernetes)
- [Generate TLS certificates](#generate-tls-certificates)
- [Create secrets](#create-secrets)
- [Deploy the source and destination clusters](#deploy-the-source-and-destination-clusters)
- [Create KafkaRestClass and topics](#create-kafkarestclass-and-topics)
- [Create bidirectional ClusterLinks](#create-bidirectional-clusterlinks)
- [Validate](#validate)
- [Tear down](#tear-down)

> **Availability**: CFK 3.2.0+ and Confluent Platform 7.4+

## Overview

This example sets up:
- Two Kafka clusters in KRaft mode with SASL/PLAIN + TLS encryption
- Source cluster using user-provided TLS certificates
- Destination cluster using CFK auto-generated certificates
- Bidirectional cluster link with secure authentication in both directions

### Security Configuration

| Component | Authentication | Encryption |
|-----------|---------------|------------|
| Kafka Interbroker | SASL/PLAIN | TLS |
| Kafka Client Listener | SASL/PLAIN | TLS |
| Kafka REST Server | Basic Auth | TLS |
| ClusterLink | SASL/PLAIN | TLS |

## Set the current tutorial directory

```bash
export TUTORIAL_HOME=<Github repo directory>/hybrid/clusterlink-bidirectional/kraft/sasl-ssl
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

Create a directory for certificates and generate a CA and server certificate with the appropriate SANs for both clusters.

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

4. Create the SAN extensions file. This is important -- the SANs must include pod-level wildcards for both namespaces:

```bash
cat > $TUTORIAL_HOME/certs/ext.cnf << 'EOF'
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = *.svc.cluster.local

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.svc.cluster.local
DNS.2 = *.src.svc.cluster.local
DNS.3 = *.dest.svc.cluster.local
DNS.4 = kafka.src.svc.cluster.local
DNS.5 = kafka.dest.svc.cluster.local
DNS.6 = kraftcontroller.src.svc.cluster.local
DNS.7 = kraftcontroller.dest.svc.cluster.local
DNS.8 = *.kafka.src.svc.cluster.local
DNS.9 = *.kafka.dest.svc.cluster.local
DNS.10 = *.kraftcontroller.src.svc.cluster.local
DNS.11 = *.kraftcontroller.dest.svc.cluster.local
EOF
```

5. Create the CSR and sign the server certificate:

```bash
openssl req -new -key $TUTORIAL_HOME/certs/privkey.pem \
  -out $TUTORIAL_HOME/certs/server.csr \
  -subj "/CN=*.svc.cluster.local/O=Confluent/C=US"

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

Create the same TLS secret in both namespaces (shared CA for both clusters):

```bash
for ns in src dest; do
  kubectl create secret generic tls-certs -n $ns \
    --from-file=fullchain.pem=$TUTORIAL_HOME/certs/fullchain.pem \
    --from-file=cacerts.pem=$TUTORIAL_HOME/certs/cacerts.pem \
    --from-file=privkey.pem=$TUTORIAL_HOME/certs/privkey.pem \
    --dry-run=client -o yaml | kubectl apply -f -
done
```

### Create SASL credential secrets

**Important**: Use different credentials for source and destination clusters to ensure authentication is properly tested.

Create source cluster SASL credentials:

```bash
cat > /tmp/src-plain.txt << 'EOF'
username=src-kafka
password=src-kafka-secret
EOF

cat > /tmp/src-plain-users.json << 'EOF'
{
  "src-kafka": "src-kafka-secret",
  "src-admin": "src-admin-secret",
  "src-client": "src-client-secret"
}
EOF

cat > /tmp/src-plain-interbroker.txt << 'EOF'
username=src-kafka
password=src-kafka-secret
EOF

kubectl create secret generic credential -n src \
  --from-file=plain.txt=/tmp/src-plain.txt \
  --from-file=plain-users.json=/tmp/src-plain-users.json \
  --from-file=plain-interbroker.txt=/tmp/src-plain-interbroker.txt \
  --dry-run=client -o yaml | kubectl apply -f -
```

Create destination cluster SASL credentials:

```bash
cat > /tmp/dest-plain.txt << 'EOF'
username=dest-kafka
password=dest-kafka-secret
EOF

cat > /tmp/dest-plain-users.json << 'EOF'
{
  "dest-kafka": "dest-kafka-secret",
  "dest-admin": "dest-admin-secret",
  "dest-client": "dest-client-secret"
}
EOF

cat > /tmp/dest-plain-interbroker.txt << 'EOF'
username=dest-kafka
password=dest-kafka-secret
EOF

kubectl create secret generic credential -n dest \
  --from-file=plain.txt=/tmp/dest-plain.txt \
  --from-file=plain-users.json=/tmp/dest-plain-users.json \
  --from-file=plain-interbroker.txt=/tmp/dest-plain-interbroker.txt \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Create REST API credential secrets

```bash
kubectl create secret generic rest-credential -n src \
  --from-literal=basic.txt="$(printf 'username=src-admin\npassword=src-admin-secret')" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic rest-credential -n dest \
  --from-literal=basic.txt="$(printf 'username=dest-admin\npassword=dest-admin-secret')" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Create password encoder secrets

```bash
kubectl create secret generic password-encoder-secret -n src \
  --from-literal=password-encoder.txt="password=src-encoder-secret" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic password-encoder-secret -n dest \
  --from-literal=password-encoder.txt="password=dest-encoder-secret" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Create cross-namespace credential secrets for ClusterLink

The destination-side ClusterLink needs source cluster credentials to authenticate to the source Kafka, and vice versa:

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

Clean up temporary files:

```bash
rm -f /tmp/src-plain.txt /tmp/src-plain-users.json /tmp/src-plain-interbroker.txt
rm -f /tmp/dest-plain.txt /tmp/dest-plain-users.json /tmp/dest-plain-interbroker.txt
```

## Deploy the source and destination clusters

1. Deploy the source cluster:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/kraftcontroller.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/kafka.yaml
```

2. Deploy the destination cluster:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/kraftcontroller.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/kafka.yaml
```

3. Wait for KRaft controllers to be ready:

```bash
kubectl wait --for=condition=Ready pod -l app=kraftcontroller -n src --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kraftcontroller -n dest --timeout=300s
```

4. Wait for Kafka clusters to be ready:

```bash
kubectl wait --for=condition=Ready pod -l app=kafka -n src --timeout=300s
kubectl wait --for=condition=Ready pod -l app=kafka -n dest --timeout=300s
```

5. Create TLS secrets for ClusterLink cross-namespace connections. Since both clusters use the same CA, we use the same certs for link trust:

```bash
kubectl create secret generic src-tls-for-link -n dest \
  --from-file=cacerts.pem=$TUTORIAL_HOME/certs/cacerts.pem \
  --from-file=fullchain.pem=$TUTORIAL_HOME/certs/fullchain.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/certs/privkey.pem \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic dest-tls-for-link -n src \
  --from-file=cacerts.pem=$TUTORIAL_HOME/certs/cacerts.pem \
  --from-file=fullchain.pem=$TUTORIAL_HOME/certs/fullchain.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/certs/privkey.pem \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Create KafkaRestClass and topics

1. Create KafkaRestClass resources:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/kafkarestclass.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/kafkarestclass.yaml
```

2. Wait for the REST API to become available:

```bash
sleep 15
```

3. Create topics:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/topics.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/topics.yaml
```

4. Wait for topics to be created:

```bash
sleep 10
```

## Create bidirectional ClusterLinks

1. Create the destination-side ClusterLink (forward mirroring):

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/clusterlink.yaml
```

2. Create the source-side ClusterLink (reverse mirroring):

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/clusterlink.yaml
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
bootstrap.servers=kafka.src.svc.cluster.local:9071
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
bootstrap.servers=kafka.dest.svc.cluster.local:9071
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

5. Test reverse mirroring (destination to source). Produce a message on destination:

```bash
kubectl exec -n dest kafka-0 -- bash -c \
  "echo 'hello-from-destination' | kafka-console-producer --topic reverse-topic --bootstrap-server kafka.dest.svc.cluster.local:9071 --producer.config /tmp/client.properties"
```

6. Consume the mirrored message from the source cluster:

```bash
kubectl exec -n src kafka-0 -- kafka-console-consumer \
  --topic reverse-topic \
  --bootstrap-server kafka.src.svc.cluster.local:9071 \
  --consumer.config /tmp/client.properties \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 30000
```

## Tear down

1. Delete ClusterLinks:

```bash
kubectl delete clusterlink --all -n src --ignore-not-found=true
kubectl delete clusterlink --all -n dest --ignore-not-found=true
```

2. Delete topics:

```bash
kubectl delete kafkatopic --all -n src --ignore-not-found=true
kubectl delete kafkatopic --all -n dest --ignore-not-found=true
```

3. Delete KafkaRestClass:

```bash
kubectl delete kafkarestclass --all -n src --ignore-not-found=true
kubectl delete kafkarestclass --all -n dest --ignore-not-found=true
```

4. Delete Kafka clusters and KRaft controllers:

```bash
kubectl delete kafka --all -n src --ignore-not-found=true
kubectl delete kafka --all -n dest --ignore-not-found=true
kubectl delete kraftcontroller --all -n src --ignore-not-found=true
kubectl delete kraftcontroller --all -n dest --ignore-not-found=true
```

5. Delete all secrets:

```bash
for secret in password-encoder-secret credential rest-credential tls-certs src-tls-for-link dest-tls-for-link src-credential dest-credential; do
  kubectl delete secret $secret -n src --ignore-not-found=true
  kubectl delete secret $secret -n dest --ignore-not-found=true
done
```

6. Clean up generated certificates:

```bash
rm -rf $TUTORIAL_HOME/certs
```

7. Optionally delete the namespaces:

```bash
kubectl delete namespace src
kubectl delete namespace dest
```

8. Uninstall CFK:

```bash
helm uninstall confluent-operator -n confluent
kubectl delete namespace confluent
```

## Important Gotchas

### TLS Trust Between Clusters

For the ClusterLink to connect to the remote cluster, it needs to trust the remote cluster's TLS certificate:

```yaml
spec:
  sourceKafkaCluster:
    bootstrapEndpoint: kafka.src.svc.cluster.local:9071
    tls:
      enabled: true
      secretRef: src-tls-certs
```

### Cross-Namespace TLS Secret Sharing

When clusters are in different namespaces, you need to copy TLS secrets:
- Source cluster's CA cert must be available in destination namespace
- Destination cluster's CA cert must be available in source namespace

### SASL Credentials for ClusterLink

The ClusterLink needs credentials to authenticate to both clusters:

```yaml
spec:
  sourceKafkaCluster:
    authentication:
      type: plain
      jaasConfig:
        secretRef: source-credentials
```

### Auto-Generated vs User-Provided Certificates

This example demonstrates both approaches:
- **Source cluster**: Uses user-provided certificates (more control)
- **Destination cluster**: Uses CFK auto-generated certificates (simpler)

For production, choose one approach consistently and manage certificate rotation.

## Troubleshooting

### "SSL handshake failed" Error

1. Verify TLS secrets exist in both namespaces:
   ```bash
   kubectl get secrets -n src | grep tls
   kubectl get secrets -n dest | grep tls
   ```
2. Check that CA certificates are correctly shared across namespaces
3. Verify certificate chain is complete (server cert + intermediate + root CA)

### "Authentication failed" Error

1. Check SASL credentials are correct:
   ```bash
   kubectl get secret credential -n src -o yaml
   ```
2. Verify jaasConfig secret format matches expected structure
3. Check that the user has appropriate ACLs (if using authorization)

### "UNKNOWN_SERVER_ERROR" from REST API

1. Verify REST API is enabled on Kafka
2. Check REST server authentication configuration
3. Verify KafkaRestClass has correct credentials

## Production Recommendations

1. **Certificate Management**: Use cert-manager or HashiCorp Vault for automated certificate lifecycle
2. **Credential Rotation**: Implement a process for rotating SASL credentials
3. **Network Policies**: Restrict network access between namespaces to only required ports
4. **Monitoring**: Set up alerts for ClusterLink health and replication lag
5. **Backup**: Regularly backup cluster configurations and secrets

## References

- [Kafka TLS Configuration](https://docs.confluent.io/operator/current/co-network-encryption.html)
- [SASL Authentication](https://docs.confluent.io/operator/current/co-authenticate.html)
- [Bidirectional Cluster Linking](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/configs.html#bidirectional-mode)
