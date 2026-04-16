## Monitor USM Agent with Prometheus

This example demonstrates how to set up Prometheus monitoring for USM Agent using a PodMonitor.

### Pre-requisite

- Deploy Confluent For Kubernetes (CFK) Operator
- Deploy USM Agent using any of the auth examples ([basic_auth](../basic_auth), [tls](../tls), [mtls](../mtls))
- [Prometheus Operator](https://github.com/prometheus-operator/prometheus-operator) installed in the cluster (for PodMonitor support)

```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/usmagent/monitoring
```

### Create Prometheus credentials secret

The monitoring endpoint (port 9910) uses the **same authentication** as the dataplane listener.
When basic auth is configured on the USMAgent, Prometheus must provide credentials to scrape metrics.

```
kubectl create secret generic usm-prometheus-creds \
  --from-literal=username=<usm-agent-basic-auth-username> \
  --from-literal=password=<usm-agent-basic-auth-password> \
  -n confluent
```

The username and password must match the USM Agent basic auth credentials (the same credentials configured in the USMAgent CR under `spec.authentication.basic.secretRef`).

> **Note:** If USMAgent is deployed in plaintext mode (no authentication), you can skip this step and remove the `basicAuth` section from the PodMonitor.

### Deploy PodMonitor

```
kubectl apply -f $TUTORIAL_HOME/podmonitor.yaml
```

### Verify metrics are accessible

Port-forward to the monitoring port:

```
USM_POD=$(kubectl get pods -n confluent -l app=usm-agent -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward $USM_POD 9910:9910 -n confluent &
```

Without auth (should return 401 when basic auth is enabled):

```
curl -s http://localhost:9910/stats/prometheus
# Output: User authentication failed. Missing username and password.
```

With auth (should return Prometheus metrics):

```
curl -s -u "<username>:<password>" http://localhost:9910/stats/prometheus | head -10
```

### Key Metrics

| Metric | Description |
|--------|-------------|
| `envoy_cluster_upstream_rq{envoy_response_code="200"}` | Healthy telemetry flow to Confluent Cloud |
| `envoy_cluster_upstream_rq{envoy_response_code="400"}` | Cluster not yet registered in Confluent Cloud (expected before registration) |
| `envoy_cluster_upstream_rq{envoy_response_code="401"}` | Authentication failure — check CCloud or CP credentials |
| `envoy_cluster_upstream_rq{envoy_response_code="503"}` | Connectivity issue to Confluent Cloud — check PrivateLink or network config |

### Recommended Grafana Dashboard

USM Agent uses Envoy internally. Import the [Envoy Proxy Monitoring dashboard (ID: 23239)](https://grafana.com/grafana/dashboards/23239-envoy-proxy-monitoring/) for a pre-built visualization.

### Important Notes

- **Authentication required:** The monitoring port mirrors the dataplane authentication. When basic auth is configured on the USMAgent, Prometheus must provide the same credentials.
- **PodMonitor required:** Port 9910 binds to localhost inside the pod. Use a PodMonitor (not ServiceMonitor) since the port is not exposed via a Kubernetes Service.
- **Plaintext mode:** When USMAgent has no authentication configured, Prometheus can scrape without credentials — remove the `basicAuth` section from the PodMonitor.
