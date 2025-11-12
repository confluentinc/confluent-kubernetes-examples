# Monitoring Configuration for Gateway Client Switchover

This file contains key metrics and queries to monitor during the client switchover process.

## Prometheus Metrics

### Producer Metrics
```promql
# Producer errors rate
rate(kafka_producer_record_error_total[5m])

# Producer request latency (p99)
histogram_quantile(0.99, rate(kafka_producer_request_latency_seconds_bucket[5m]))

# Producer connection count
kafka_producer_connections_count

# Producer fence exceptions
rate(kafka_producer_fence_exceptions_total[5m])
```

### Consumer Metrics
```promql
# Consumer lag
kafka_consumer_lag

# Consumer rebalance rate
rate(kafka_consumer_rebalance_total[5m])

# Consumer fetch latency
histogram_quantile(0.99, rate(kafka_consumer_fetch_latency_seconds_bucket[5m]))

# Consumer group members
kafka_consumer_group_members
```

### Gateway Metrics
```promql
# Gateway connection count by version
sum by (version) (kafka_gateway_connections_count)

# Gateway request rate
rate(kafka_gateway_requests_total[5m])

# Gateway error rate
rate(kafka_gateway_errors_total[5m])

# Gateway memory usage
container_memory_usage_bytes{pod=~"confluent-gateway-.*"}
```

### Cluster Link Metrics
```promql
# Replication lag (messages)
kafka_cluster_link_lag_messages

# Mirror topic byte rate
rate(kafka_cluster_link_bytes_total[5m])

# Offset sync lag
kafka_cluster_link_offset_sync_lag_seconds
```

## Grafana Dashboard JSON

```json
{
  "dashboard": {
    "title": "Gateway Client Switchover Monitoring",
    "panels": [
      {
        "title": "Producer Success Rate",
        "targets": [
          {
            "expr": "1 - (rate(kafka_producer_record_error_total[5m]) / rate(kafka_producer_record_send_total[5m]))"
          }
        ],
        "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 }
      },
      {
        "title": "Consumer Lag",
        "targets": [
          {
            "expr": "kafka_consumer_lag"
          }
        ],
        "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 }
      },
      {
        "title": "Gateway Connections by Version",
        "targets": [
          {
            "expr": "sum by (version) (kafka_gateway_connections_count)"
          }
        ],
        "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 }
      },
      {
        "title": "Replication Lag",
        "targets": [
          {
            "expr": "kafka_cluster_link_lag_messages"
          }
        ],
        "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 }
      },
      {
        "title": "Producer Errors",
        "targets": [
          {
            "expr": "rate(kafka_producer_fence_exceptions_total[5m])"
          }
        ],
        "gridPos": { "h": 8, "w": 12, "x": 0, "y": 16 }
      },
      {
        "title": "Consumer Rebalances",
        "targets": [
          {
            "expr": "rate(kafka_consumer_rebalance_total[5m])"
          }
        ],
        "gridPos": { "h": 8, "w": 12, "x": 12, "y": 16 }
      }
    ]
  }
}
```

## Alert Rules

```yaml
groups:
  - name: gateway_switchover_alerts
    interval: 30s
    rules:
      - alert: HighReplicationLag
        expr: kafka_cluster_link_lag_messages > 1000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High replication lag detected"
          description: "Replication lag is {{ $value }} messages"
      
      - alert: ProducerErrorsHigh
        expr: rate(kafka_producer_record_error_total[5m]) > 0.01
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "High producer error rate"
          description: "Producer error rate is {{ $value | humanizePercentage }}"
      
      - alert: ConsumerLagHigh
        expr: kafka_consumer_lag > 10000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High consumer lag"
          description: "Consumer lag is {{ $value }} messages"
      
      - alert: GatewayConnectionDrop
        expr: delta(kafka_gateway_connections_count[1m]) < -10
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Significant gateway connection drop"
          description: "Lost {{ $value }} connections in the last minute"
      
      - alert: MirrorTopicNotPromoted
        expr: kafka_mirror_topic_writable == 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Mirror topic not promoted"
          description: "Topic {{ $labels.topic }} is still read-only"
```

## Key Metrics to Watch During Migration

### Pre-Migration Checklist
- [ ] Replication lag < 100 messages per partition
- [ ] All consumer groups are stable (no rebalancing)
- [ ] Producer error rate < 0.1%
- [ ] All topics are mirrored to destination

### During Migration (First 5 minutes)
- [ ] Producer errors spike then decrease
- [ ] Consumer rebalances complete within 2 minutes
- [ ] Gateway connections transfer from Blue to Green
- [ ] No sustained TopicAuthorizationException

### Post-Migration Validation (5-60 minutes)
- [ ] Producer success rate returns to >99.9%
- [ ] Consumer lag normalizes
- [ ] No persistent producer fence exceptions
- [ ] Application error rates return to baseline

### Long-term Monitoring (1-24 hours)
- [ ] No unexpected consumer group rebalances
- [ ] Stable producer/consumer performance
- [ ] Memory usage within limits
- [ ] No connection leaks

## Log Queries

### Kubernetes Logs
```bash
# Producer errors
kubectl logs -n confluent -l app=confluent-gateway,version=green --tail=100 | grep -E "ERROR.*Producer"

# Consumer rebalances
kubectl logs -n confluent -l app=your-app --tail=100 | grep -i "rebalance"

# Connection issues
kubectl logs -n confluent -l app=confluent-gateway --tail=100 | grep -i "connection.*failed"

# Authorization errors
kubectl logs -n confluent -l app=confluent-gateway --tail=100 | grep "TopicAuthorizationException"
```

### Application Logs
```bash
# Transaction failures
kubectl logs -n confluent deployment/your-app | grep -E "ProducerFencedException|InvalidProducerEpochException"

# Duplicate processing
kubectl logs -n confluent deployment/your-app | grep -i "duplicate"

# Offset commit failures
kubectl logs -n confluent deployment/your-app | grep "CommitFailedException"
```

## Custom Metrics to Implement

Consider implementing these application-level metrics:

```java
// Producer metrics
private final Counter producerSuccessCounter = Counter.builder("app.producer.success")
    .description("Successful producer sends")
    .register(meterRegistry);

private final Counter producerErrorCounter = Counter.builder("app.producer.errors")
    .description("Failed producer sends")
    .tag("error_type", "authorization")
    .register(meterRegistry);

private final Timer producerLatency = Timer.builder("app.producer.latency")
    .description("Producer send latency")
    .register(meterRegistry);

// Consumer metrics
private final Gauge consumerLag = Gauge.builder("app.consumer.lag", () -> getCurrentLag())
    .description("Current consumer lag")
    .register(meterRegistry);

private final Counter duplicateCounter = Counter.builder("app.consumer.duplicates")
    .description("Duplicate messages processed")
    .register(meterRegistry);

// Migration specific
private final Counter switchoverCounter = Counter.builder("app.gateway.switchover")
    .description("Gateway switchover events detected")
    .register(meterRegistry);
```

## Observability Stack Setup

To fully monitor the migration, ensure you have:

1. **Prometheus** - Metric collection
2. **Grafana** - Visualization
3. **AlertManager** - Alert routing
4. **Loki** - Log aggregation (optional)
5. **Jaeger** - Distributed tracing (optional)

Deploy monitoring stack:
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts

# Install Prometheus
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace

# Access Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Default credentials: admin/prom-operator
```
