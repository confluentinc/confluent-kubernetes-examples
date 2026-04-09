# MRC Bidirectional Cluster Link (SASL-SSL, LoadBalancer)

True multi-cluster bidirectional cluster linking between two separate GKE clusters
with SASL-SSL security and LoadBalancer external access.

## Architecture

```
  GKE Cluster: <central-cluster> (us-central1)          GKE Cluster: <east-cluster> (us-east4)
  Namespace: central                               Namespace: east
  +------------------------------------------+    +------------------------------------------+
  |                                          |    |                                          |
  |  KRaftController (3 replicas)            |    |  KRaftController (3 replicas)             |
  |  Kafka (3 brokers, SASL-SSL)             |    |  Kafka (3 brokers, SASL-SSL)              |
  |                                          |    |                                          |
  |  central-topic (original)  ------------->|    |  central-topic (mirror)                   |
  |                            ClusterLink   |    |                                          |
  |  east-topic (mirror)   <------------- |    |  east-topic (original)                 |
  |                            ClusterLink   |    |                                          |
  |                                          |    |                                          |
  |  LB: kafka-central.domain:9092           |    |  LB: kafka-east.domain:9092               |
  |  LB: kafka-central-rest.domain:443       |    |  LB: kafka-east-rest.domain:443            |
  +------------------------------------------+    +------------------------------------------+
```

## Security Configuration

| Component | Setting | Details |
|-----------|---------|---------|
| Kafka internal listener | SASL/PLAIN + TLS | `credential` secret (different per cluster) |
| Kafka external listener | SASL/PLAIN + TLS | `credential` secret + LoadBalancer |
| Kafka REST API | Basic auth + TLS | `rest-credential` secret + LoadBalancer |
| KRaft controller | TLS | `tls-kraftcontroller` secret |
| ClusterLink (central) | SASL/PLAIN + TLS | `east-credential` (east's creds on central) |
| ClusterLink (east) | SASL/PLAIN + TLS | `central-credential` (central's creds on east) |
| Remote REST (central) | Basic auth + TLS | `east-rest-credential` (east REST creds) |
| Remote REST (east) | Basic auth + TLS | `central-rest-credential` (central REST creds) |
| Password encoder | Secret | `password-encoder-secret` (required for CL) |

## Prerequisites

1. **Two GKE clusters** with CFK operator installed (`namespaced=false` for cross-cluster):
   - `<central-cluster>` (us-central1) -- context: `<central-cluster-context>`
   - `<east-cluster>` (us-east4) -- context: `<east-cluster-context>`

2. **ExternalDNS** configured on both clusters for domain `my-domain.example.com`

3. **Secrets pre-created** on both clusters:

   On **central** cluster (namespace `central`):
   ```
   tls-kafka                  # fullchain.pem, privkey.pem, cacerts.pem
   tls-kraftcontroller        # fullchain.pem, privkey.pem, cacerts.pem
   ca-pair-sslcerts           # tls.crt, tls.key
   confluent-registry         # Docker registry credentials
   credential                 # plain.txt (central-kafka/<central-kafka-password>), plain-users.json, plain-interbroker.txt
   rest-credential            # basic.txt (central REST creds)
   east-credential            # plain.txt (east-kafka/<east-kafka-password>) -- east's SASL creds
   east-rest-credential       # basic.txt (east REST creds)
   password-encoder-secret    # password-encoder.txt
   ```

   On **east** cluster (namespace `east`):
   ```
   tls-kafka                  # fullchain.pem, privkey.pem, cacerts.pem
   tls-kraftcontroller        # fullchain.pem, privkey.pem, cacerts.pem
   ca-pair-sslcerts           # tls.crt, tls.key
   confluent-registry         # Docker registry credentials
   credential                 # plain.txt (east-kafka/<east-kafka-password>), plain-users.json, plain-interbroker.txt
   rest-credential            # basic.txt (east REST creds)
   central-credential         # plain.txt (central-kafka/<central-kafka-password>) -- central's SASL creds
   central-rest-credential    # basic.txt (central REST creds)
   password-encoder-secret    # password-encoder.txt
   ```

4. **CP version**: `confluentinc/cp-server:7.9.6`, init: `confluentinc/confluent-init-container:3.2.0`

## Quick Start (Interactive)

```bash
./setup.sh
```

The script runs through 7 phases interactively with yes/no prompts.

## Manual Step-by-Step

### Phase 1: Deploy KRaft Controllers

```bash
# Central
kubectl --context <central-cluster-context> \
  apply -f manifests/central-cluster/kraftcontroller.yaml

# East
kubectl --context <east-cluster-context> \
  apply -f manifests/east-cluster/kraftcontroller.yaml

# Wait for ready
kubectl --context <central-cluster-context> \
  wait --for=condition=platform.confluent.io/cluster-ready \
  kraftcontroller/kraftcontroller -n central --timeout=10m

kubectl --context <east-cluster-context> \
  wait --for=condition=platform.confluent.io/cluster-ready \
  kraftcontroller/kraftcontroller -n east --timeout=10m
```

### Phase 2: Deploy Kafka Clusters

```bash
# Central
kubectl --context <central-cluster-context> \
  apply -f manifests/central-cluster/kafka.yaml

# East
kubectl --context <east-cluster-context> \
  apply -f manifests/east-cluster/kafka.yaml

# Wait for ready
kubectl --context <central-cluster-context> \
  wait --for=condition=platform.confluent.io/cluster-ready \
  kafka/kafka -n central --timeout=15m

kubectl --context <east-cluster-context> \
  wait --for=condition=platform.confluent.io/cluster-ready \
  kafka/kafka -n east --timeout=15m
```

### Phase 3: Verify DNS Resolution

Wait for ExternalDNS to sync LoadBalancer IPs:

```bash
dig +short kafka-central.my-domain.example.com
dig +short kafka-east.my-domain.example.com
dig +short kafka-central-rest.my-domain.example.com
dig +short kafka-east-rest.my-domain.example.com
```

### Phase 4: Create KafkaRestClass

```bash
# Central: local + remote REST classes
kubectl --context <central-cluster-context> \
  apply -f manifests/central-cluster/kafkarestclass.yaml
kubectl --context <central-cluster-context> \
  apply -f manifests/central-cluster/east-kafkarestclass.yaml

# East: local + remote REST classes
kubectl --context <east-cluster-context> \
  apply -f manifests/east-cluster/kafkarestclass.yaml
kubectl --context <east-cluster-context> \
  apply -f manifests/east-cluster/central-kafkarestclass.yaml
```

### Phase 5: Create Topics

```bash
# central-topic on central (will be mirrored to east)
kubectl --context <central-cluster-context> \
  apply -f manifests/central-cluster/topics.yaml

# east-topic on east (will be mirrored to central)
kubectl --context <east-cluster-context> \
  apply -f manifests/east-cluster/topics.yaml
```

### Phase 6: Get Cluster IDs and Create ClusterLinks

```bash
# Get cluster IDs
CENTRAL_ID=$(kubectl --context <central-cluster-context> \
  get kafka kafka -n central -o jsonpath='{.status.clusterId}')
EAST_ID=$(kubectl --context <east-cluster-context> \
  get kafka kafka -n east -o jsonpath='{.status.clusterId}')

echo "Central: $CENTRAL_ID"
echo "East: $EAST_ID"

# Patch cluster IDs into ClusterLink manifests
# In manifests/central-cluster/clusterlink.yaml: set clusterID to $EAST_ID
# In manifests/east-cluster/clusterlink.yaml: set clusterID to $CENTRAL_ID

sed -i '' "s/clusterID: .*/clusterID: $EAST_ID/" manifests/central-cluster/clusterlink.yaml
sed -i '' "s/clusterID: .*/clusterID: $CENTRAL_ID/" manifests/east-cluster/clusterlink.yaml

# Apply ClusterLinks
kubectl --context <central-cluster-context> \
  apply -f manifests/central-cluster/clusterlink.yaml
kubectl --context <east-cluster-context> \
  apply -f manifests/east-cluster/clusterlink.yaml
```

### Phase 7: Validate

```bash
./validate.sh
```

Or manually:

```bash
# Check ClusterLink status
kubectl --context <central-cluster-context> \
  get clusterlink -n central
kubectl --context <east-cluster-context> \
  get clusterlink -n east

# Both should show state: CREATED
```

## Script Commands

```bash
./setup.sh              # Run all phases interactively
./setup.sh kraft        # Phase 1 only
./setup.sh kafka        # Phase 2 only
./setup.sh dns          # Phase 3 only
./setup.sh restclass    # Phase 4 only
./setup.sh topics       # Phase 5 only
./setup.sh clusterlink  # Phase 6 only
./setup.sh validate     # Phase 7 only
./setup.sh status       # Show resource status on both clusters

./validate.sh           # Run produce/consume validation
./teardown.sh           # Delete all resources
```

## Key Design Decisions

### Why LoadBalancer for both Kafka and REST?

- **Kafka LB**: Required for cross-cluster ClusterLink bootstrap (brokers in different GKE clusters)
- **REST LB**: Required for cross-cluster ClusterLink management (CFK operator on each cluster
  needs to call the remote cluster's REST API to manage the link)

### Why different credentials per cluster?

Different SASL credentials for central and east clusters ensure authentication is genuinely
tested. If both clusters used the same credentials, a misconfigured ClusterLink might
accidentally work by using local creds against the remote cluster.

### Why separate REST classes for local and remote?

- **Local REST class** (`central-rest`, `east-rest`): Uses `kafkaClusterRef` to reference the
  local Kafka cluster. CFK discovers the REST endpoint automatically.
- **Remote REST class** (`east-rest` on central, `central-rest` on east): Uses explicit
  `endpoint` pointing to the remote cluster's REST LoadBalancer. Required because the operator
  cannot discover resources across GKE clusters.

### ClusterLink link name

Both sides of the bidirectional link use `name: bidirectional-link`. This MUST match for the
bidirectional protocol to work correctly.

## Troubleshooting

### ClusterLink stuck in non-CREATED state

```bash
# Check ClusterLink details
kubectl --context <context> get clusterlink <name> -n <ns> -o yaml

# Check operator logs
kubectl --context <context> logs -n <operator-ns> deploy/confluent-operator -f | grep -i clusterlink
```

### DNS not resolving

```bash
# Check ExternalDNS logs
kubectl --context <context> logs -n <externaldns-ns> deploy/external-dns -f

# Check LoadBalancer service IPs
kubectl --context <context> get svc -n <ns> | grep LoadBalancer
```

### REST API unreachable from remote cluster

```bash
# Test REST endpoint from a pod
kubectl --context <context> exec -n <ns> kafka-0 -- \
  curl -sk https://kafka-east-rest.my-domain.example.com:443/v3/clusters
```

### Authentication failures

Check that cross-cluster credential secrets have the correct username/password:
```bash
# On central, check east-credential
kubectl --context <central-context> get secret east-credential -n central -o jsonpath='{.data.plain\.txt}' | base64 -d

# On east, check central-credential
kubectl --context <east-context> get secret central-credential -n east -o jsonpath='{.data.plain\.txt}' | base64 -d
```
