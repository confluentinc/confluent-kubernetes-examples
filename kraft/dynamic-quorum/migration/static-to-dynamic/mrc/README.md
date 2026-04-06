## Static to Dynamic Quorum Migration for MRC (Secured)

Migrate a multi-region KRaft cluster from static quorum (`kraft.version=0`) to dynamic quorum (`kraft.version=1`) with full production security enabled. Two GKE clusters, 6 controllers total (3+3).

### Security Configuration

| Layer | Setting |
|-------|---------|
| TLS | SecretRef |
| Authentication | SASL/PLAIN |
| Authorization (RBAC) | Kafka + KRaft |
| MDS Provider | OAuth (Keycloak) |
| MRC | Yes (true multi-cluster, LoadBalancer) |

### Version Requirements

| Component | Minimum Version | Notes |
|-----------|----------------|-------|
| **CFK** | 3.2+ | Dynamic quorum support |
| **CP** | 8.0+ | Works on all CP 8.0+ versions. Not affected by KMETA-2851. |

This migration path is not affected by KMETA-2851 because advertised listeners are added in Step 1, after the quorum is already formed.

### Prerequisites

- A **running multi-region KRaft cluster** with static quorum (`kraft.version=0`) and Kafka brokers on two Kubernetes clusters
- CFK 3.2+ operator deployed on both clusters
- CP 8.0+ images
- Cross-cluster networking (LoadBalancer + DNS) already configured
- `kubectl` configured with contexts for both clusters

If you do not have a running cluster, see [Reference: Setting Up a Test Cluster](#reference-setting-up-a-test-cluster) below.

### Set the Tutorial Home

```bash
export TUTORIAL_HOME=<Tutorial directory>/kraft/dynamic-quorum/migration/static-to-dynamic/mrc
```

### Configuration

Before running the steps below, set these environment variables:

```bash
export REGION1_NS=central                              # Namespace for region 1
export REGION2_NS=east                                 # Namespace for region 2
export REGION1_CONTEXT=<your-region1-k8s-context>      # kubectl context for region 1
export REGION2_CONTEXT=<your-region2-k8s-context>      # kubectl context for region 2
export DOMAIN=my-domain.example.com                    # Replace with your actual domain
```

Replace `my-domain.example.com` with your actual domain throughout the YAML files in `region1/resources/` and `region2/resources/`.

### Migration Flow

This migration has 4 phases. The "Properties at Each Phase" table below shows how configuration evolves through the process.

```
Phase 1                      Phase 2                  Phase 3                          Phase 4
Add advertised listeners --> Upgrade kraft.version --> Switch to dynamicQuorumConfig --> Roll Kafka brokers
(MRC cross-cluster           (metadata-level,          (CFK generates                   (pick up new
 admin commands)              no YAML change)           bootstrap.servers,               bootstrap.servers)
                                                        controllers roll)
```

**Properties at Each Phase:**

| Phase | KRaft properties | Kafka properties | kraft.version |
|-------|-----------------|-----------------|---------------|
| Start | voters | voters | 0 |
| After Phase 1 | voters + advListeners | voters (unchanged) | 0 |
| After Phase 2 | voters + advListeners | voters (unchanged) | 1 |
| After Phase 3 | bootstrap.servers + advListeners | voters (unchanged) | 1 |
| After Phase 4 | bootstrap.servers + advListeners | bootstrap.servers | 1 |

#### Pre-migration: Verify starting state

Confirm the cluster is running with static quorum (`kraft.version=0`):

```bash
kubectl --context $REGION1_CONTEXT exec kraftcontroller-0 -n $REGION1_NS -- bash -c "
  cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
  cat /mnt/admin-config/security.properties >> /tmp/admin.properties
  kafka-features --bootstrap-controller localhost:9074 \
    --command-config /tmp/admin.properties describe" | grep kraft.version
```

Expected: `FinalizedVersionLevel: 0`

Check quorum health:

```bash
kubectl --context $REGION1_CONTEXT exec kraftcontroller-0 -n $REGION1_NS -- bash -c "
  cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
  cat /mnt/admin-config/security.properties >> /tmp/admin.properties
  kafka-metadata-quorum --bootstrap-controller localhost:9074 \
    --command-config /tmp/admin.properties describe --replication"
```

All controllers should be voters with low lag.

#### Phase 1: Add Advertised Listeners on KRaft (MRC only)

Add `advertisedListenersEnabled: true` to KRaftController on both clusters. This is required for cross-cluster admin commands to work after the upgrade.

This change alone does not trigger an auto-roll. Add a pod template annotation to force it:

```bash
kubectl --context $REGION1_CONTEXT apply -f $TUTORIAL_HOME/region1/resources/kraftcontroller-phase1-advlisteners.yaml
kubectl --context $REGION2_CONTEXT apply -f $TUTORIAL_HOME/region2/resources/kraftcontroller-phase1-advlisteners.yaml

kubectl --context $REGION1_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kraftcontroller/kraftcontroller -n $REGION1_NS --timeout=10m
kubectl --context $REGION2_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kraftcontroller/kraftcontroller -n $REGION2_NS --timeout=10m
```

#### Phase 2: Upgrade kraft.version

Run from any controller pod. The admin config is needed for SASL/PLAIN + TLS authentication:

```bash
kubectl --context $REGION1_CONTEXT exec kraftcontroller-0 -n $REGION1_NS -- bash -c "
  cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
  cat /mnt/admin-config/security.properties >> /tmp/admin.properties
  kafka-features --bootstrap-controller localhost:9074 \
    --command-config /tmp/admin.properties \
    upgrade --feature kraft.version=1"
```

Verify:

```bash
kubectl --context $REGION1_CONTEXT exec kraftcontroller-0 -n $REGION1_NS -- bash -c "
  cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
  cat /mnt/admin-config/security.properties >> /tmp/admin.properties
  kafka-features --bootstrap-controller localhost:9074 \
    --command-config /tmp/admin.properties describe" | grep kraft.version
```

Expected: `FinalizedVersionLevel: 1`

Check that DirectoryIds changed from placeholder `AAAAAAAAAAAAAAAAAAAAAA` to unique UUIDs:

```bash
kubectl --context $REGION1_CONTEXT exec kraftcontroller-0 -n $REGION1_NS -- bash -c "
  cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
  cat /mnt/admin-config/security.properties >> /tmp/admin.properties
  kafka-metadata-quorum --bootstrap-controller localhost:9074 \
    --command-config /tmp/admin.properties describe --replication"
```

#### Phase 3: Switch KRaft from Voters to Bootstrap Servers

**Do this promptly after Phase 2.** Apply KRaftController with `dynamicQuorumConfig.enabled: true` on both clusters. CFK generates `controller.quorum.bootstrap.servers` and removes `controller.quorum.voters`.

```bash
kubectl --context $REGION1_CONTEXT apply -f $TUTORIAL_HOME/region1/resources/kraftcontroller-phase3-dynamic.yaml
kubectl --context $REGION2_CONTEXT apply -f $TUTORIAL_HOME/region2/resources/kraftcontroller-phase3-dynamic.yaml

kubectl --context $REGION1_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kraftcontroller/kraftcontroller -n $REGION1_NS --timeout=10m
kubectl --context $REGION2_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kraftcontroller/kraftcontroller -n $REGION2_NS --timeout=10m
```

Verify quorum is healthy after the roll:

```bash
kubectl --context $REGION1_CONTEXT exec kraftcontroller-0 -n $REGION1_NS -- bash -c "
  cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
  cat /mnt/admin-config/security.properties >> /tmp/admin.properties
  kafka-metadata-quorum --bootstrap-controller localhost:9074 \
    --command-config /tmp/admin.properties describe --status"

kubectl --context $REGION1_CONTEXT exec kraftcontroller-0 -n $REGION1_NS -- bash -c "
  cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
  cat /mnt/admin-config/security.properties >> /tmp/admin.properties
  kafka-metadata-quorum --bootstrap-controller localhost:9074 \
    --command-config /tmp/admin.properties describe --replication"
```

#### Phase 4: Roll Kafka to Pick Up Bootstrap Servers

Force a rolling restart of Kafka brokers on both clusters:

```bash
kubectl --context $REGION1_CONTEXT patch kafka kafka -n $REGION1_NS --type merge \
    -p '{"spec":{"podTemplate":{"annotations":{"kafkacluster-manual-roll":"phase4"}}}}'
kubectl --context $REGION2_CONTEXT patch kafka kafka -n $REGION2_NS --type merge \
    -p '{"spec":{"podTemplate":{"annotations":{"kafkacluster-manual-roll":"phase4"}}}}'

kubectl --context $REGION1_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kafka/kafka -n $REGION1_NS --timeout=10m
kubectl --context $REGION2_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kafka/kafka -n $REGION2_NS --timeout=10m
```

### Validate

```bash
# Check kraft.version
kubectl --context $REGION1_CONTEXT exec kraftcontroller-0 -n $REGION1_NS -- bash -c "
  cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
  cat /mnt/admin-config/security.properties >> /tmp/admin.properties
  kafka-features --bootstrap-controller localhost:9074 \
    --command-config /tmp/admin.properties describe" | grep kraft.version

# Check quorum status (all controllers should be voters)
kubectl --context $REGION1_CONTEXT exec kraftcontroller-0 -n $REGION1_NS -- bash -c "
  cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
  cat /mnt/admin-config/security.properties >> /tmp/admin.properties
  kafka-metadata-quorum --bootstrap-controller localhost:9074 \
    --command-config /tmp/admin.properties describe --replication"
```

### Important Notes

- **Phase 3 should follow Phase 2 quickly.** A v1 cluster with `controller.quorum.voters` is functional but not optimal for disaster recovery.
- **Kafka does not auto-roll** when KRaft CR changes. A manual roll (Phase 4) is required.
- **All admin commands require `--command-config`** when security is enabled.
- **Keycloak must be running** before deploying Kafka with MDS.
- **Certificate SANs** use wildcards to cover all LoadBalancer DNS names across both regions.
- Replace `my-domain.example.com` with your actual domain in all YAML files and commands.

### Reference: Setting Up a Test Cluster

If you don't already have a running cluster, follow these steps to set one up for testing this migration.

#### Secrets Required

| Secret | Contents | Purpose |
|--------|----------|---------|
| `tls-kraftcontroller` | fullchain.pem, privkey.pem, cacerts.pem | TLS certs for KRaft controllers |
| `tls-kafka` | fullchain.pem, privkey.pem, cacerts.pem | TLS certs for Kafka brokers |
| `credential` | plain.txt, plain-users.json, plain-interbroker.txt, kafka-server-listener-internal-plain-metrics.txt | SASL/PLAIN credentials |
| `mds-token` | mdsPublicKey.pem, mdsTokenKeyPair.pem | MDS token signing keypair |
| `oauth-jass` | oauth.txt | Keycloak OAuth client credentials |

All secrets are created by the steps below.

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

# Create SAN config (must include pod-level wildcards for StatefulSet FQDNs)
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

openssl req -new -nodes -keyout component-key.pem -out component.csr -config san.cnf
openssl x509 -req -days 3650 -in component.csr \
    -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial \
    -out component-cert.pem -extensions v3_req -extfile san.cnf
cat component-cert.pem ca-cert.pem > fullchain.pem
```

#### Step 3: Create TLS secrets (both clusters)

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

```bash
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

#### Step 5: Create MDS token and OAuth secrets (both clusters)

```bash
# MDS token keypair
openssl genrsa -out /tmp/mds-tokenkeypair.pem 2048
openssl rsa -in /tmp/mds-tokenkeypair.pem -outform PEM -pubout -out /tmp/mds-public.pem

# OAuth credentials
cat > /tmp/oauth.txt <<'EOF'
clientId=ssologin
clientSecret=KbLRih1HzjDC267PefuKU7QIoZ8hgHDK
EOF

for ctx_ns in "$REGION1_CONTEXT:$REGION1_NS" "$REGION2_CONTEXT:$REGION2_NS"; do
  CTX="${ctx_ns%%:*}"
  NS="${ctx_ns##*:}"
  kubectl --context $CTX create secret generic mds-token \
      --from-file=mdsPublicKey.pem=/tmp/mds-public.pem \
      --from-file=mdsTokenKeyPair.pem=/tmp/mds-tokenkeypair.pem -n $NS
  kubectl --context $CTX create secret generic oauth-jass \
      --from-file=oauth.txt=/tmp/oauth.txt -n $NS
done

rm -f /tmp/mds-tokenkeypair.pem /tmp/mds-public.pem /tmp/oauth.txt
```

#### Step 6: Deploy Keycloak (Region 1 only)

```bash
kubectl --context $REGION1_CONTEXT create configmap keycloak-configmap \
    --from-file=realm.json=$TUTORIAL_HOME/resources/keycloak-realm.json -n $REGION1_NS
kubectl --context $REGION1_CONTEXT apply -f $TUTORIAL_HOME/resources/keycloak.yaml
kubectl --context $REGION1_CONTEXT rollout status deployment/keycloak -n $REGION1_NS --timeout=180s
```

#### Step 7: Deploy External-DNS (both clusters)

```bash
kubectl --context $REGION1_CONTEXT apply -f $TUTORIAL_HOME/resources/external-dns-region1.yaml
kubectl --context $REGION2_CONTEXT apply -f $TUTORIAL_HOME/resources/external-dns-region2.yaml
```

#### Step 8: Deploy CFK operator (both clusters)

```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

helm --kube-context $REGION1_CONTEXT upgrade --install \
    confluent-operator confluentinc/confluent-for-kubernetes --namespace $REGION1_NS
helm --kube-context $REGION2_CONTEXT upgrade --install \
    confluent-operator confluentinc/confluent-for-kubernetes --namespace $REGION2_NS
```

#### Step 9: Create admin CLI config (both clusters)

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

#### Step 10: Deploy Static Quorum Cluster

Deploy KRaftController with static quorum and Kafka on both clusters:

```bash
# KRaft on both clusters
kubectl --context $REGION1_CONTEXT apply -f $TUTORIAL_HOME/region1/resources/kraftcontroller-phase0-static.yaml
kubectl --context $REGION2_CONTEXT apply -f $TUTORIAL_HOME/region2/resources/kraftcontroller-phase0-static.yaml

kubectl --context $REGION1_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kraftcontroller/kraftcontroller -n $REGION1_NS --timeout=10m
kubectl --context $REGION2_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kraftcontroller/kraftcontroller -n $REGION2_NS --timeout=10m

# Kafka on both clusters
kubectl --context $REGION1_CONTEXT apply -f $TUTORIAL_HOME/region1/resources/kafka.yaml
kubectl --context $REGION2_CONTEXT apply -f $TUTORIAL_HOME/region2/resources/kafka.yaml

kubectl --context $REGION1_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kafka/kafka -n $REGION1_NS --timeout=10m
kubectl --context $REGION2_CONTEXT wait --for=condition=platform.confluent.io/cluster-ready \
    kafka/kafka -n $REGION2_NS --timeout=10m
```

Verify `kraft.version=0`:

```bash
kubectl --context $REGION1_CONTEXT exec kraftcontroller-0 -n $REGION1_NS -- bash -c "
  cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
  cat /mnt/admin-config/security.properties >> /tmp/admin.properties
  kafka-features --bootstrap-controller localhost:9074 \
    --command-config /tmp/admin.properties describe" | grep kraft.version
```

### Tear Down

```bash
# Phase 1: Delete CP resources
kubectl --context $REGION1_CONTEXT delete kafka kafka -n $REGION1_NS --timeout=5m
kubectl --context $REGION1_CONTEXT delete kraftcontroller kraftcontroller -n $REGION1_NS --timeout=5m
kubectl --context $REGION2_CONTEXT delete kafka kafka -n $REGION2_NS --timeout=5m
kubectl --context $REGION2_CONTEXT delete kraftcontroller kraftcontroller -n $REGION2_NS --timeout=5m

# Phase 2: Delete Keycloak
kubectl --context $REGION1_CONTEXT delete deployment keycloak -n $REGION1_NS
kubectl --context $REGION1_CONTEXT delete service keycloak -n $REGION1_NS
kubectl --context $REGION1_CONTEXT delete configmap keycloak-configmap -n $REGION1_NS

# Phase 3: Delete operator and secrets
helm --kube-context $REGION1_CONTEXT uninstall confluent-operator -n $REGION1_NS
helm --kube-context $REGION2_CONTEXT uninstall confluent-operator -n $REGION2_NS

for secret in confluent-registry tls-kraftcontroller tls-kafka credential mds-token oauth-jass; do
  kubectl --context $REGION1_CONTEXT delete secret $secret -n $REGION1_NS 2>/dev/null || true
  kubectl --context $REGION2_CONTEXT delete secret $secret -n $REGION2_NS 2>/dev/null || true
done

kubectl --context $REGION1_CONTEXT delete configmap kraft-admin-config -n $REGION1_NS
kubectl --context $REGION2_CONTEXT delete configmap kraft-admin-config -n $REGION2_NS

# Phase 4: Delete namespaces
kubectl --context $REGION1_CONTEXT delete namespace $REGION1_NS
kubectl --context $REGION2_CONTEXT delete namespace $REGION2_NS

# Phase 5: Clean up generated certificates
rm -rf $TUTORIAL_HOME/.generated-certs
```
