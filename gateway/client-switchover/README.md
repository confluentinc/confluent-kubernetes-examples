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

This example demonstrates migration from one Kafka cluster to another using:
- **Confluent Cluster Linking**: To replicate topics from source to destination cluster.
- **Blue/Green Gateway deployment**: For atomic traffic cutover.
- **Mirror topic promotion**: To make destination topics writable.

The Blue/Green deployment strategy is the **RECOMMENDED** approach for production environments as it provides:
- Atomic cutover (all clients switch simultaneously).
- Instant rollback capability.
- Minimal producer downtime.
- Predictable consumer behavior (controlled duplicate processing window).

## Architecture

```
Before Migration:
                                Load Balancer
                               [selector: blue]
                                      │
                  ┌───────────────────┴───────────────────┐
                  ▼                                       ▼
            ┌──────────┐                            ┌──────────┐
            │  Blue    │                            │ Green    │
            │ Gateway  │                            │ Gateway  │
            │ (Active) │                            │ (Standby)│
            └────┬─────┘                            └─────┬────┘
                 │                                        │
                 ▼                                        ▼
        ┌─────────────────┐                     ┌───────────────────┐
        │    Source       │   Cluster Linking   │    Destination    │
        │   Cluster       │ ───────────────────▶│      Cluster      │
        │  - orders       │                     │ - orders(mirror)  │
        │  - users        │                     │ - users(mirror)   │
        └─────────────────┘                     └───────────────────┘

```
```
After Migration:
                                Load Balancer
                               [selector: green]
                                      │
                  ┌───────────────────┴───────────────────┐
                  ▼                                       ▼
            ┌──────────┐                            ┌──────────┐
            │   Blue   │                            │  Green   │
            │ Gateway  │                            │ Gateway  │
            │(Standby) │                            │ (Active) │
            └────┬─────┘                            └─────┬────┘
                 │                                        │
                 ▼                                        ▼
        ┌─────────────────┐                     ┌─────────────────────┐
        │    Source       │                     │    Destination      │
        │   Cluster       │                     │      Cluster        │
        │  - orders       │                     │ - orders(promoted)  │
        │  - users        │                     │ - users(promoted)   │
        └─────────────────┘                     └─────────────────────┘

```

## Prerequisites

- Please ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites) for using the examples in this repo.
- Two Confluent Kafka clusters deployed (source and destination) with SASL/PLAIN listeners configured.
- Confluent Cluster Linking configured between clusters.

## Deploy the Example

### Step 1: Deploy the Confluent for Kubernetes Operator

1. Add the Confluent Helm repository
```
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
```
2. Create the `confluent` namespace in the Kubernetes cluster
```
kubectl create namespace confluent
```
3. Install the CFK operator
```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes -n confluent
```
4. Check that the `confluent-operator` pod comes up and is running:
```
kubectl get pods -n confluent
```
### Step 2: Deploy Gateway instances and Loadbalancer Service

#### 1. Deploy Blue Gateway [Initially active]
- Modify the `streamingDomains` section in the [gateway-blue.yaml](./gateway-blue.yaml)  to point to your Kafka cluster SASL/PLAIN listener.
```
kubectl apply -f gateway-blue.yaml -n confluent
```
- Wait for the gateway pods to become READY
```
kubectl wait --for=condition=Ready pod -l app=confluent-gateway-blue --timeout=600s -n confluent
```

#### 2. Deploy Green Gateway [Initially standby]
- Modify the `streamingDomains` section in the [gateway-green.yaml](./gateway-green.yaml)  to point to your Kafka cluster SASL/PLAIN listener.
```
kubectl apply -f gateway-green.yaml -n confluent
```
- Wait for the gateway pods to become READY
```
kubectl wait --for=condition=Ready pod -l app=confluent-gateway-green --timeout=600s -n confluent
```
#### 3. Deploy Loadbalancer Service [Initially pointing to Blue deployment]
- Modify the port mappings in `spec.ports` corresponding to your source and destination Kafka node id ranges.
```
kubectl apply -f loadbalancer-service.yaml -n confluent
```

- Map the following DNS name to the created loadbalancer: `gateway.example.com`.
```
NOTE:
For the rest of this document, we will be using `gateway.example.com` as the loadbalancer domain name.
Please replace this appropriately if the configured domain name is different or if you would prefer to use the loadbalancer IP address instead.
Also, please change the Kafka bootstrap listener port corresponding to this endpoint appropriately, based on the applied loadbalancer service yaml.
```

### Step 3: Create source and destination Kafka cluster configuration files.

1. Create source cluster configuration: `source-cluster.config`.
- Modify the `sasl.jaas.config` section with appropriate credentials and the `bootstrap.servers` section with the appropriate endpoint.
```
bootstrap.servers=kafka-source:9093
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret";
```

2. Create destination cluster configuration: `destination-cluster.config`.
- Modify the `sasl.jaas.config` section with appropriate credentials.
```
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret";
```

### Step 4: Test Initial Gateway setup [Loadbalancer pointing to Blue deployment]

1. Test producing messages:
```
kafka-console-producer \
  --bootstrap-server gateway.example.com:9595 \
  --producer.config source-cluster.config \
  --topic gateway-blue-test
```
2. Test consuming messages:
```
kafka-console-consumer \
  --bootstrap-server gateway.example.com:9595 \
  --consumer.config source-cluster.config \
  --topic gateway-blue-test \
  --from-beginning
```

### Step 5: Configure Cluster Linking from source to destination Kafka cluster.
#### NOTE: Please modify the `bootstrap-server` config appropriately for all commands in this section.

#### 1. Create the Cluster Link on the destination cluster
```
kafka-cluster-links \
  --bootstrap-server kafka-destination:9193 \
  --command-config destination-cluster.config \
  --create \
  --link source-to-destination-link \
  --config-file source-cluster.config
```

#### 2. List and Verify Cluster Links.
- List all cluster links on destination.
```
kafka-cluster-links \
  --bootstrap-server kafka-destination:9193 \
  --command-config destination-cluster.config \
  --list
```

- Describe the cluster link. 
```
kafka-cluster-links \
  --bootstrap-server kafka-destination:9193 \
  --command-config destination-cluster.config \
  --describe \
  --link source-to-destination-link
```

### Step 6: Test Cluster linking setup
#### NOTE: Please modify the `bootstrap-server` config appropriately for all commands in this section.

#### 1. Create Test Topic on Source Kafka Cluster
```
bash kafka-topics.sh --create --topic test-topic --bootstrap-server kafka-source:9093  --command-config source-cluster.config
```

#### 2. Create Mirror Topic on Destination Kafka Cluster
```
kafka-mirrors \
  --bootstrap-server kafka-destination:9193 \
  --command-config destination-cluster.config \
  --create \
  --mirror-topic test-topic \
  --link source-to-destination-link
```

#### 3. Test the Cluster Link
- Produce messages to source cluster. 
```
echo "Testing cluster link message 1" | kafka-console-producer \
  --bootstrap-server kafka-source:9093 \
  -- producer.config client-src.properties
  --topic test-topic

echo "Testing cluster link message 2" | kafka-console-producer \
  --bootstrap-server kafka-source:9093 \
  --producer.config client-src.properties
  --topic test-topic
```

- Consume from destination cluster mirror topic
```
kafka-console-consumer \
  --bootstrap-server kafka-destination:9193 \
  --consumer.config destination-cluster.config \
  --topic test-topic \
  --from-beginning \
  --max-messages 2
```

## Migration Procedure: Blue/Green Deployment
#### NOTE: Please modify the `bootstrap-server` config appropriately for all commands in this section.

### Step 1: Pre-Flight Checks

#### 1. Verify Cluster Link Status
- Verify that replication lag is less than 100 messages per partition.
```
kafka-cluster-links \
  --bootstrap-server kafka-destination:9193 \
  --command-config destination-cluster.config \
  --describe \
  --link source-to-destination-link
```

#### 2. Check Offset Sync Status
- Compare consumer group offsets between clusters. Validate that the offset difference corresponds to 30-60 seconds of messages.
```bash
# Get source offsets.
kafka-consumer-groups --describe --all-groups \
  --bootstrap-server kafka-source:9093 \
  --command-config source-cluster.config > /tmp/source-offsets.txt

# Get destination offsets.
kafka-consumer-groups --describe --all-groups \
  --bootstrap-server kafka-destination:9193 \
  --command-config destination-cluster.config > /tmp/destination-offsets.txt
  
# Validate the difference.
diff /tmp/source-offsets.txt /tmp/destination-offsets.txt
```

#### 3. Verify all topics are mirrored
```bash
# Get source kafka topics.
kafka-topics--list --bootstrap-server kafka-source:9093  --command-config source-cluster.config | sort > /tmp/source-topics.txt

# Get mirrored topics in the destination.
kafka-mirrors \
  --bootstrap-server kafka-destination:9193 \
  --command-config destination-cluster.config \
  --list \
  --link source-to-destination-link | sort > /tmp/destination-topics.txt

# Validate that any difference is expected (test or internal topics only).
diff /tmp/source-topics.txt /tmp/destination-topics.txt
```

### Step 2: Traffic cutover to the Green cluster

#### 1. Patch loadbalancer to point to Green deployment
- Patch the loadbalancer to change the label selectors as well as the `targetPort` for the Kafka bootstrap listener.
- Modify the `targetPort` in the below patch command to point to the port of the Green gateway route endpoint.
```
kubectl patch service confluent-gateway-switchover-lb -n confluent --type='json' -p='[
  {"op": "replace", "path": "/spec/selector/app", "value": "confluent-gateway-green"},
  {"op": "replace", "path": "/spec/ports/0/targetPort", "value": 9696}
]'
```

####  2. Test message consumption from new Gateway setup [Loadbalancer pointing to Green deployment]
```
kafka-console-consumer \
  --bootstrap-server gateway.example.com:9595 \
  --consumer.config destination-cluster.config \
  --topic test-topic \
  --from-beginning
```

### Step 3: Promote Mirror Topics
#### NOTE: Please modify the `bootstrap-server` config appropriately for all commands in this section.

- Promote mirrors to make them writable. Modify below command to include required topic names
```bash
kafka-mirrors --promote \
  --topics test-topic \
  --bootstrap-server kafka-destination:9193 \
  --command-config destination-cluster.config
```

- Verify promotion by producing messages:
```
kafka-console-producer \
  --bootstrap-server gateway.example.com:9595 \
  --producer.config destination-cluster.config \
  --topic test-topic
```

### Step 4: Monitor and Validate
- Monitor for 15-30 minutes. Watch for:
  - Producer reinitialization (ProducerFencedException should spike then stabilize)
  - Consumer duplicate processing (should spike then decrease)
  - Application error rates

### Step 5: Scale down Blue deployment

- Scale down Blue deployment to 0 replicas. Goal is to retain for 24-48 hours in case of rollback.
```
kubectl scale deployment confluent-gateway-blue -n confluent --replicas=0
```

## Client Impact Summary

| Client Type                | During Migration | After Promotion        | Recovery Time (after promotion) |
|----------------------------|------------------|------------------------|---------------------------------|
| **Transactional Producer** | 🔴 Blocked | ✅ Auto-recovery        | ~1-5s (reconnect + retry)       |
| **Idempotent Producer**    | 🔴 Blocked | ⚠️ Lost idempotency    | ~1-5s (reinitialise)            |
| **Regular Producer**       | 🔴 Blocked | ✅ Works                | ~1s (reinitialise)              |
| **Consumer Group**         | ✅ Works | 🟡 Duplicates          | Immediate                       |
| **Share Group**            | ✅ Works | 🔴 Complete state loss | N/A - requires mitigation       |
| **Kafka Streams**          | 🔴 Blocked | ✅ Auto-recovery        | ~5-10s (state restore)          |
| **Connect Source**         | 🔴 Blocked | ✅ Auto-recovery        | ~1-5s (task restart)           |

## Key Considerations

### Why Blue/Green is Recommended

- **Atomic Cutover**: All clients switch simultaneously.
- *Instant Rollback**: Can revert to Blue immediately if issues arise.
- **Predictable Behavior**: No gradual degradation like rolling restart.
- **Minimal Downtime**: ~30 seconds for producers.
- **Testing Capability**: Can validate Green before switching.

### Important Notes

- **Mirror Topic Promotion is One-Way**: Once promoted, topics cannot be demoted back to mirrors.
- **Consumer Offset Sync Lag**: Expect 30-60 seconds of duplicate processing.
- **Transactional Guarantees**: Wait for `transaction.max.timeout.ms` before promotion to avoid zombie transactions.
- **Idempotency**: Producer IDs are not preserved across clusters.
- **Share Groups**: Not compatible with cluster migrations (state is not synced).

## Monitoring and Alerting

Set up monitoring for:

- **Replication Lag**
- **Consumer Lag**: Alert if lag increases unexpectedly.
- **Producer and Consumer Errors**
- **Connection Metrics**: Monitor client reconnection rates
- **Application Errors**: Monitor application-specific error rates

## Clean Up

To remove all resources created by this example:

```bash
# Delete Gateways
kubectl delete -f gateway-blue.yaml -n confluent
kubectl delete -f gateway-green.yaml -n confluent

# Delete LoadBalancer service
kubectl delete service confluent-gateway-lb -n confluent
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
