# Client Switchover with Blue/Green Gateway Deployment

This example demonstrates client switchover using gateway via Blue/Green deployment with:
- **Deployment Mode**: Blue/Green with atomic switchover
- **Replication**: Confluent Cluster Linking
- **Authentication Mode**: SASL/PLAIN passthrough
- **Routing Strategy**: Port-based routing
- **Client TLS**: None (PLAINTEXT)
- **Cluster TLS**: None (PLAINTEXT)
- **External Access**: LoadBalancer

## Overview

This scenario demonstrates how to migrate from one Kafka cluster to another using:
1. **Confluent Cluster Linking** to replicate topics from source to destination cluster
2. **Blue/Green Gateway deployments** for atomic traffic switching
3. **Mirror topic promotion** to make destination topics writable

The Blue/Green deployment strategy is the **RECOMMENDED** approach for production environments as it provides:
- Atomic cutover (all clients switch simultaneously)
- Instant rollback capability
- Minimal producer downtime
- Predictable consumer behavior (controlled duplicate processing window)

## Architecture

```
Before Migration:
                Load Balancer
                [selector: blue]
                     │
      ┌──────────────┴──────────────┐
      ▼                             ▼
┌──────────┐                  ┌──────────┐
│ Blue     │                  │ Green    │
│ Gateway  │                  │ Gateway  │
│ (Active) │                  │ (Standby)│
└────┬─────┘                  └──────────┘
     │
     ▼
┌─────────────────┐         ┌─────────────────┐
│ Cluster A       │         │ Cluster B       │
│ (Source)        │─────────│ (Destination)   │
│ - orders        │ Cluster │ - orders(mirror)│
│ - users         │ Linking │ - users(mirror) │
└─────────────────┘         └─────────────────┘

After Migration:
                Load Balancer
                [selector: green]
                     │
      ┌──────────────┴──────────────┐
      ▼                             ▼
┌──────────┐                  ┌──────────┐
│ Blue     │                  │ Green    │
│ Gateway  │                  │ Gateway  │
│ (Standby)│                  │ (Active) │
└──────────┘                  └────┬─────┘
                                   │
                                   ▼
┌─────────────────┐         ┌─────────────────┐
│ Cluster A       │         │ Cluster B       │
│ (Source)        │         │ (Destination)   │
│ - orders        │         │ - orders        │
│ - users         │         │ - users         │
└─────────────────┘         └─────────────────┘
```

## Prerequisites

- Please ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites) for using the examples in this repo.
- Two Confluent Kafka clusters deployed (source and destination) with SASL/PLAIN listeners configured.
- Confluent Cluster Linking configured between clusters.

## Deploy the Example

### Step 1: Deploy the Confluent for Kubernetes Operator

- Add the Confluent Helm repository
```
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
```
- Create the `confluent` namespace in the Kubernetes cluster
```
kubectl create namespace confluent
```
- Install the CFK operator
```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes -n confluent
```
- Check that the `confluent-operator` pod comes up and is running:
```
kubectl get pods -n confluent
```

### Step 2: Create source test topic.
-  Create source client configuration file (`client-src.properties`). Modify the `sasl.jaas.config` section with appropriate credentials.
```
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
  username="kafka" \
  password="kafka-secret";
```
- Create test topic in source cluster. Replace the source bootstrap server in the below command appropriately.
```
kafka-topics.sh --create --topic test-topic --bootstrap-server <src-bootstrap-server>  --command-config client-src.properties
```

### Step 3: Configure Cluster Linking from source to destination

Step 1: Create Configuration Files for Cluster Linking
bash# Create source cluster configuration
sudo docker exec broker2 bash -c 'cat > /tmp/source-cluster.config << "EOF"
bootstrap.servers=ec2-44-251-10-93.us-west-2.compute.amazonaws.com:9093
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret";
EOF'

# Create destination cluster admin configuration
sudo docker exec broker2 bash -c 'cat > /tmp/destination-admin.config << "EOF"
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret";
EOF'

Step 2: Create the Cluster Link
bash# Create cluster link on the destination cluster (broker2)
sudo docker exec broker2 kafka-cluster-links \
--bootstrap-server localhost:9193 \
--command-config /tmp/destination-admin.config \
--create \
--link source-to-destination-link \
--config-file /tmp/source-cluster.config

Step 3: List and Verify Cluster Links
bash# List all cluster links on destination
sudo docker exec broker2 kafka-cluster-links \
--bootstrap-server localhost:9193 \
--command-config /tmp/destination-admin.config \
--list

# Describe the cluster link
sudo docker exec broker2 kafka-cluster-links \
--bootstrap-server localhost:9193 \
--command-config /tmp/destination-admin.config \
--describe \
--link source-to-destination-link

Step 4: Create Mirror Topics
# Create mirror topic using kafka-mirrors command
sudo docker exec broker2 kafka-mirrors \
--bootstrap-server localhost:9193 \
--command-config /tmp/destination-admin.config \
--create \
--mirror-topic sushi \
--link source-to-destination-link

Step 5: Verify Mirror Topic Creation
# List topics on destination to see the mirror topic
sudo docker exec broker2 kafka-topics \
--bootstrap-server localhost:9193 \
--command-config /tmp/destination-admin.config \
--list

# Describe the mirror topic
sudo docker exec broker2 kafka-topics \
--bootstrap-server localhost:9193 \
--command-config /tmp/destination-admin.config \
--describe \
--topic sushi

Step 6: Test the Cluster Link
# Produce messages to source cluster
echo "Testing cluster link message 1" | sudo docker exec -i broker kafka-console-producer \
--bootstrap-server localhost:9093 \
--producer-property security.protocol=SASL_PLAINTEXT \
--producer-property sasl.mechanism=PLAIN \
--producer-property 'sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="alice-secret";' \
--topic sushi

echo "Testing cluster link message 2" | sudo docker exec -i broker kafka-console-producer \
--bootstrap-server localhost:9093 \
--producer-property security.protocol=SASL_PLAINTEXT \
--producer-property sasl.mechanism=PLAIN \
--producer-property 'sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="alice-secret";' \
--topic sushi

# Wait for replication
sleep 3

# Consume from destination cluster mirror topic
sudo docker exec broker2 kafka-console-consumer \
--bootstrap-server localhost:9193 \
--consumer-property security.protocol=SASL_PLAINTEXT \
--consumer-property sasl.mechanism=PLAIN \
--consumer-property 'sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="alice-secret";' \
--topic sushi \
--from-beginning \
--max-messages 2

Step 7: Monitor Cluster Link Status
# Check cluster link status and metrics
# Describe the cluster link without --include-tasks
sudo docker exec broker2 kafka-cluster-links \
--bootstrap-server localhost:9193 \
--command-config /tmp/destination-admin.config \
--describe \
--link source-to-destination-link

Step 5: Get Cluster Link Metrics
bash# Check the state of the link
sudo docker exec broker2 kafka-configs \
--bootstrap-server localhost:9193 \
--command-config /tmp/destination-admin.config \
--describe \
--entity-type cluster-links \
--entity-name source-to-destination-link

### Step 5: Deploy Blue Gateway (Initially Active)

Create the Blue Gateway deployment:

```bash
cat > gateway-blue.yaml <<EOF
apiVersion: gateway.conduktor.io/v1
kind: Gateway
metadata:
  name: confluent-gateway-blue
  namespace: confluent
  labels:
    app: confluent-gateway
    version: blue
spec:
  replicas: 3
  image: conduktor/conduktor-gateway:3.0.0
  config:
    mode: GATEWAY_SECURITY
    hostName: gateway.example.com
  streamingDomains:
    - name: main
      config:
        bootstrap.servers: kafka-source:9092
        security.protocol: SASL_PLAINTEXT
        sasl.mechanism: PLAIN
        sasl.jaas.config: |
          org.apache.kafka.common.security.plain.PlainLoginModule required
          username="kafka"
          password="kafka-secret";
  authentication:
    type: passthrough
  externalAccess:
    type: loadBalancer
    loadBalancer:
      domain: gateway.example.com
      port: 9092
EOF

kubectl apply -f gateway-blue.yaml -n confluent
```

### Step 6: Deploy Green Gateway (Initially Standby)

Create the Green Gateway deployment (initially pointing to source):

```bash
cat > gateway-green.yaml <<EOF
apiVersion: gateway.conduktor.io/v1
kind: Gateway
metadata:
  name: confluent-gateway-green
  namespace: confluent
  labels:
    app: confluent-gateway
    version: green
spec:
  replicas: 3
  image: conduktor/conduktor-gateway:3.0.0
  config:
    mode: GATEWAY_SECURITY
    hostName: gateway.example.com
  streamingDomains:
    - name: main
      config:
        bootstrap.servers: kafka-source:9092
        security.protocol: SASL_PLAINTEXT
        sasl.mechanism: PLAIN
        sasl.jaas.config: |
          org.apache.kafka.common.security.plain.PlainLoginModule required
          username="kafka"
          password="kafka-secret";
  authentication:
    type: passthrough
  externalAccess:
    type: loadBalancer
    loadBalancer:
      domain: gateway-green.example.com
      port: 9092
EOF

kubectl apply -f gateway-green.yaml -n confluent
```

### Step 7: Create LoadBalancer Service with Selector

Create a LoadBalancer service that can switch between Blue and Green:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: confluent-gateway-lb
  namespace: confluent
spec:
  type: LoadBalancer
  selector:
    app: confluent-gateway
    version: blue  # Initially pointing to Blue
  ports:
    - name: kafka
      port: 9092
      targetPort: 9092
    - name: kafka-ssl
      port: 9093
      targetPort: 9093
EOF
```

### Step 8: Create Mirror Topics

Mirror your production topics to the destination cluster:

```bash
# Create mirror topics
kafka-mirrors --create \
  --source-cluster kafka-source:9092 \
  --destination-cluster kafka-destination:9092 \
  --topics orders,payments,inventory,users \
  --link source-to-destination-link
```

## Migration Procedure: Blue/Green Deployment

### Phase 1: Pre-Flight Checks

1. **Verify Cluster Link Status**
```bash
# Check replication lag (should be < 100 messages)
kafka-cluster-links --describe \
  --link source-to-destination-link \
  --bootstrap-server kafka-destination:9092

# Expected: LAG < 100 messages per partition
```

2. **Check Offset Sync Status**
```bash
# Compare consumer group offsets between clusters
kafka-consumer-groups --describe --all-groups \
  --bootstrap-server kafka-source:9092 > /tmp/offsets-source.txt

kafka-consumer-groups --describe --all-groups \
  --bootstrap-server kafka-destination:9092 > /tmp/offsets-destination.txt

# Compare offsets
diff /tmp/offsets-source.txt /tmp/offsets-destination.txt
```

3. **Document Current State**
```bash
# Capture pre-cutover snapshot
CUTOVER_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Cutover initiated: $CUTOVER_TIME"

# Save current state
kubectl get pods -n confluent -o wide > /tmp/pre-cutover-pods.txt
kubectl get svc -n confluent > /tmp/pre-cutover-services.txt
```

### Phase 2: Prepare Green Environment

1. **Update Green Gateway to Point to Destination**
```bash
# Edit the Green Gateway configuration
kubectl edit gateway confluent-gateway-green -n confluent

# Update the streamingDomains section:
# Change: bootstrap.servers: kafka-source:9092
# To:     bootstrap.servers: kafka-destination:9092
```

2. **Restart Green Gateway Pods**
```bash
# Trigger a rollout restart
kubectl rollout restart deployment/confluent-gateway-green -n confluent

# Wait for rollout to complete
kubectl rollout status deployment/confluent-gateway-green -n confluent --timeout=5m

# Verify all Green pods are running
kubectl get pods -l app=confluent-gateway,version=green -n confluent
```

### Phase 3: Promote Mirror Topics

```bash
# Promote mirrors to make them writable
kafka-mirrors --promote \
  --topics orders,payments,inventory,users \
  --bootstrap-server kafka-destination:9092

# Verify promotion
for topic in orders payments inventory users; do
  echo "Testing $topic..."
  echo "test-message" | kafka-console-producer \
    --bootstrap-server kafka-destination:9092 \
    --topic $topic 2>&1 | grep -i "error" || echo "  ✓ Writable"
done
```

### Phase 4: Atomic Traffic Cutover

```bash
# Switch LoadBalancer selector from Blue to Green
kubectl patch service confluent-gateway-lb -n confluent -p \
  '{"spec":{"selector":{"version":"green","app":"confluent-gateway"}}}'

# Verify service endpoints
kubectl get endpoints confluent-gateway-lb -n confluent
# Should show Green pod IPs

# Monitor client reconnections
kubectl logs -f deployment/confluent-gateway-green -n confluent | grep "connection"
```

### Phase 5: Monitor and Validate

1. **Verify Producer Health**
```bash
# Check for producer errors
kubectl logs deployment/confluent-gateway-green -n confluent | \
  grep -E "ProducerFencedException|InvalidProducerEpochException" | \
  wc -l
# Should spike initially then drop to 0
```

2. **Verify Consumer Health**
```bash
# Check consumer lag
kafka-consumer-groups --describe --all-groups \
  --bootstrap-server kafka-destination:9092

# Monitor for duplicate processing (expected for 30-60 seconds)
kubectl logs deployment/your-application -n confluent | \
  grep "duplicate" | tail -20
```

3. **Application Metrics**
```bash
# Monitor application metrics
curl http://gateway-metrics:9090/metrics | grep -E "producer|consumer|error"
```

### Phase 6: Cleanup (After Stability Confirmed)

After 24-48 hours of stable operation:

```bash
# Scale down Blue deployment
kubectl scale deployment/confluent-gateway-blue -n confluent --replicas=0

# Keep Blue configuration for emergency rollback capability
# Do not delete the Blue deployment immediately
```

## Rollback Procedure (If Issues Detected)

If issues are detected during or after migration:

```bash
# Immediately switch traffic back to Blue
kubectl patch service confluent-gateway-lb -n confluent -p \
  '{"spec":{"selector":{"version":"blue","app":"confluent-gateway"}}}'

# Scale up Blue if it was scaled down
kubectl scale deployment/confluent-gateway-blue -n confluent --replicas=3

# Verify Blue pods are serving traffic
kubectl get endpoints confluent-gateway-lb -n confluent
# Should show Blue pod IPs
```

## Testing the Configuration

### Test Client Configuration

Create a client configuration file (`client.properties`):

```properties
bootstrap.servers=gateway.example.com:9092
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
  username="kafka" \
  password="kafka-secret";
```

### Test Producer

```bash
# Produce test messages
kafka-console-producer \
  --bootstrap-server gateway.example.com:9092 \
  --producer.config client.properties \
  --topic orders
```

### Test Consumer

```bash
# Consume messages
kafka-console-consumer \
  --bootstrap-server gateway.example.com:9092 \
  --consumer.config client.properties \
  --topic orders \
  --from-beginning
```

### Test Transactional Producer

```bash
# Create a transactional producer test
cat > test-transaction.sh <<'EOF'
#!/bin/bash
kafka-transactions \
  --bootstrap-server gateway.example.com:9092 \
  --command-config client.properties \
  --execute "
    begin
    send --topic orders --key k1 --value v1
    send --topic payments --key k2 --value v2
    commit
  "
EOF

chmod +x test-transaction.sh
./test-transaction.sh
```

## Client Impact Summary

| Client Type | During Migration | After Promotion | Recovery Time |
|-------------|------------------|-----------------|---------------|
| **Transactional Producer** | 🔴 Blocked | ✅ Auto-recovery | ~1-5s |
| **Idempotent Producer** | 🔴 Blocked | ⚠️ Lost idempotency | ~1-5s |
| **Regular Producer** | 🔴 Blocked | ✅ Works | ~1s |
| **Consumer Group** | ✅ Works | 🟡 Duplicates (30-60s) | Immediate |
| **Kafka Streams** | 🔴 Blocked | ✅ Auto-recovery | ~5-10s |
| **Connect Source** | 🔴 Blocked | ✅ Auto-recovery | ~1-5s |

## Key Considerations

### Why Blue/Green is Recommended

1. **Atomic Cutover**: All clients switch simultaneously
2. **Instant Rollback**: Can revert to Blue immediately if issues arise
3. **Predictable Behavior**: No gradual degradation like rolling restart
4. **Minimal Downtime**: ~30 seconds for producers
5. **Testing Capability**: Can validate Green before switching

### Important Notes

- **Mirror Topic Promotion is One-Way**: Once promoted, topics cannot be demoted back to mirrors
- **Consumer Offset Sync Lag**: Expect 30-60 seconds of duplicate processing
- **Transactional Guarantees**: Wait for `transaction.max.timeout.ms` before promotion to avoid zombie transactions
- **Idempotency**: Producer IDs are not preserved across clusters
- **Share Groups**: Not compatible with cluster migrations (state is not synced)

## Monitoring and Alerting

Set up monitoring for:

1. **Replication Lag**: Alert if lag > 1000 messages
2. **Consumer Lag**: Alert if lag increases unexpectedly
3. **Producer Errors**: Alert on sustained `TopicAuthorizationException`
4. **Connection Metrics**: Monitor client reconnection rates
5. **Application Errors**: Monitor application-specific error rates

## Clean Up

To remove all resources created by this example:

```bash
# Delete Gateways
kubectl delete -f gateway-blue.yaml -n confluent
kubectl delete -f gateway-green.yaml -n confluent

# Delete LoadBalancer service
kubectl delete service confluent-gateway-lb -n confluent

# Delete Cluster Link
kubectl delete clusterlink source-to-destination-link -n confluent

# Delete Kafka clusters (if created for this example)
kubectl delete kafka kafka-source kafka-destination -n confluent

# Delete namespace (if dedicated for this example)
# kubectl delete namespace confluent
```

## Troubleshooting

### Common Issues and Solutions

1. **Producers Getting TopicAuthorizationException**
   - Cause: Mirror topics are still read-only
   - Solution: Ensure mirrors are promoted before switching traffic

2. **High Consumer Duplicate Rate**
   - Cause: Normal behavior due to offset sync lag
   - Solution: Wait 30-60 seconds for offset sync to catch up

3. **Transactional Producer Failures**
   - Cause: Transaction coordinator change
   - Solution: Producers will auto-recover with retry logic

4. **Consumer Group Rebalancing**
   - Cause: Normal behavior during cluster switch
   - Solution: Ensure `session.timeout.ms` is configured appropriately

## Further Reading

- [Confluent Cluster Linking Documentation](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/)
- [Disaster Recovery with Cluster Linking](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/disaster-recovery.html)
- [Gateway Migration Best Practices](https://docs.confluent.io/platform/current/gateway/migration.html)
- [Kafka Migration Strategies](https://docs.confluent.io/platform/current/multi-dc-deployments/cluster-linking/migrate-cp.html)
