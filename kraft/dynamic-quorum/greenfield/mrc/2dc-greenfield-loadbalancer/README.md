## Greenfield MRC with Dynamic Quorum (LoadBalancer, Secured)

Deploy a greenfield multi-region KRaft cluster with dynamic quorum (`kraft.version=1`) and full production security from day one. Two GKE clusters, 6 controllers total (3+3), LoadBalancer external access.

### Security Configuration

| Layer | Setting |
|-------|---------|
| TLS | SecretRef |
| Authentication | SASL/PLAIN |
| Authorization (RBAC) | Kafka + KRaft |
| MDS Provider | OAuth (Keycloak) |
| MRC | Yes (true multi-cluster, LoadBalancer) |

### Architecture

- **Region 1 (central)**: 3 KRaft controllers (bootstrap, IDs 100-102) + 2 Kafka brokers (IDs 30-31)
- **Region 2 (east)**: 3 KRaft controllers (observer, IDs 200-202) + 2 Kafka brokers (IDs 10-11)
- **Total**: 6 controllers (all promoted to voters), quorum requires 4
- **External Access**: LoadBalancer with external-dns for automatic DNS sync

### Prerequisites

- Two Kubernetes clusters with cross-cluster networking (LoadBalancer + DNS)
- CFK 3.2+ operator (will be deployed by the setup steps below)
- CP 7.9.6+ or 8.1.2+ images (8.0.x and 8.2.0 affected by KMETA-2851 for MRC greenfield)
- `openssl` installed locally (for certificate generation)
- `helm` installed (for operator deployment)
- GCP Cloud DNS zone configured for the domain (or equivalent DNS provider)

### Set the Tutorial Home

```bash
export TUTORIAL_HOME=<Tutorial directory>/kraft/dynamic-quorum/greenfield/mrc/2dc-greenfield-loadbalancer
```

### Configuration

Before running the steps below, set the following environment variables to match your environment:

```bash
export REGION1_NS=central                              # Namespace for region 1
export REGION2_NS=east                                 # Namespace for region 2
export REGION1_CONTEXT=<your-region1-k8s-context>      # kubectl context for region 1
export REGION2_CONTEXT=<your-region2-k8s-context>      # kubectl context for region 2
export DOMAIN=my-domain.example.com                    # Replace with your actual domain
```

Replace `my-domain.example.com` with your actual domain throughout the YAML files in `region1/resources/` and `region2/resources/`.

### Pre-Setup: One-Time Infrastructure

These steps set up namespaces, certificates, secrets, Keycloak, external-dns, and the CFK operator on both clusters. Run these once.

#### Step 1: Create namespaces

```bash
kubectl --context $REGION1_CONTEXT create namespace $REGION1_NS
kubectl --context $REGION2_CONTEXT create namespace $REGION2_NS
```

#### Step 2: Generate TLS certificates

Generate a CA and component certificates with wildcard SANs covering both regions:

```bash
mkdir -p $TUTORIAL_HOME/.generated-certs
cd $TUTORIAL_HOME/.generated-certs

# Generate CA
openssl req -new -nodes -x509 -days 3650 \
    -keyout ca-key.pem -out ca-cert.pem \
    -subj '/C=US/ST=California/L=PaloAlto/O=Confluent/OU=Engineering/CN=TestCA'

# Create SAN config
cat > san.cnf <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
C = US
ST = California
L = PaloAlto
O = Confluent
OU = Engineering
CN = kafka

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.$DOMAIN
DNS.2 = *.$REGION1_NS.svc.cluster.local
DNS.3 = *.$REGION2_NS.svc.cluster.local
DNS.4 = *.svc.cluster.local
DNS.5 = *.cluster.local
DNS.6 = localhost
DNS.7 = *.kafka.$REGION1_NS.svc.cluster.local
DNS.8 = *.kafka.$REGION2_NS.svc.cluster.local
DNS.9 = *.kraftcontroller.$REGION1_NS.svc.cluster.local
DNS.10 = *.kraftcontroller.$REGION2_NS.svc.cluster.local
DNS.11 = kafka.$REGION1_NS.svc.cluster.local
DNS.12 = kafka.$REGION2_NS.svc.cluster.local
DNS.13 = kraftcontroller.$REGION1_NS.svc.cluster.local
DNS.14 = kraftcontroller.$REGION2_NS.svc.cluster.local
EOF

# Generate component certificate
openssl req -new -nodes -keyout component-key.pem -out component.csr -config san.cnf
openssl x509 -req -days 3650 -in component.csr \
    -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial \
    -out component-cert.pem -extensions v3_req -extfile san.cnf

# Create fullchain
cat component-cert.pem ca-cert.pem > fullchain.pem
```

#### Step 3: Create TLS secrets

```bash
for ctx_ns in "$REGION1_CONTEXT:$REGION1_NS" "$REGION2_CONTEXT:$REGION2_NS"; do
  CTX="${ctx_ns%%:*}"
  NS="${ctx_ns##*:}"
  for name in tls-kraftcontroller tls-kafka; do
    kubectl --context $CTX create secret generic $name \
        --from-file=fullchain.pem=$TUTORIAL_HOME/.generated-certs/fullchain.pem \
        --from-file=privkey.pem=$TUTORIAL_HOME/.generated-certs/component-key.pem \
        --from-file=cacerts.pem=$TUTORIAL_HOME/.generated-certs/ca-cert.pem \
        -n $NS
  done
done
```

#### Step 4: Create credential secrets (SASL/PLAIN)

Create a `credential` secret with SASL/PLAIN credentials on both clusters. The secret requires these keys:
- `plain.txt` -- client credentials
- `plain-users.json` -- server-side user list
- `plain-interbroker.txt` -- inter-controller/inter-broker credentials
- `kafka-server-listener-internal-plain-metrics.txt` -- metrics reporter credentials

```bash
# Create credential files
cat > /tmp/plain.txt <<'EOF'
username=kafka
password=kafka-secret
EOF

cat > /tmp/plain-users.json <<'EOF'
{
  "kafka": "kafka-secret",
  "admin": "admin-secret"
}
EOF

for ctx_ns in "$REGION1_CONTEXT:$REGION1_NS" "$REGION2_CONTEXT:$REGION2_NS"; do
  CTX="${ctx_ns%%:*}"
  NS="${ctx_ns##*:}"
  kubectl --context $CTX create secret generic credential \
      --from-file=plain.txt=/tmp/plain.txt \
      --from-file=plain-users.json=/tmp/plain-users.json \
      --from-file=plain-interbroker.txt=/tmp/plain.txt \
      --from-file=kafka-server-listener-internal-plain-metrics.txt=/tmp/plain.txt \
      -n $NS
done
```

#### Step 5: Create MDS token keypair secret

```bash
openssl genrsa -out /tmp/mds-tokenkeypair.pem 2048
openssl rsa -in /tmp/mds-tokenkeypair.pem -outform PEM -pubout -out /tmp/mds-public.pem

for ctx_ns in "$REGION1_CONTEXT:$REGION1_NS" "$REGION2_CONTEXT:$REGION2_NS"; do
  CTX="${ctx_ns%%:*}"
  NS="${ctx_ns##*:}"
  kubectl --context $CTX create secret generic mds-token \
      --from-file=mdsPublicKey.pem=/tmp/mds-public.pem \
      --from-file=mdsTokenKeyPair.pem=/tmp/mds-tokenkeypair.pem \
      -n $NS
done

rm -f /tmp/mds-tokenkeypair.pem /tmp/mds-public.pem
```

#### Step 6: Create OAuth JAAS secret

OAuth client credentials for Keycloak (used by ERP and KafkaRest dependency).

```bash
cat > /tmp/oauth.txt <<'EOF'
clientId=ssologin
clientSecret=my-oauth-client-secret
EOF

for ctx_ns in "$REGION1_CONTEXT:$REGION1_NS" "$REGION2_CONTEXT:$REGION2_NS"; do
  CTX="${ctx_ns%%:*}"
  NS="${ctx_ns##*:}"
  kubectl --context $CTX create secret generic oauth-jass \
      --from-file=oauth.txt=/tmp/oauth.txt \
      -n $NS
done

rm -f /tmp/oauth.txt
```

#### Step 7: Deploy Keycloak

Keycloak provides OAuth/OIDC identity resolution for MDS RBAC. Deployed once in Region 1 -- both regions reference it via LoadBalancer DNS at `http://keycloak.$DOMAIN:8080/realms/sso_test`.

```bash
# Create Keycloak realm ConfigMap (use the realm template from resources/)
kubectl --context $REGION1_CONTEXT create configmap keycloak-configmap \
    --from-file=realm.json=$TUTORIAL_HOME/resources/keycloak-realm.json \
    -n $REGION1_NS

# Deploy Keycloak
kubectl --context $REGION1_CONTEXT apply -f $TUTORIAL_HOME/resources/keycloak.yaml

# Wait for Keycloak to be ready
kubectl --context $REGION1_CONTEXT rollout status deployment/keycloak -n $REGION1_NS --timeout=180s
```

#### Step 8: Deploy External-DNS

External-DNS syncs LoadBalancer IPs with your DNS provider (e.g., GCP Cloud DNS). Each cluster needs its own external-dns deployment.

```bash
# Region 1
kubectl --context $REGION1_CONTEXT apply -f $TUTORIAL_HOME/resources/external-dns-region1.yaml

# Region 2
kubectl --context $REGION2_CONTEXT apply -f $TUTORIAL_HOME/resources/external-dns-region2.yaml
```

#### Step 9: Deploy CFK operator via Helm

Each cluster gets its own namespaced operator instance.

```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

# Region 1
helm --kube-context $REGION1_CONTEXT upgrade --install \
    confluent-operator confluentinc/confluent-for-kubernetes \
    --namespace $REGION1_NS

# Region 2
helm --kube-context $REGION2_CONTEXT upgrade --install \
    confluent-operator confluentinc/confluent-for-kubernetes \
    --namespace $REGION2_NS
```

#### Step 10: Create admin CLI config

Creates a ConfigMap with security properties mounted at `/mnt/admin-config` on KRaft pods. This is needed for admin CLI commands like `kafka-metadata-quorum` and `kafka-features`.

```bash
cat > /tmp/security.properties <<'EOF'
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="kafka" password="kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
ssl.truststore.type=PKCS12
EOF

kubectl --context $REGION1_CONTEXT create configmap kraft-admin-config \
    --from-file=security.properties=/tmp/security.properties -n $REGION1_NS
kubectl --context $REGION2_CONTEXT create configmap kraft-admin-config \
    --from-file=security.properties=/tmp/security.properties -n $REGION2_NS

rm -f /tmp/security.properties
```

### Deployment Steps

#### Step 1: Deploy bootstrap ConfigMap and RBAC (Region 1)

```bash
kubectl --context $REGION1_CONTEXT apply -f $TUTORIAL_HOME/region1/resources/bootstrap-configmap.yaml
kubectl --context $REGION1_CONTEXT apply -f $TUTORIAL_HOME/region1/resources/rbac.yaml
```

#### Step 2: Deploy KRaftController in Region 1 (bootstrap)

Region 1 KRaftController has `dynamicQuorumConfig.bootstrapPod: 0`. The bootstrap pod (kraftcontroller-0) formats the quorum with `--standalone`. Other pods join as observers.

```bash
kubectl --context $REGION1_CONTEXT apply -f $TUTORIAL_HOME/region1/resources/kraftcontroller.yaml

kubectl --context $REGION1_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kraftcontroller/kraftcontroller -n $REGION1_NS --timeout=10m
```

#### Step 3: Get cluster ID from Region 1

Retrieve the cluster ID and update the Region 2 KRaftController YAML.

```bash
CLUSTER_ID=$(kubectl --context $REGION1_CONTEXT get kraftcontroller kraftcontroller \
    -n $REGION1_NS -o jsonpath='{.status.clusterID}')
echo "Cluster ID: $CLUSTER_ID"

# Update the clusterID in region2 kraftcontroller.yaml
sed -i '' "s/clusterID: .*/clusterID: $CLUSTER_ID/" \
    $TUTORIAL_HOME/region2/resources/kraftcontroller.yaml
```

#### Step 4: Deploy KRaftController in Region 2 (observer)

Region 2 KRaftController has `dynamicQuorumConfig.enabled: true` (no `bootstrapPod`). All controllers join the existing quorum as observers using the cluster ID from Region 1.

```bash
kubectl --context $REGION2_CONTEXT apply -f $TUTORIAL_HOME/region2/resources/kraftcontroller.yaml

kubectl --context $REGION2_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kraftcontroller/kraftcontroller -n $REGION2_NS --timeout=10m
```

#### Step 5: Promote observers to voters

Check `describe --replication` output from the previous step. If controllers already show `ReplicaState: Follower` (not `Observer`), auto-join (CP 8.2+) has already promoted them and you can **skip this step**.

If controllers show `ReplicaState: Observer`, they must be promoted to voters. Run `add-controller` from each observer pod, pointing to the bootstrap controller's external DNS.

```bash
BOOTSTRAP_ENDPOINT="kraft-central0.$DOMAIN:9074"

# Promote Region 1 controllers (IDs 101, 102)
for i in 1 2; do
  kubectl --context $REGION1_CONTEXT exec kraftcontroller-$i -n $REGION1_NS -- bash -c "
    cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
    cat /mnt/admin-config/security.properties >> /tmp/admin.properties"
  kubectl --context $REGION1_CONTEXT exec kraftcontroller-$i -n $REGION1_NS -- \
    kafka-metadata-quorum --bootstrap-controller $BOOTSTRAP_ENDPOINT \
    --command-config /tmp/admin.properties add-controller
done

# Promote Region 2 controllers (IDs 200, 201, 202)
for i in 0 1 2; do
  kubectl --context $REGION2_CONTEXT exec kraftcontroller-$i -n $REGION2_NS -- bash -c "
    cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
    cat /mnt/admin-config/security.properties >> /tmp/admin.properties"
  kubectl --context $REGION2_CONTEXT exec kraftcontroller-$i -n $REGION2_NS -- \
    kafka-metadata-quorum --bootstrap-controller $BOOTSTRAP_ENDPOINT \
    --command-config /tmp/admin.properties add-controller
done
```

#### Step 6: Deploy Kafka in both regions

Deploy Kafka brokers with MDS (OAuth/Keycloak) after the quorum is fully formed (all 6 voters).

```bash
kubectl --context $REGION1_CONTEXT apply -f $TUTORIAL_HOME/region1/resources/kafka.yaml
kubectl --context $REGION2_CONTEXT apply -f $TUTORIAL_HOME/region2/resources/kafka.yaml

kubectl --context $REGION1_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kafka/kafka -n $REGION1_NS --timeout=10m
kubectl --context $REGION2_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kafka/kafka -n $REGION2_NS --timeout=10m
```

### Validate

Check quorum status (all 6 controllers should be voters):

```bash
kubectl --context $REGION1_CONTEXT exec kraftcontroller-0 -n $REGION1_NS -- bash -c "
  cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
  cat /mnt/admin-config/security.properties >> /tmp/admin.properties
  kafka-metadata-quorum --bootstrap-controller localhost:9074 \
    --command-config /tmp/admin.properties describe --replication"
```

Check `kraft.version`:

```bash
kubectl --context $REGION1_CONTEXT exec kraftcontroller-0 -n $REGION1_NS -- bash -c "
  cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
  cat /mnt/admin-config/security.properties >> /tmp/admin.properties
  kafka-features --bootstrap-controller localhost:9074 \
    --command-config /tmp/admin.properties describe" | grep kraft.version
```

Check DNS sync:

```bash
$TUTORIAL_HOME/check-dns-sync.sh watch
```

### DNS Endpoints

| Endpoint | Port | Purpose |
|----------|------|---------|
| `kraft-central{0,1,2}.$DOMAIN` | 9074 | KRaft controller listener (Region 1) |
| `kraft-east{0,1,2}.$DOMAIN` | 9074 | KRaft controller listener (Region 2) |
| `kafka-central-ext{0,1}.$DOMAIN` | 9092 | Kafka external listener (Region 1) |
| `kafka-east-ext{0,1}.$DOMAIN` | 9092 | Kafka external listener (Region 2) |
| `keycloak.$DOMAIN` | 8080 | Keycloak OIDC provider (Region 1 only) |

### Tear Down

The cleanup proceeds in phases to avoid dependency issues.

**Phase 1: Delete CP resources**

```bash
# Region 1
kubectl --context $REGION1_CONTEXT delete kafka kafka -n $REGION1_NS --timeout=5m
kubectl --context $REGION1_CONTEXT delete kraftcontroller kraftcontroller -n $REGION1_NS --timeout=5m

# Region 2
kubectl --context $REGION2_CONTEXT delete kafka kafka -n $REGION2_NS --timeout=5m
kubectl --context $REGION2_CONTEXT delete kraftcontroller kraftcontroller -n $REGION2_NS --timeout=5m
```

**Phase 2: Delete bootstrap ConfigMap and RBAC**

```bash
kubectl --context $REGION1_CONTEXT delete configmap kraftcontroller-dynamic-quorum -n $REGION1_NS
kubectl --context $REGION1_CONTEXT delete rolebinding kraftcontroller-bootstrap-rolebinding -n $REGION1_NS
kubectl --context $REGION1_CONTEXT delete role kraftcontroller-bootstrap-role -n $REGION1_NS
kubectl --context $REGION1_CONTEXT delete serviceaccount kraftcontroller-sa -n $REGION1_NS
```

**Phase 3: Delete Keycloak**

```bash
kubectl --context $REGION1_CONTEXT delete deployment keycloak -n $REGION1_NS
kubectl --context $REGION1_CONTEXT delete service keycloak -n $REGION1_NS
kubectl --context $REGION1_CONTEXT delete configmap keycloak-configmap -n $REGION1_NS
```

**Phase 4: Delete operator and secrets**

```bash
helm --kube-context $REGION1_CONTEXT uninstall confluent-operator -n $REGION1_NS
helm --kube-context $REGION2_CONTEXT uninstall confluent-operator -n $REGION2_NS

for secret in confluent-registry tls-kraftcontroller tls-kafka credential mds-token oauth-jass; do
  kubectl --context $REGION1_CONTEXT delete secret $secret -n $REGION1_NS 2>/dev/null || true
  kubectl --context $REGION2_CONTEXT delete secret $secret -n $REGION2_NS 2>/dev/null || true
done

kubectl --context $REGION1_CONTEXT delete configmap kraft-admin-config -n $REGION1_NS
kubectl --context $REGION2_CONTEXT delete configmap kraft-admin-config -n $REGION2_NS
```

**Phase 5: Delete namespaces**

```bash
kubectl --context $REGION1_CONTEXT delete namespace $REGION1_NS
kubectl --context $REGION2_CONTEXT delete namespace $REGION2_NS
```

**Phase 6: Clean up generated certificates**

```bash
rm -rf $TUTORIAL_HOME/.generated-certs
```

### Important Notes

- **Keycloak must be running** before deploying Kafka with MDS. Deploy it in the pre-setup phase.
- **Certificate SANs** use wildcards (`*.$DOMAIN`) to cover all LoadBalancer DNS names across both regions.
- **All admin commands require `--command-config`** when security is enabled. The setup creates `/mnt/admin-config/security.properties` on each pod.
- **Observer promotion order** does not matter, but all must be promoted before the cluster is production-ready.
- **external-dns** handles DNS for all LoadBalancer services. Check DNS sync with `./check-dns-sync.sh watch`.
- Replace `my-domain.example.com` with your actual domain in all YAML files and commands.
