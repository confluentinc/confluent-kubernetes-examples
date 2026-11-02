# Client Switchover with Blue/Green Gateway Deployment

This example demonstrates client switchover using Gateway via Blue/Green deployment with:
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
- Easy rollback capability.
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

#### 1. Deploy Blue Gateway [Initially ACTIVE]
- Modify the `streamingDomains` section in the [gateway-blue.yaml](./gateway-blue.yaml)  to point to your Kafka cluster SASL/PLAIN listener.
```
kubectl apply -f gateway-blue.yaml -n confluent
```
- Wait for the gateway pods to become READY
```
kubectl wait --for=condition=Ready pod -l app=confluent-gateway-blue --timeout=600s -n confluent
```

#### 2. Deploy Green Gateway [Initially STANDBY]
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

### Step 3: Create Kafka cluster configuration files.

1. Create source cluster configuration: `source-cluster.config`.
- Modify the `sasl.jaas.config` section with appropriate credentials and the `bootstrap.servers` section with the appropriate endpoint.
```
bootstrap.servers=kafka-source:9093
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="src-admin" password="src-admin-secret";
```

2. Create destination cluster configuration: `destination-cluster.config`.
- Modify the `sasl.jaas.config` section with appropriate credentials.
```
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="dest-admin" password="dest-admin-secret";
```

3. Create client configuration: `client.properties`.
- Modify the `sasl.jaas.config` section with appropriate credentials.
```
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="usr1" password="usr1-secret";
```

### Step 4: Test Initial Gateway setup [Loadbalancer pointing to Blue deployment]

1. Test producing messages:
```
kafka-console-producer \
  --bootstrap-server gateway.example.com:9595 \
  --producer.config client.properties \
  --topic gateway-client-switchover-test
```
2. Test consuming messages:
```
kafka-console-consumer \
  --bootstrap-server gateway.example.com:9595 \
  --consumer.config client.properties \
  --topic gateway-client-switchover-test \
  --from-beginning
```

### Step 5: Configure Cluster Linking from source to destination Kafka cluster.
**NOTE: Please modify the `bootstrap-server` config appropriately for all commands in this section.**

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
**NOTE: Please modify the `bootstrap-server` config appropriately for all commands in this section.**

#### 1. Create Test Topic on Source Kafka Cluster
```
bash kafka-topics.sh --create --topic gateway-client-switchover-test --bootstrap-server kafka-source:9093  --command-config source-cluster.config
```

#### 2. Create Mirror Topic on Destination Kafka Cluster
**NOTE: Please ensure that the mirror-topic has the same name as the original source topic.**

```
kafka-mirrors \
  --bootstrap-server kafka-destination:9193 \
  --command-config destination-cluster.config \
  --create \
  --mirror-topic gateway-client-switchover-test \
  --link source-to-destination-link
```

#### 3. Test the Cluster Link
- Produce messages to source cluster. 
```
echo "Testing cluster link message 1" | kafka-console-producer \
  --bootstrap-server kafka-source:9093 \
  --producer.config client.properties \
  --topic gateway-client-switchover-test

echo "Testing cluster link message 2" | kafka-console-producer \
  --bootstrap-server kafka-source:9093 \
  --producer.config client.properties \
  --topic gateway-client-switchover-test
```

- Consume from destination cluster mirror topic
```
kafka-console-consumer \
  --bootstrap-server kafka-destination:9193 \
  --consumer.config client.properties \
  --topic gateway-client-switchover-test \
  --from-beginning \
  --max-messages 2
```

## Migration Procedure: Switch to Green Deployment
**NOTE: Please modify the `bootstrap-server` config appropriately for all commands in this section.**

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
kafka-topics --list --bootstrap-server kafka-source:9093  --command-config source-cluster.config | sort > /tmp/source-topics.txt

# Get mirrored topics in the destination.
kafka-mirrors \
  --bootstrap-server kafka-destination:9193 \
  --command-config destination-cluster.config \
  --list \
  --link source-to-destination-link | sort > /tmp/destination-topics.txt

# Validate that any difference is expected (test or internal topics only).
diff /tmp/source-topics.txt /tmp/destination-topics.txt
```

**IMPORTANT: Run Steps 2, 3 and 4 in this exact order. Any other order can lose data. See [Data Safety During Cutover](#data-safety-during-cutover).**

**Before you start the cutover (Steps 2, 3 and 4):**
- Finish Steps 3 and 4 within 60 seconds of Step 2 completing. With default settings, some producers start failing records with a timeout error after 60 seconds. Those records are lost unless the application resends them. Check your clients' timeout settings.
- Prepare the commands for Steps 3 and 4 with your topic names and endpoints, so you can run them without delay.
- Until Step 3, you can safely abort by scaling the Blue Gateway back up.

### Step 2: Stop writes to the source cluster

Patching the loadbalancer only routes **new** connections to Green. Clients that are already connected stay on Blue and keep writing to the source cluster. This includes ClusterIP Services. Scale the Blue Gateway to 0 to close every client connection to the source cluster.

#### 1. Scale the Blue Gateway to 0 replicas
**NOTE: Scale the `Gateway` resource, not its Deployment. CFK reverts direct changes to the Deployment.**
```
kubectl scale gateway confluent-gateway-blue -n confluent --replicas=0
```

#### 2. Wait until the Blue pods are gone
- Blue keeps accepting client connections, existing and new, until its pods are deleted. Do not start Step 3 before this command succeeds.
```
kubectl wait --for=delete pod -l app=confluent-gateway-blue -n confluent --timeout=60s
```
- Clients now get connection errors and retry until they reach Green.
- Optionally, wait a few seconds before Step 3 so records already written to the source cluster finish replicating.

### Step 3: Promote Mirror Topics

#### 1. Promote mirrors to make them writable
- Modify below command to include required topic names.
- Use `--promote`, not `--failover`. `--promote` fails if a mirror topic has lag, and does a final sync of consumer group offsets and topic configs. `--failover` skips these checks and converts the topic immediately.
- If `--promote` fails because of lag, wait a few seconds and run it again.
```bash
kafka-mirrors --promote \
  --topics gateway-client-switchover-test \
  --bootstrap-server kafka-destination:9193 \
  --command-config destination-cluster.config
```

#### 2. Wait for promotion to complete
- Describe the promoted topics. Modify below command to include required topic names.
```bash
kafka-mirrors --describe \
  --topics gateway-client-switchover-test \
  --bootstrap-server kafka-destination:9193 \
  --command-config destination-cluster.config
```
- Proceed to Step 4 only when every topic shows `State: STOPPED`.
  - `PENDING_STOPPED`: promotion is still running. Wait and check again.
  - `ACTIVE`: the promotion was rejected. Run Step 3 again.

### Step 4: Traffic cutover to Green cluster

#### 1. Patch loadbalancer to point to the Green deployment
- Patch the loadbalancer to change the label selector to the Green deployment.
```
kubectl patch service confluent-gateway-switchover-lb -n confluent --type='json' -p='[
  {"op": "replace", "path": "/spec/selector/app", "value": "confluent-gateway-green"}]'
```

#### 2. Test message consumption from new Gateway setup [Loadbalancer pointing to Green deployment]
- You should be able to consume the test messages that were produced in `gateway-client-switchover-test` as part of the Cluster Linking verification step.
```
kafka-console-consumer \
  --bootstrap-server gateway.example.com:9595 \
  --consumer.config client.properties \
  --topic gateway-client-switchover-test \
  --from-beginning
```

#### 3. Verify promotion by producing messages
```
kafka-console-producer \
  --bootstrap-server gateway.example.com:9595 \
  --producer.config client.properties \
  --topic gateway-client-switchover-test
```

### Step 5: Monitor and Validate
- Monitor for 15-30 minutes. Watch for:
  - Producer reinitialization (ProducerFencedException should spike then stabilize).
  - Consumer duplicate processing (should spike then decrease).
  - Application error rates.

### Step 6: Retain Blue for rollback
- Blue is already scaled to 0 from Step 2. Keep the Blue Gateway resource for 24-48 hours in case of rollback.

## Data Safety During Cutover

`kafka-mirrors --promote` fails if a mirror topic has lag, but producers can still write to the source topic after that check succeeds. The order of Steps 2, 3 and 4 closes the two ways data can be lost:

| Order | What happens |
|---|---|
| Patch the loadbalancer, then promote, with Blue still running | Connected clients keep writing to the source cluster. Records written after promotion are never mirrored. Clients see no errors. |
| Stop Blue, patch the loadbalancer, then promote | Clients reconnect to Green while the topics are still read-only mirrors. Writes fail with `InvalidRequestException: Cannot append records to read-only mirror topic`. Producers do not retry this error, so these records are dropped. |
| Stop Blue, promote, then patch the loadbalancer (Steps 2, 3, 4) | Clients get connection errors until the loadbalancer points to Green, then their retries succeed. No records are lost if clients reach Green within 60 seconds of Step 2 completing. |

## Key Considerations

### Why Blue/Green Approach is Recommended

- **Atomic Cutover**: All clients switch simultaneously.
- **Clean Rollback**: Can revert to Blue if issues arise.
- **Predictable Behavior**: No gradual degradation like rolling restart.
- **Minimal Downtime**: ~30 seconds for producers.
- **Testing Capability**: Can validate Green setup before switching.

### Important Notes

- **Mirror Topic Promotion is One-Way**: Once promoted, topic at source and destination are no longer linked and hence writable at both places.
- **Consumer Offset Sync Lag**: Expect 30-60 seconds of duplicate processing.
- **Transactional Guarantees**: Wait for `transaction.max.timeout.ms` before promotion to avoid zombie transactions.
- **Idempotency**: Producer IDs are not preserved across clusters.
- **Share Groups**: Not compatible with cluster migrations (state is not synced).

## Monitoring and Alerting

Set up monitoring for:

- **Replication Lag**
- **Consumer Lag**: Monitor for lag increasing unexpectedly.
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
kubectl delete service confluent-gateway-switchover-lb -n confluent
```

## Troubleshooting

### Common Issues and Solutions

1. **Producers Getting `InvalidRequestException: Cannot append records to read-only mirror topic`**
   - Cause: Traffic was switched to Green before the mirror topics were promoted
   - Solution: Promote mirrors before switching traffic (Step 3 before Step 4). Records that failed with this error are not retried and must be resent by the application

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
- [Disaster Recovery with Cluster Linking](https://docs.confluent.io/cloud/current/multi-cloud/cluster-linking/dr-failover.html)
