# Bidirectional Cluster Linking - KRaft Private Cluster with SASL-SSL

This example demonstrates **Bidirectional Cluster Linking** with a **private cluster** setup where one cluster only accepts inbound connections. This pattern is essential when one cluster is behind a firewall or NAT and cannot initiate outbound connections.

- [Set the current tutorial directory](#set-the-current-tutorial-directory)
- [Prerequisites](#prerequisites)
- [Deploy Confluent for Kubernetes](#deploy-confluent-for-kubernetes)
- [Generate TLS certificates](#generate-tls-certificates)
- [Create secrets](#create-secrets)
- [Deploy the clusters](#deploy-the-clusters)
- [Create KafkaRestClass and retrieve cluster ID](#create-kafkarestclass-and-retrieve-cluster-id)
- [Create topics and ClusterLinks](#create-topics-and-clusterlinks)
- [Validate](#validate)
- [Tear down](#tear-down)

> **Availability**: CFK 3.2.0+ and Confluent Platform 7.5+

## Overview

This implements the "Advanced options for bidirectional Cluster Linking" scenario:
- **Public cluster** (source namespace): Uses `connection.mode=OUTBOUND` - initiates connections
- **Private cluster** (destination namespace): Uses `connection.mode=INBOUND` - only accepts connections

```
+-----------------------------------------------------------------------------+
|                      PRIVATE CLUSTER CLUSTER LINK                           |
+-----------------------------------------------------------------------------+
|                                                                             |
|   +---------------------+                    +---------------------+        |
|   |   PUBLIC CLUSTER    |                    |  PRIVATE CLUSTER    |        |
|   |   (Can reach out)   |                    |  (Behind firewall)  |        |
|   +---------------------+                    +---------------------+        |
|   |                     |                    |                     |        |
|   |  ClusterLink        | -----------------> |  ClusterLink        |        |
|   |  (OUTBOUND mode)    |   Initiates        |  (INBOUND mode)    |        |
|   |                     |   Connection       |                     |        |
|   |                     |                    |                     |        |
|   |  reverse-topic <------------------------------- reverse-topic  |        |
|   |    (mirror)         |  Reverse Mirror    |   (original)        |        |
|   |                     |                    |                     |        |
|   |  forward-topic      |  Forward Mirror    |  forward-topic      |        |
|   |   (original)  ------------------------------>  (mirror)        |        |
|   |                     |                    |                     |        |
|   +---------------------+                    +---------------------+        |
|                                                                             |
+-----------------------------------------------------------------------------+
```

### Connection Modes

| Mode | Used By | Behavior |
|------|---------|----------|
| OUTBOUND | Public cluster | Initiates TCP connections to remote cluster |
| INBOUND | Private cluster | Only accepts incoming connections, never initiates |

### What works in private cluster mode

- Forward mirroring (public to private): Configured on the INBOUND link with `direction: toDestination`
- Reverse mirroring (private to public): Configured on the OUTBOUND link with `direction: toDestination`

## Set the current tutorial directory

```bash
export TUTORIAL_HOME=<Github repo directory>/hybrid/clusterlink-bidirectional/kraft/private-sasl-ssl
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

4. Create the SAN extensions file:

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
# Source credentials in dest namespace (for INBOUND link to validate connections)
kubectl create secret generic src-credential -n dest \
  --from-literal=plain.txt="$(printf 'username=src-kafka\npassword=src-kafka-secret')" \
  --dry-run=client -o yaml | kubectl apply -f -

# Dest credentials in src namespace (for OUTBOUND link to auth to dest)
kubectl create secret generic dest-credential -n src \
  --from-literal=plain.txt="$(printf 'username=dest-kafka\npassword=dest-kafka-secret')" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Deploy the clusters

1. Deploy the public cluster (source):

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/kraftcontroller.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/kafka.yaml
```

2. Deploy the private cluster (destination):

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

## Create KafkaRestClass and retrieve cluster ID

1. Create KafkaRestClass resources:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/kafkarestclass.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/kafkarestclass.yaml
```

2. Wait for the REST API to become available:

```bash
sleep 20
```

3. Retrieve the public (source) cluster ID. This is **required** for INBOUND mode because the private cluster cannot reach the public cluster to discover its ID:

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

## Create topics and ClusterLinks

1. Create topics:

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/topics.yaml
kubectl apply -f $TUTORIAL_HOME/manifests/dest-cluster/topics.yaml
sleep 10
```

2. **Create the INBOUND link first** (private cluster). The cluster link manifest uses a `${SOURCE_CLUSTER_ID}` placeholder that must be substituted with the actual cluster ID:

```bash
cat $TUTORIAL_HOME/manifests/dest-cluster/clusterlink.yaml | \
  sed "s/\${SOURCE_CLUSTER_ID}/$SRC_CLUSTER_ID/g" | \
  kubectl apply -f -
```

3. Create the OUTBOUND link (public cluster):

```bash
kubectl apply -f $TUTORIAL_HOME/manifests/src-cluster/clusterlink.yaml
```

**Important**: The INBOUND link must be created first so that it is assigned a new link ID. The OUTBOUND link then gets the link ID from the other cluster. If you reverse the order, the second link cannot get the same link ID since it cannot talk to the other cluster.

4. Monitor ClusterLink status. The OUTBOUND link should become healthy first:

```bash
kubectl get clusterlink -n src
kubectl get clusterlink -n dest
```

## Validate

1. Wait for the OUTBOUND link (public cluster) to become healthy:

```bash
for i in $(seq 1 60); do
  SRC_LINK_STATE=$(kubectl get clusterlink src-cluster-link -n src -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
  if [ "$SRC_LINK_STATE" = "CREATED" ]; then
    echo "OUTBOUND link is healthy: $SRC_LINK_STATE"
    break
  fi
  echo "Waiting... ($i/60) - State: $SRC_LINK_STATE"
  sleep 10
done
```

2. Then check the INBOUND link (private cluster):

```bash
for i in $(seq 1 30); do
  DEST_LINK_STATE=$(kubectl get clusterlink dest-cluster-link -n dest -o jsonpath='{.status.state}' 2>/dev/null || echo "NotFound")
  if [ "$DEST_LINK_STATE" = "CREATED" ]; then
    echo "INBOUND link is healthy: $DEST_LINK_STATE"
    break
  fi
  echo "Waiting... ($i/30) - State: $DEST_LINK_STATE"
  sleep 10
done
```

3. Create SASL-SSL client configuration on each cluster:

```bash
kubectl exec -n src kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
bootstrap.servers=kafka.src.svc.cluster.local:9071
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="src-kafka" password="src-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=$(grep jksPassword /mnt/sslcerts/jksPassword.txt | cut -d= -f2)
EOF'

kubectl exec -n dest kafka-0 -- bash -c 'cat > /tmp/client.properties << EOF
bootstrap.servers=kafka.dest.svc.cluster.local:9071
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="dest-kafka" password="dest-kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=$(grep jksPassword /mnt/sslcerts/jksPassword.txt | cut -d= -f2)
EOF'
```

4. Test reverse mirroring (private to public). Produce to `reverse-topic` on the private cluster:

```bash
kubectl exec -n dest kafka-0 -- bash -c \
  "echo 'hello-from-private' | kafka-console-producer \
   --topic reverse-topic \
   --bootstrap-server kafka.dest.svc.cluster.local:9071 \
   --producer.config /tmp/client.properties"
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

6. Test forward mirroring (public to private). Produce to `forward-topic` on the public cluster:

```bash
kubectl exec -n src kafka-0 -- bash -c \
  "echo 'hello-from-public' | kafka-console-producer \
   --topic forward-topic \
   --bootstrap-server kafka.src.svc.cluster.local:9071 \
   --producer.config /tmp/client.properties"
```

7. Consume the mirrored message from the private cluster:

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
for ns in src dest; do
  kubectl delete secret tls-certs credential rest-credential password-encoder-secret ca-pair-sslcerts -n $ns --ignore-not-found=true
done
kubectl delete secret src-credential -n dest --ignore-not-found=true
kubectl delete secret dest-credential -n src --ignore-not-found=true
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

## Critical Gotchas for Private Cluster Mode

### Creation Order is Critical

For private cluster bidirectional links:

1. Create the **INBOUND** link first (on the private cluster)
2. Create the **OUTBOUND** link (on the public cluster)
3. Wait for the **OUTBOUND** link to become healthy first
4. Then the **INBOUND** link will become healthy

The INBOUND link must be created first so it is assigned a new link ID. The OUTBOUND link then gets the link ID from the other cluster.

### Do NOT Set ClusterLinkId for Bidirectional INBOUND Links

The Kafka REST API returns an error if you provide `ClusterLinkId` for bidirectional links with INBOUND mode:

```
Unexpected cluster link id. Should not be provided for bi-directional 
cluster link with inbound connections. (40002)
```

CFK handles this automatically, but be aware if troubleshooting.

### cluster.link.id Config (Auto-Populated by CFK)

For INBOUND mode, the `cluster.link.id` must match the remote cluster's ID (the public/source cluster's ID). In CFK, this is automatically derived from `sourceKafkaCluster.clusterID`:

```yaml
spec:
  sourceKafkaCluster:
    clusterID: "<public-cluster-id>"  # CFK uses this to set cluster.link.id
```

### Source Cluster ID Required for INBOUND Mode

Since the private cluster cannot reach the public cluster to discover its ID, you must explicitly provide it:

```yaml
spec:
  sourceKafkaCluster:
    clusterID: "<public-cluster-id>"
```

### "Timed out waiting for a node assignment" Error

This error typically means the INBOUND link was not created first. The INBOUND link must be assigned a new link ID before the OUTBOUND link can get that same ID.

## Troubleshooting

### ClusterLink Stuck at "Creating"

1. Check which link is stuck:
   ```bash
   kubectl get clusterlink -A
   ```

2. If INBOUND link is stuck, verify OUTBOUND link is healthy:
   ```bash
   kubectl get clusterlink -n src -o yaml
   ```

3. Check events for errors:
   ```bash
   kubectl describe clusterlink -n dest dest-cluster-link
   ```

### "Remote cluster id mismatch" Error

The `cluster.link.id` config doesn't match the actual remote cluster ID:
1. Get the correct cluster ID:
   ```bash
   kubectl get kafkarestclass src-rest -n src -o jsonpath='{.status.kafkaClusterID}'
   ```
2. Update the ClusterLink spec with the correct ID

### Connection Timeout Errors

For private clusters, ensure:
1. The public cluster can reach the private cluster's Kafka endpoint
2. No network policies are blocking traffic
3. The OUTBOUND link is initiating connections correctly

## Production Recommendations

1. **Network Security**: Use network policies to restrict which pods can connect to the private cluster
2. **Certificate Validation**: Ensure TLS certificates are properly validated to prevent MITM attacks
3. **Monitoring**: Set up alerts for ClusterLink state changes, replication lag thresholds, and connection failures
4. **Failover Testing**: Regularly test that bidirectional mirroring works correctly

## References

- [Advanced Options for Bidirectional Cluster Linking](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/configs.html#advanced-options-for-bidirectional-cluster-linking)
- [Source-Initiated Cluster Linking](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/configs.html#source-initiated-cluster-linking)
