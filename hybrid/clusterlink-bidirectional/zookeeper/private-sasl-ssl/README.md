# Bidirectional Cluster Linking - ZooKeeper Private Cluster with SASL-SSL

This example demonstrates **Bidirectional Cluster Linking** with a **private cluster** setup using ZooKeeper mode. One cluster only accepts inbound connections (INBOUND mode), while the other initiates connections (OUTBOUND mode).

- [Set the current tutorial directory](#set-the-current-tutorial-directory)
- [Prerequisites](#prerequisites)
- [Deploy Confluent for Kubernetes](#deploy-confluent-for-kubernetes)
- [Generate TLS certificates](#generate-tls-certificates)
- [Create secrets](#create-secrets)
- [Deploy the clusters](#deploy-the-clusters)
- [Retrieve the public cluster ID](#retrieve-the-public-cluster-id)
- [Create ClusterLinks](#create-clusterlinks)
- [Validate](#validate)
- [Tear down](#tear-down)

> **Availability**: CFK 3.2.0+ and Confluent Platform 7.5+

## Overview

This implements the "Advanced options for bidirectional Cluster Linking" scenario for ZooKeeper-based clusters:
- **Public cluster** (src): Uses `connection.mode=OUTBOUND` - initiates connections
- **Private cluster** (dest): Uses `connection.mode=INBOUND` - only accepts connections

### Connection Modes

| Cluster | Mode | Behavior |
|---------|------|----------|
| Public (src) | OUTBOUND | Initiates TCP connections |
| Private (dest) | INBOUND | Only accepts incoming connections |

### Important Limitation: Forward Mirroring NOT Possible

In private cluster mode with ZooKeeper, **only reverse mirroring** (private to public) works.

**Why?** Creating a mirror topic requires the destination cluster's REST API to describe the source topic. For forward mirroring (public to private), the private cluster would need to describe topics on the public cluster, but it **cannot reach out** due to INBOUND mode.

```
Reverse mirroring: private (dest) -> public (src) WORKS
Forward mirroring: public (src) -> private (dest) NOT POSSIBLE
```

For bidirectional data flow, use standard bidirectional mode where both clusters can reach each other.

## Set the current tutorial directory

```bash
export TUTORIAL_HOME=<Github repo directory>/hybrid/clusterlink-bidirectional/zookeeper/private-sasl-ssl
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
  -subj "/CN=confluent-ca"
```

3. Generate the server private key:

```bash
openssl genrsa -out $TUTORIAL_HOME/certs/privkey.pem 2048
```

4. Create the SAN extensions file. Note the ZooKeeper-specific SANs:

```bash
cat > $TUTORIAL_HOME/certs/ext.cnf << 'EOF'
[v3_req]
subjectAltName = DNS:*.svc.cluster.local,DNS:kafka.src.svc.cluster.local,DNS:kafka.dest.svc.cluster.local,DNS:zookeeper.src.svc.cluster.local,DNS:zookeeper.dest.svc.cluster.local,DNS:*.kafka.src.svc.cluster.local,DNS:*.kafka.dest.svc.cluster.local,DNS:*.zookeeper.src.svc.cluster.local,DNS:*.zookeeper.dest.svc.cluster.local
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

Source (public) cluster credentials:

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

Destination (private) cluster credentials:

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
# Source credentials in dest namespace (for INBOUND link)
kubectl create secret generic src-credential -n dest \
  --from-literal=plain.txt="$(printf 'username=src-kafka\npassword=src-kafka-secret')" \
  --dry-run=client -o yaml | kubectl apply -f -

# Dest credentials in src namespace (for OUTBOUND link)
kubectl create secret generic dest-credential -n src \
  --from-literal=plain.txt="$(printf 'username=dest-kafka\npassword=dest-kafka-secret')" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Deploy the clusters

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

## Retrieve the public cluster ID

The public cluster ID is required for the INBOUND link because the private cluster cannot reach the public cluster to discover its ID.

1. Wait for the REST API to become available:

```bash
sleep 20
```

2. Retrieve the cluster ID:

```bash
SRC_CLUSTER_ID=""
for i in $(seq 1 30); do
  SRC_CLUSTER_ID=$(kubectl get kafkarestclass src-rest -n src -o jsonpath='{.status.kafkaClusterID}' 2>/dev/null || echo "")
  if [ -n "$SRC_CLUSTER_ID" ]; then
    break
  fi
  echo "Waiting for cluster ID... ($i/30)"
  sleep 5
done

echo "Public cluster ID: $SRC_CLUSTER_ID"
```

If the cluster ID is empty after 30 attempts, check that the Kafka cluster and KafkaRestClass are healthy.

## Create ClusterLinks

**Important**: For private cluster mode, the OUTBOUND link should be created first.

1. Create the OUTBOUND link (public cluster):

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/clusterlinks/src-clusterlink.yaml
```

2. Create the INBOUND link (private cluster) with the source cluster ID substituted:

```bash
cat $TUTORIAL_HOME/manifests/clusterlinks/dest-clusterlink.yaml | \
  sed "s/\${SOURCE_CLUSTER_ID}/$SRC_CLUSTER_ID/g" | \
  kubectl apply -f -
```

3. Monitor ClusterLink status. The OUTBOUND link should become healthy first:

```bash
kubectl get clusterlink -n src
kubectl get clusterlink -n dest
```

## Validate

1. Wait for the OUTBOUND link (public cluster) to become healthy:

```bash
for i in $(seq 1 60); do
  SRC_STATE=$(kubectl get clusterlink src-cluster-link -n src -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
  if [ "$SRC_STATE" = "CREATED" ]; then
    echo "OUTBOUND link healthy: $SRC_STATE"
    break
  fi
  echo "Waiting... ($i/60) - State: $SRC_STATE"
  sleep 10
done
```

2. Check the INBOUND link (private cluster):

```bash
for i in $(seq 1 30); do
  DEST_STATE=$(kubectl get clusterlink dest-cluster-link -n dest -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
  if [ "$DEST_STATE" = "CREATED" ]; then
    echo "INBOUND link healthy: $DEST_STATE"
    break
  fi
  echo "Waiting... ($i/30) - State: $DEST_STATE"
  sleep 10
done
```

3. Create SASL-SSL client configuration on each cluster:

```bash
kubectl exec -n src kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="src-kafka" password="src-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=$(grep jksPassword /mnt/sslcerts/jksPassword.txt | cut -d= -f2)
EOF'

kubectl exec -n dest kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="dest-kafka" password="dest-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=$(grep jksPassword /mnt/sslcerts/jksPassword.txt | cut -d= -f2)
EOF'
```

4. Test reverse mirroring (private to public -- the only direction that works). Produce to `reverse-topic` on the private cluster:

```bash
kubectl exec -n dest kafka-0 -- bash -c \
  "echo 'hello-from-private' | kafka-console-producer --topic reverse-topic --bootstrap-server kafka.dest.svc.cluster.local:9071 --producer.config /tmp/client.properties"
```

5. Consume the mirrored message from the public cluster:

```bash
kubectl exec -n src kafka-0 -- kafka-console-consumer \
  --topic reverse-topic \
  --bootstrap-server kafka.src.svc.cluster.local:9071 \
  --consumer.config /tmp/client.properties \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 30000
```

> **Note**: Forward mirroring (public to private) is NOT possible in private cluster mode with ZooKeeper. See the [Overview](#overview) section for details.

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

2. Delete cross-namespace credential secrets:

```bash
kubectl delete secret src-credential -n dest --ignore-not-found=true
kubectl delete secret dest-credential -n src --ignore-not-found=true
```

3. Clean up generated certificates:

```bash
rm -rf $TUTORIAL_HOME/certs
```

4. Optionally delete the namespaces:

```bash
kubectl delete namespace src
kubectl delete namespace dest
```

5. Uninstall CFK:

```bash
helm uninstall confluent-operator -n confluent
kubectl delete namespace confluent
```

## Critical Gotchas for Private Cluster Mode

### Creation Order

```
1. Create OUTBOUND link (public cluster) FIRST
2. Create INBOUND link (private cluster)
3. Wait for OUTBOUND link to become healthy FIRST
4. THEN the INBOUND link will become healthy
```

If you wait for the INBOUND link first, it will timeout.

### Do NOT Set ClusterLinkId for Bidirectional INBOUND Links

```
Error: Unexpected cluster link id. Should not be provided for bi-directional 
cluster link with inbound connections. (40002)
```

### cluster.link.id Config Must Match Remote Cluster

```yaml
spec:
  configs:
    cluster.link.id: "<public-cluster-id>"
```

### Source Cluster ID Required for INBOUND Mode

```yaml
spec:
  sourceKafkaCluster:
    clusterID: "<public-cluster-id>"
```

### inter.broker.protocol.version=3.1 Required

For ZooKeeper mode (not needed for KRaft):

```yaml
spec:
  configOverrides:
    server:
      - inter.broker.protocol.version=3.1
```

## Troubleshooting

### "Timed out waiting for node assignment"
- The INBOUND link is waiting for a connection
- Ensure OUTBOUND link is created and healthy first

### "Remote cluster id mismatch"
- Get correct cluster ID:
  ```bash
  kubectl get kafkarestclass src-rest -n src -o jsonpath='{.status.kafkaClusterID}'
  ```

### "UnsupportedVersionException"
- Ensure `inter.broker.protocol.version=3.1` is set on both clusters

## References

- [Advanced Options for Bidirectional Cluster Linking](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/configs.html#advanced-options-for-bidirectional-cluster-linking)
