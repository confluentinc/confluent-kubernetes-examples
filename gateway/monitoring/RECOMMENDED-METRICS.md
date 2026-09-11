# Recommended Gateway Metrics to Monitor

A recommended set of Gateway, Kroxylicious, and JVM metrics to alert on, grouped by intent.

## Errors & stuck connections

| Metric | Description | Alert hint |
|---|---|---|
| `kroxylicious_client_to_proxy_errors_total` | Downstream (client-facing) error rate | `rate(...[5m]) > 0` sustained |
| `kroxylicious_client_to_proxy_connections_total` vs `kroxylicious_proxy_to_server_connections_total` | Growing gap = client connections accepted but upstream (broker) connections failing to establish | Alert on a widening, non-zero gap over 5m |
| `kroxylicious_client_to_proxy_disconnects_total{cause}` | Client disconnect reasons (`client_closed`, `idle_timeout`, `drain_timeout`, ...) | Spike in `drain_timeout` / non-`client_closed` causes |
| `kroxylicious_virtual_cluster_state{state}` | Route lifecycle state (`serving`, `failed`, `draining`, `initializing`, `stopped`) | Alert if `state="failed"` is `1` |

## Request/response completion

| Metric | Description | Alert hint |
|---|---|---|
| `kroxylicious_client_to_proxy_request_total` vs `kroxylicious_proxy_to_client_response_total` / `kroxylicious_server_to_proxy_response_total` | Divergence indicates requests not completing | Alert if the ratio drifts from ~1 over 5m |
| `gateway_schema_validation_requests_total{outcome}` | Schema-validation success/failure per route/topic | Alert on sustained `outcome="failure"` rate |

## Throughput & latency

| Metric | Description | Alert hint |
|---|---|---|
| `kroxylicious_*_request_size_bytes_*` / `kroxylicious_*_response_size_bytes_*` | Traffic volume and payload sizes (client↔proxy, proxy↔server) | Track for capacity planning; no default alert |
| `gateway_authswap_latency_seconds{quantile}` | AuthSwap end-to-end latency (client-side percentiles) | `gateway_authswap_latency_seconds{quantile="0.99"}` above SLO |
| `gateway_authswap_secret_store_latency_seconds{quantile,type}` | Secret-store lookup latency during AuthSwap | `gateway_authswap_secret_store_latency_seconds{quantile="0.99"}` above SLO |
| `gateway_authswap_client_auth_total{result}` / `gateway_authswap_cluster_auth_total{result}` | Auth success/failure rate, client- and cluster-side | Alert on sustained `result="failure"` rate |

> AuthSwap metrics only exist once a route is configured with AuthSwap auth — a passthrough-auth route emits none of the `gateway_authswap_*` series.

## Process health

| Metric | Description | Alert hint |
|---|---|---|
| `jvm_memory_used_bytes` / `jvm_memory_max_bytes` | Heap/non-heap usage vs limit | Alert above ~85% sustained |
| `jvm_gc_pause_seconds` | GC pause time | Alert on rising `rate(..._sum[5m])` |
| `process_cpu_usage` / `system_cpu_usage` | Process vs host CPU utilization | Alert above threshold sustained |
| `process_files_open_files` / `process_files_max_files` | Open file descriptors vs limit (requires `FileDescriptorMetrics` in `admin.jvmMetrics`) | Alert above ~80% of max |
| `kroxylicious_client_to_proxy_active_connections` / `kroxylicious_proxy_to_server_active_connections` | Live connection counts | Track against expected client/broker counts |
| `netty_eventexecutor_tasks_pending` | Pending tasks per Netty event-loop thread | Alert on sustained non-zero — early sign of event-loop saturation |

## Notes

- `gateway_jvm_metrics` is not a real metric name — JVM/process health is exposed as the individual `jvm_*`/`process_*`/`system_*` series above.
