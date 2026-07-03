## Dynamic Quorum - Secured with LDAP RBAC

Deploy a KRaft cluster with dynamic quorum (KIP-853), TLS encryption, SASL/PLAIN authentication, and Confluent RBAC with LDAP as the MDS identity provider. Single Kubernetes cluster deployment.

### Security Configuration

| Layer | Setting |
|-------|---------|
| TLS | Auto-generated |
| Authentication | SASL/PLAIN |
| Authorization (RBAC) | Kafka only (KRaft has no RBAC in this example) |
| MDS Provider | LDAP |
| MRC | No (single cluster) |

### Architecture

```
Namespace: confluent

OpenLDAP (ldap:389)
  - Users: admin, kafka, kafka_client
  - Readonly bind user: mds
        |
        | LDAP lookups
        v
KRaftController (3 replicas)
  - TLS enabled
  - SASL/PLAIN authentication
  - Dynamic quorum (KIP-853)
  - Bootstrap pod: kraftcontroller-0
        |
        | Metadata
        v
Kafka (3 brokers)
  - TLS enabled
  - SASL/PLAIN authentication
  - Confluent RBAC authorization
  - MDS with LDAP provider
        |
        | REST API
        v
KafkaRestClass + ConfluentRolebindings
  - Operator uses RBAC for Day-2 operations
```

### Prerequisites

- Kubernetes cluster with `kubectl` configured
- Confluent for Kubernetes (CFK) 3.2+ operator deployed
- CP 7.9+ images (CP 8.2+ recommended for auto-join)
- Valid Confluent Enterprise license (RBAC requires Enterprise)
- `openssl` CLI available
- `helm` CLI available

### Set the Tutorial Home

```bash
export TUTORIAL_HOME=<Tutorial directory>/kraft/dynamic-quorum/greenfield/secured
```


### Step 1: Create the namespace

```bash
kubectl create namespace confluent
```

### Step 2: Install the CFK operator

```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --namespace confluent
```

### Step 3: Create the credential secret

This secret contains SASL/PLAIN credentials for Kafka and the LDAP bind credentials for MDS.

```bash
kubectl create secret generic credential \
  --namespace confluent \
  --from-literal=plain.txt="username=kafka_client
password=kafka_client-secret" \
  --from-literal=plain-users.json='{
  "kafka": "kafka-secret",
  "kafka_client": "kafka_client-secret",
  "admin": "admin-secret"
}' \
  --from-literal=plain-interbroker.txt="username=kafka
password=kafka-secret" \
  --from-literal=ldap-server-simple.txt="username=cn=mds,dc=test,dc=com
password=Developer!" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 4: Generate the MDS token keypair

MDS uses an RSA keypair to sign and verify bearer tokens.

```bash
openssl genrsa -out /tmp/mds-tokenkeypair.pem 2048
openssl rsa -in /tmp/mds-tokenkeypair.pem -outform PEM -pubout -out /tmp/mds-public.pem

kubectl create secret generic mds-token \
  --namespace confluent \
  --from-file=mdsPublicKey.pem=/tmp/mds-public.pem \
  --from-file=mdsTokenKeyPair.pem=/tmp/mds-tokenkeypair.pem \
  --dry-run=client -o yaml | kubectl apply -f -

rm -f /tmp/mds-tokenkeypair.pem /tmp/mds-public.pem
```

### Step 5: Create ERP and REST credential secrets

These secrets provide credentials for Kafka's Embedded REST Proxy and KafkaRestClass.

```bash
kubectl create secret generic mds-client-erp \
  --namespace confluent \
  --from-literal=bearer.txt="username=kafka
password=kafka-secret" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic rest-credential \
  --namespace confluent \
  --from-literal=bearer.txt="username=admin
password=admin-secret" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 6: Apply RBAC and bootstrap ConfigMap

The bootstrap ConfigMap tracks whether kraftcontroller-0 has formatted storage with `--standalone`. The RBAC gives the KRaftController ServiceAccount permission to update it.

```bash
kubectl apply -f $TUTORIAL_HOME/resources/rbac.yaml
kubectl apply -f $TUTORIAL_HOME/resources/bootstrap-configmap.yaml
```

### Step 7: Create the admin CLI config ConfigMap

This ConfigMap is mounted on KRaft pods at `/mnt/admin-config` and provides security properties for admin CLI tools like `kafka-metadata-quorum` and `kafka-features`.

```bash
cat > /tmp/security.properties <<'EOF'
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="kafka" password="kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
ssl.truststore.type=PKCS12
EOF

kubectl create configmap kraft-admin-config \
  --from-file=security.properties=/tmp/security.properties \
  -n confluent

rm -f /tmp/security.properties
```

### Step 8: Deploy OpenLDAP

LDAP must be running before Kafka starts because MDS connects to LDAP during Kafka startup.

```bash
kubectl apply -f $TUTORIAL_HOME/resources/openldap.yaml
```

Wait for OpenLDAP to be ready:

```bash
kubectl wait --for=condition=ready pod/ldap-0 -n confluent --timeout=120s
```

### Step 9: Deploy KRaftController

```bash
kubectl apply -f $TUTORIAL_HOME/resources/kraftcontroller.yaml
```

Wait for controllers to be ready:

```bash
kubectl wait --for=condition=ready pod -l app=kraftcontroller -n confluent --timeout=300s
```

### Step 10: Deploy Kafka with LDAP RBAC

```bash
kubectl apply -f $TUTORIAL_HOME/resources/kafka.yaml
```

Wait for Kafka to be ready:

```bash
kubectl wait --for=condition=ready pod -l app=kafka -n confluent --timeout=600s
```

### Step 11: Deploy KafkaRestClass and Confluent Rolebindings

```bash
kubectl apply -f $TUTORIAL_HOME/resources/kafkarestclass.yaml
kubectl apply -f $TUTORIAL_HOME/resources/rolebindings.yaml
```

### Validate

Check deployment status:

```bash
kubectl get kraftcontroller,kafka,kafkarestclass,confluentrolebinding -n confluent
kubectl get pods -n confluent
```

Verify LDAP users:

```bash
kubectl exec ldap-0 -n confluent -- ldapsearch \
  -x -H ldap://localhost:389 \
  -b dc=test,dc=com \
  -D 'cn=mds,dc=test,dc=com' -w Developer! \
  '(objectClass=organizationalRole)' cn
```

Check dynamic quorum status (with TLS + SASL credentials):

```bash
kubectl exec kraftcontroller-0 -n confluent -- sh -c '
JKS_PASS=$(grep jksPassword /mnt/sslcerts/jksPassword.txt | cut -d= -f2)
USERNAME=$(grep "^username" /mnt/secrets/kraftcontroller-controller-listener-apikeys/plain.txt | cut -d= -f2)
PASSWORD=$(grep "^password" /mnt/secrets/kraftcontroller-controller-listener-apikeys/plain.txt | cut -d= -f2)
cat > /tmp/ctrl.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${USERNAME}" password="${PASSWORD}";
ssl.truststore.location=/mnt/sslcerts/truststore.jks
ssl.truststore.password=${JKS_PASS}
EOF
kafka-metadata-quorum --bootstrap-controller localhost:9074 \
  --command-config /tmp/ctrl.properties describe --status
'
```

Check replication status (all controllers should show low lag):

```bash
kubectl exec kraftcontroller-0 -n confluent -- bash -c '
JKS_PASS=$(cat /mnt/sslcerts/jksPassword.txt)
USERNAME=$(grep "^username" /mnt/secrets/kraftcontroller-controller-listener-apikeys/plain.txt | cut -d= -f2)
PASSWORD=$(grep "^password" /mnt/secrets/kraftcontroller-controller-listener-apikeys/plain.txt | cut -d= -f2)
cat > /tmp/ctrl.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${USERNAME}" password="${PASSWORD}";
ssl.truststore.location=/mnt/sslcerts/truststore.jks
ssl.truststore.password=${JKS_PASS}
EOF
kafka-metadata-quorum --bootstrap-controller localhost:9074 \
  --command-config /tmp/ctrl.properties describe --replication
'
```

Check `kraft.version` is 1:

```bash
kubectl exec kraftcontroller-0 -n confluent -- kafka-features \
  --bootstrap-controller localhost:9074 describe | grep kraft.version
```

Check RBAC bindings:

```bash
kubectl get confluentrolebinding -n confluent
```

### Users and Credentials

| Username | Password | LDAP DN | Roles | Purpose |
|----------|----------|---------|-------|---------|
| `kafka` | `kafka-secret` | `cn=kafka,dc=test,dc=com` | SystemAdmin | Inter-broker, inter-controller |
| `admin` | `admin-secret` | `cn=admin,dc=test,dc=com` | SystemAdmin | Admin operations |
| `kafka_client` | `kafka_client-secret` | `cn=kafka_client,dc=test,dc=com` | DeveloperWrite | Client produce/consume |
| `mds` | `Developer!` | `cn=mds,dc=test,dc=com` | -- | LDAP bind user for MDS (not for Kafka auth) |

### Tear Down

```bash
kubectl delete -f $TUTORIAL_HOME/resources/ -n confluent
kubectl delete secret credential mds-token mds-client-erp rest-credential -n confluent
kubectl delete configmap kraft-admin-config -n confluent
kubectl delete namespace confluent
```

### Troubleshooting

**Kafka CLI tools: OutOfMemoryError**: The default heap for CLI tools is 256MB. Increase it:

```bash
KAFKA_HEAP_OPTS="-Xmx512m" kafka-metadata-quorum ...
```

**Pods not starting**: Check operator logs and pod events:

```bash
kubectl logs -n confluent deploy/confluent-operator --tail=50
kubectl describe pod kraftcontroller-0 -n confluent
```

**LDAP / MDS issues**: Verify LDAP is reachable from Kafka pod:

```bash
kubectl exec kafka-0 -n confluent -- bash -c \
  "ldapsearch -x -H ldap://ldap.confluent.svc.cluster.local:389 \
   -b dc=test,dc=com -D 'cn=mds,dc=test,dc=com' -w Developer! '(cn=kafka)'"
```

**Dynamic quorum issues**: Check bootstrap ConfigMap status:

```bash
kubectl get cm kraftcontroller-dynamic-quorum -n confluent -o yaml
```
