# Control Center Next Gen with an External Prometheus

These examples deploy Control Center Next Gen with your own external Prometheus
instead of the bundled Prometheus and Alertmanager. Kafka brokers and KRaft
controllers push their metrics to the external Prometheus over OTLP, and
Control Center reads the metrics from it.

Requirements:

- Confluent for Kubernetes 3.4 or later
- Control Center Next Gen 2.7.0 or later
- Prometheus 3.0 or later

Alerting is not available with an external Prometheus.

## Examples

1. [`TLS`](tls): TLS without authentication
2. [`Basic+TLS`](basic_tls): Basic authentication over TLS
3. [`mTLS`](mtls): mutual TLS

## Prepare your Prometheus

Before you deploy an example, configure your Prometheus as follows:

- Start Prometheus with `--web.enable-otlp-receiver`.
- Promote the OTLP resource attributes that Control Center uses, and set an
  out-of-order time window:

  ```yaml
  otlp:
    promote_resource_attributes:
      - host.hostname
      - java.version
      - kafka.broker.id
      - kafka.cluster.id
      - kafka.version
      - type
      - kafka.process.roles
      - kafka.process.roles.broker
      - kafka.process.roles.controller
      - kafka.kafka.node.id
      - kafka.broker.rack
  storage:
    tsdb:
      out_of_order_time_window: 10m
  ```

- Load the Control Center recording rules. Copy
  `recording_rules-generated.yml` from `/etc/confluent-control-center/` in the
  Control Center image, and add it to `rule_files`.
- Configure TLS, and Basic authentication or mTLS if you use them, in the file
  that you pass with `--web.config.file`. The server certificate must have a
  Subject Alternative Name that matches the host name in the Prometheus URL.

In the examples, replace `https://prometheus.example.com:9090` with the URL of
your Prometheus.
