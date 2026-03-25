# CFK Platform Logs to Splunk on Kubernetes

End‑to‑end guide for sending **Confluent for Kubernetes (CFK) platform logs** from **Kubernetes** to **Splunk** using the **Splunk OpenTelemetry Collector for Kubernetes**.

## Table of Contents

- [1. Overview](#1-overview)
- [2. Prerequisites](#2-prerequisites)
- [3. Splunk Setup](#3-splunk-setup)
- [4. Install Splunk OTel Collector on Kubernetes](#4-install-splunk-otel-collector-on-kubernetes)
- [5. Deploy Confluent Platform](#5-deploy-confluent-platform)
- [6. Validation](#6-validation)
- [7. Troubleshooting](#7-troubleshooting)
- [8. Cleanup](#8-cleanup)
- [9. Summary](#9-summary)
- [10. Additional Notes](#10-additional-notes)
- [11. References](#11-references)

---

## 1. Overview

### Goal

Centralize Kafka Connect logs from CFK‑managed clusters into Splunk, with:

- Kubernetes metadata (cluster, namespace, pod, container)
- Optional JSON formatting for easier parsing
- Minimal impact on existing CFK and Kubernetes setup

### Architecture

```text
+-----------+          +----------------------------+          +-------------------+
| CFK      |  logs    | Splunk OTel Collector      |  HEC     | Splunk            |
| Connect  +--------->+ (DaemonSet on every node)  +--------->+ (Cloud/Enterprise)|
| Pods     | stdout   | - Tails container logs     | HTTPS    | - Index: k8s_logs    |
+-----------+          +----------------------------+          +-------------------+
       |                          ^
       |                          |
       v                          |
   Kubernetes / kubelet writes logs to node filesystem
```

---

## 2. Prerequisites

### Platform

- **Kubernetes** cluster
- `kubectl` configured for the Kubernetes cluster
- `helm` v3.9+ installed

### Splunk

- Splunk **Cloud** or **Enterprise**
- A **HEC (HTTP Event Collector) endpoint** reachable from Kubernetes:
  - Example: `https://splunk.example.com:8088/services/collector`
- A **HEC token** for Kubernetes logs (steps provided)
- A **log index** for CFK logs, e.g. `k8s_logs`

### How It Works

- The Splunk OTel Collector is a DaemonSet that runs on every node in the cluster.
- It tails all container logs by default and sends them to Splunk via HEC.
- It uses the `splunkPlatform.endpoint` and `splunkPlatform.token` to authenticate to the Splunk HEC endpoint.
- It uses the `splunkPlatform.index` to route logs to the correct Splunk index.
- Set `splunkPlatform.insecureSkipVerify` to skip certificate verification if the HEC endpoint uses a self-signed certificate.

### Tips

- Consider setting the HEC token or event **sourcetype** to `_json` (or configuring props/transforms) so JSON logs are automatically parsed into fields, while keeping the index (for example `k8s_logs`) unchanged.
- Configure Confluent's CRs to emit JSON logs that are easier to parse in Splunk via Log4j2 configuration overrides.
- A basic Confluent Platform deployment with Connect, Kafka, KsqlDB, and Control Center is available in `confluent-platform.yaml`, with all components configured to emit JSON logs.

## Set the current tutorial directory
Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```bash
export TUTORIAL_HOME=<Tutorial directory>/splunk-Logging-stdout
```

---

## 3. Splunk Setup

You can use either an existing Splunk Cloud/Enterprise deployment or spin up a **free Splunk Cloud Platform trial**.

### 3.1 Create a free Splunk Cloud trial (optional but easy for demos)

1. Go to the **Splunk Cloud Platform trial** page: https://www.splunk.com/en_us/download/splunk-cloud.html
2. Sign up (no credit card required) and create your trial instance (14 days, up to 5 GB/day ingest).
3. **Create index** (if not existing), e.g. `k8s_logs`.
4. When the instance is ready, open **Settings → Data Inputs → HTTP Event Collector (HEC)**.
5. Create a **new HEC token**, note:
   - **Token value** (you'll paste it into `splunkValues.yaml`)
   - **HEC endpoint**, typically `https://<your-instance>.splunkcloud.com:8088/services/collector`
   - **Data type**, typically `_json`

### 3.2 Index and HEC token

For any Splunk deployment (trial or existing):

1. **Create index** (if not existing), e.g. `k8s_logs`.
2. **Create HEC token**:
   - Set default index to `k8s_logs` or rely on index routing later.
   - **Data type**, typically `_json`
3. Note the values for the collector config:
   - **Endpoint**: `https://<hec-host>:8088/services/collector`
   - **Token**: `<hec-token>`

Recommended: one **HEC token per Kubernetes cluster**.

---

## 4. Install Splunk OTel Collector on Kubernetes

### 4.1 Add Helm repo

```bash
helm repo add splunk-otel-collector-chart https://signalfx.github.io/splunk-otel-collector-chart
helm repo update
```

### 4.2 Create a namespace (optional but recommended)

```bash
kubectl create namespace observability
```

### 4.3 Create `splunkValues.yaml`

Copy the template `$TUTORIAL_HOME/splunkValuesTemplate.yaml` to `$TUTORIAL_HOME/splunkValues.yaml` and fill in the placeholder values:

```yaml
# Arbitrary cluster name; surfaces as k8s.cluster.name in Splunk
clusterName: k8s-cfk

# Tell the chart we're on AKS (helps with some defaults)
distribution: aks

splunkPlatform:
  endpoint: "https://Splunk-Endpoint:8088/services/collector"
  token: "Token from Splunk"
  index: "Index from Splunk"
  insecureSkipVerify: true  # Set to true only when testing with self-signed certs; do not use in production

logsCollection:
  containers:
    enabled: true  # collect container stdout/stderr logs
```

| Field | Description |
|-------|-------------|
| `clusterName` | Arbitrary name that appears as `k8s.cluster.name` in Splunk |
| `distribution` | Kubernetes distribution hint (`aks`, `eks`, `gke`, or omit for generic) |
| `splunkPlatform.endpoint` | Full HEC URL from Section 3 |
| `splunkPlatform.token` | HEC token from Section 3 |
| `splunkPlatform.index` | Default Splunk index for logs |
| `splunkPlatform.insecureSkipVerify` | Set `true` only for self-signed certs in non-prod |

### 4.4 Install the chart

```bash
helm -n observability install splunk-otel \
  -f $TUTORIAL_HOME/splunkValues.yaml \
  splunk-otel-collector-chart/splunk-otel-collector
```

This deploys:

- **DaemonSet** agents on every node
- Agents tail **all container logs** by default and send to Splunk via HEC

After the chart is installed, verify the agents are running: [6.1 Check OTel agents](#61-check-otel-agents).

---

## 5. Deploy Confluent Platform

Create a namespace for Confluent Platform and annotate it with the desired Splunk index.

```bash
kubectl create namespace confluent \
  && kubectl annotate namespace confluent splunk.com/index="k8s_logs"
```

Install the Confluent Operator Chart from Confluent's Helm repo.
```bash
helm repo add confluentinc https://packages.confluent.io/helm/charts
helm repo update
helm install confluent-operator confluentinc/confluent-for-kubernetes --namespace confluent
```

Deploy the Confluent Platform using the `$TUTORIAL_HOME/confluent-platform.yaml` file.

```bash
kubectl apply -f $TUTORIAL_HOME/confluent-platform.yaml
```

Notice that the `$TUTORIAL_HOME/confluent-platform.yaml` contains the Log4j2 configuration overrides to emit JSON logs that are easier to parse in Splunk.

```yaml
    log4j2:
      Configuration:
        Appenders:
          Console:
            PatternLayout:
              Pattern: '{"severity":"%level","timestamp":"%d{yyyy-MM-dd''T''HH:mm:ss.SSSXXX}","textPayload":"%encode{%X{connector.context}%message%n%ex{full}}{JSON}","sourceLocation":{"file":"%encode{%F}{JSON}","line":"%L","function":"%encode{%c}{JSON}"},"thread":"%encode{%t}{JSON}"}%n'
            name: stdout
            target: SYSTEM_OUT
```

This will emit logs in the following format:

```json
{"severity":"INFO","timestamp":"2026-03-16T13:46:11.435Z","textPayload":"Registered loader: jdk.internal.loader.ClassLoaders$AppClassLoader@7b98f307\n","sourceLocation":{"file":"PluginScanner.java","line":"80","function":"org.apache.kafka.connect.runtime.isolation.PluginScanner"},"thread":"main"}
```
  
Result:

- All pods in `confluent` namespace have their logs sent to `k8s_logs`.

---

## 6. Validation

### 6.1 Check OTel agents

```bash
kubectl -n observability get pods -l app=splunk-otel-collector
kubectl -n observability logs -l app=splunk-otel-collector | head
```

Verify there are no repeated HEC errors.

### 6.2 Check Connect pods

```bash
kubectl -n confluent get pods -l "platform.confluent.io/type=connect" -o wide
kubectl -n confluent logs <one-connect-pod> | tail
```

Confirm logs are flowing and in the expected format (plain text or JSON).

### 6.3 Verify in Splunk

In Splunk Search:

```spl
index=k8s_logs k8s.cluster.name=k8s-cfk
```

You should see events with fields like:

- `k8s.cluster.name`
- `k8s.namespace.name`
- `k8s.pod.name`
- `k8s.container.name`

To narrow to Confluent Platform:

```spl
index=k8s_logs k8s.namespace.name=confluent
```

To view the logs of a specific pod:

```spl
index=k8s_logs k8s.pod.name=kafka-0
```

To view the logs of a specific container:

```spl
index=k8s_logs k8s.container.name=kafka
```

Viewing as a table:

```spl
index=k8s_logs k8s.pod.name=kafka-0 | table timestamp, severity, "sourceLocation.file", "sourceLocation.line", thread, textPayload
```

Viewing as a time series:

```spl
index=k8s_logs k8s.pod.name=kafka-0 | timechart count by severity
```

---

## 7. Troubleshooting

### No data in Splunk

- Check HEC connectivity:

  ```bash
  kubectl -n observability logs -l app=splunk-otel-collector | grep -i hec
  ```

- Verify:
  - `splunkPlatform.endpoint` URL is correct
  - `splunkPlatform.token` matches HEC token
  - HEC is enabled and accepts connections from Kubernetes IP ranges

### Data in wrong index

- Check pod / namespace annotations:

  ```bash
  kubectl -n confluent get ns confluent -o yaml | grep -i splunk.com
  kubectl -n confluent get pods --show-labels -o yaml | grep -i splunk.com -n
  ```

- Remember:
  - Pod annotation overrides namespace annotation:
    - `splunk.com/index` at pod/workload level wins
    - `splunk.com/include` / `splunk.com/exclude` can also be pod or namespace scoped

### High volume / performance issues

- If OTel agents are CPU constrained, adjust resources in `values.yaml`:

  ```yaml
  agent:
    resources:
      limits:
        cpu: "500m"
        memory: "512Mi"
      requests:
        cpu: "200m"
        memory: "256Mi"
  ```

- Monitor HEC throughput and add more Splunk indexers / tuning if backpressure is observed.

---

## 8. Cleanup

To remove the collector:

```bash
helm -n observability uninstall splunk-otel
kubectl delete namespace observability
```

(Only delete the namespace if it's dedicated to observability and not shared.)

To remove annotations (example):

```bash
kubectl annotate namespace confluent splunk.com/exclude- splunk.com/index-
kubectl annotate deployment connect -n confluent splunk.com/include- splunk.com/index-
```

The `-` suffix removes an annotation key.

To remove the Confluent Platform:

```bash
kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml
helm uninstall confluent-operator --namespace confluent
kubectl delete namespace confluent
```

---

## 9. Summary

You now have:

- CFK‑managed Confluent Platform on Kubernetes emitting logs to stdout
- A Splunk **OpenTelemetry Collector** DaemonSet tailing container logs
- **Index‑aware routing** and include/exclude control via annotations
- Optional JSON logging for better Splunk field extraction

This setup is reusable for other CFK components (Kafka, SR, ksqlDB, etc.) by adjusting namespace and annotations accordingly.
The Confluent Operator Chart is used to deploy the Confluent Platform.

---

## 10. Additional Notes

### Collect logs from all containers in the namespace to flat files

The following command collects logs from all containers in the namespace to flat files in the current directory.

```bash
for pod in $(kubectl -n confluent get pods -o jsonpath='{.items[*].metadata.name}'); do
  kubectl -n confluent logs "$pod" --all-containers > "${pod}.log" 2>&1 \
    && echo "Saved ${pod}.log ($(wc -l < "${pod}.log") lines)"
done
```

You can check the output of the logs (end of file) to verify they are in JSON format.

---

## 11. References

- [Splunk OpenTelemetry Collector for Kubernetes](https://github.com/signalfx/splunk-otel-collector-chart)
- [Confluent for Kubernetes](https://docs.confluent.io/operator/current/overview.html)
