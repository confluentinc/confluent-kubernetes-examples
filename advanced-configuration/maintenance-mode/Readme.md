# Confluent Platform Maintenance Mode

This feature allows you to put specific pods into maintenance mode, preventing them from starting their main processes while keeping them available for manual maintenance operations. This is particularly useful for performing maintenance tasks like configuration updates, log analysis, or troubleshooting without affecting the entire cluster.

# Feature Introduction Version
- Introduced in CFK 3.1 or higher
- Init container should be updated 3.1 or higher
- It is also available in following patch versions 3.0.1, 2.11.3, 2.10.3

## Overview

The maintenance mode feature works by:

1. **Annotation-based Configuration**: Pods are marked for maintenance using Kubernetes annotations on the Custom Resource (CR)
2. **Init Container Check**: The init container checks for maintenance mode configuration before starting the main application
3. **Graceful Pause**: Pods in maintenance mode pause indefinitely, allowing for manual intervention
4. **Signal Handling**: Pods respond to SIGTERM signals for clean termination

## Architecture

### Components Involved

- **Custom Resources**: All Confluent Platform components (Kafka, SchemaRegistry, KsqlDB, Connect, ControlCenter, KafkaRestProxy, Zookeeper, KRaftController, USMAgent)
- **Init Container**: Checks maintenance mode configuration and pauses if needed
- **Configuration Generation**: Maintenance mode settings are generated and mounted as configuration files

### Configuration Flow

```
CR Annotation → Operator → ConfigMap → Init Container → Pod Behavior
```

1. User adds annotation to CR: `platform.confluent.io/maintenance-mode=pod1,pod2` where pod1, pod2 are the pod names to be put into maintenance mode
2. Operator generates maintenance mode configuration
3. Configuration is mounted to init container at `/mnt/config/init/maintenance_mode.config`
4. Init container checks if current pod is in maintenance mode
5. If in maintenance mode, pod pauses; otherwise, normal startup continues

## Quick Start

### 1. Deploy Confluent Platform

Choose one of the provided manifests based on your architecture:

#### For KRaft-based Deployment (Recommended)
```bash
kubectl apply -f manifests/confluent_platform.yaml
```

#### For Zookeeper-based Deployment
```bash
kubectl apply -f manifests/confluent_platform_zk.yaml
```

### 2. Put Pods into Maintenance Mode

To put specific pods into maintenance mode, add the `platform.confluent.io/maintenance-mode` annotation to the Custom Resource:

```bash
# Example: Put SchemaRegistry pods 1 and 2 into maintenance mode
kubectl -n confluent annotate schemaregistry schemaregistry \
  platform.confluent.io/maintenance-mode=schemaregistry-1,schemaregistry-2 \
  --overwrite
  
# wait for a few seconds to let the operator generate the configuration

# Delete the pods to trigger the maintenance mode behavior
kubectl delete pod schemaregistry-1 schemaregistry-2 -n confluent
```

### 3. Perform Maintenance

Once pods are in maintenance mode, you can:

```bash
# Execute commands in the paused pod
kubectl exec -it schemaregistry-1 -n confluent -- /bin/bash

# Edit configuration files
kubectl exec -it schemaregistry-1 -n confluent

```

### 4. Exit Maintenance Mode

To return pods to normal operation:

```bash
# Remove the maintenance mode annotation
kubectl -n confluent annotate schemaregistry schemaregistry \
  platform.confluent.io/maintenance-mode- \
  --overwrite

# Delete the pods to restart them normally
kubectl delete pod schemaregistry-1 schemaregistry-2 -n confluent
```

## Detailed Usage Examples

### Kafka Pods

```bash
# Put Kafka broker 0 into maintenance mode
kubectl -n confluent annotate kafka kafka \
  platform.confluent.io/maintenance-mode=kafka-0 \
  --overwrite

kubectl delete pod kafka-0 -n confluent

# Perform maintenance
kubectl exec -it kafka-0 -n confluent -- /bin/bash

# Exit maintenance mode
kubectl -n confluent annotate kafka kafka \
  platform.confluent.io/maintenance-mode- \
  --overwrite

kubectl delete pod kafka-0 -n confluent
```

### Multiple Components

```bash
# Put multiple pods from different components into maintenance mode
kubectl -n confluent annotate kafka kafka \
  platform.confluent.io/maintenance-mode=kafka-0,kafka-1 \
  --overwrite

kubectl -n confluent annotate schemaregistry schemaregistry \
  platform.confluent.io/maintenance-mode=schemaregistry-0 \
  --overwrite

# Delete all affected pods
kubectl delete pod kafka-0 kafka-1 schemaregistry-0 -n confluent
```

### KRaft Controller

```bash
# Put KRaft controller into maintenance mode
kubectl -n confluent annotate kraftcontroller kraftcontroller \
  platform.confluent.io/maintenance-mode=kraftcontroller-0 \
  --overwrite

kubectl delete pod kraftcontroller-0 -n confluent
```

## Configuration Details

### Annotation Format

The maintenance mode annotation follows this format:
```
platform.confluent.io/maintenance-mode=<pod1>,<pod2>,<pod3>
```

Where:
- `<pod1>`, `<pod2>`, etc. are the exact pod names (e.g., `kafka-0`, `schemaregistry-1`)
- Multiple pods are comma-separated
- Pod names must match the actual pod names in the cluster

### Generated Configuration

The operator generates a JSON configuration file at `/mnt/config/init/maintenance_mode.config`:

```json
{
  "kafka-0": {
    "mode": "MAINTENANCE"
  },
  "kafka-1": {
    "mode": "MAINTENANCE"
  }
}
```

### Init Container Behavior

When a pod starts:

1. **Check Configuration**: Looks for `/mnt/config/init/maintenance_mode.config`
2. **Parse JSON**: Uses `jq` to check if current pod is in the maintenance list
3. **Decision**:
   - If pod is in maintenance mode → Pause indefinitely with graceful signal handling
   - If pod is not in maintenance mode → Continue with normal startup

## Signal Handling

Pods in maintenance mode handle signals gracefully:

- **SIGTERM**: Clean termination (e.g., `kubectl delete pod`)
- **SIGINT**: Clean termination (e.g., Ctrl+C)
- **Other signals**: Ignored to maintain maintenance state

## Log Examples

### Pod in Maintenance Mode

When a pod is put into maintenance mode, the init container logs will show:

```bash
kafka-1 › config-init-container
kafka-1 config-init-container + '[' -f /mnt/config/init/template.jsonnet ']'
kafka-1 config-init-container + /opt/startup.sh
kafka-1 config-init-container + '[' -z kafka-1 ']'
kafka-1 config-init-container + checkMaintenanceMode
kafka-1 config-init-container + local maintenance_config=/mnt/config/init/maintenance_mode.config
kafka-1 config-init-container + '[' -f /mnt/config/init/maintenance_mode.config ']'
kafka-1 config-init-container + echo '===> Checking maintenance mode configuration...'
kafka-1 config-init-container ===> Checking maintenance mode configuration...
kafka-1 config-init-container + jq -e --arg pod_name kafka-1 'has($pod_name)' /mnt/config/init/maintenance_mode.config
kafka-1 config-init-container + local mode
kafka-1 config-init-container ++ jq -r --arg pod_name kafka-1 '.[$pod_name].mode' /mnt/config/init/maintenance_mode.config
kafka-1 config-init-container ===> Pod kafka-1 is in MAINTENANCE mode. Pausing gracefully to allow for manual repair.
kafka-1 config-init-container ===> Send SIGTERM (e.g., 'kubectl delete pod') to exit.
kafka-1 config-init-container + mode=MAINTENANCE
kafka-1 config-init-container + '[' MAINTENANCE = MAINTENANCE ']'
kafka-1 config-init-container + echo '===> Pod kafka-1 is in MAINTENANCE mode. Pausing gracefully to allow for manual repair.'
kafka-1 config-init-container + echo '===> Send SIGTERM (e.g., '\''kubectl delete pod'\'') to exit.'
kafka-1 config-init-container + trap handle_exit SIGTERM SIGINT
kafka-1 config-init-container + SLEEP_PID=9
kafka-1 config-init-container + wait 9
kafka-1 config-init-container + sleep infinity
```

**Key indicators of maintenance mode:**
- `===> Checking maintenance mode configuration...`
- `===> Pod kafka-1 is in MAINTENANCE mode. Pausing gracefully to allow for manual repair.`
- `===> Send SIGTERM (e.g., 'kubectl delete pod') to exit.`
- `sleep infinity` - The pod will remain in this state until manually terminated

### Pod Not in Maintenance Mode

When a pod is not in maintenance mode, the init container logs will show:

```bash
kafka-1 › config-init-container
kafka-1 config-init-container + '[' -f /mnt/config/init/template.jsonnet ']'
kafka-1 config-init-container + /opt/startup.sh
kafka-1 config-init-container + '[' -z kafka-1 ']'
kafka-1 config-init-container + checkMaintenanceMode
kafka-1 config-init-container + local maintenance_config=/mnt/config/init/maintenance_mode.config
kafka-1 config-init-container + '[' -f /mnt/config/init/maintenance_mode.config ']'
kafka-1 config-init-container + echo '===> Checking maintenance mode configuration...'
kafka-1 config-init-container + jq -e --arg pod_name kafka-1 'has($pod_name)' /mnt/config/init/maintenance_mode.config
kafka-1 config-init-container ===> Checking maintenance mode configuration...
kafka-1 config-init-container + echo '===> Pod is not in maintenance mode. Proceeding with normal startup.'
kafka-1 config-init-container + POD_AGNOSTIC_COMPONENTS=("usm-agent" "gateway")
kafka-1 config-init-container ===> Pod is not in maintenance mode. Proceeding with normal startup.
```

**Key indicators of normal startup:**
- `===> Checking maintenance mode configuration...`
- `===> Pod is not in maintenance mode. Proceeding with normal startup.`
- The init container continues with the normal startup process

## Troubleshooting

### Pod Stuck in Maintenance Mode

If a pod appears stuck in maintenance mode:

```bash
# Check the maintenance mode configuration
kubectl exec -it <pod-name> -n confluent -- cat /mnt/config/init/maintenance_mode.config

# Check pod logs
kubectl logs <pod-name> -n confluent

# Force delete the pod (if needed)
kubectl delete pod <pod-name> -n confluent --force --grace-period=0
```

### Verify Maintenance Mode Status

```bash
# Check if annotation exists
kubectl get <component> <name> -n confluent -o jsonpath='{.metadata.annotations.platform\.confluent\.io/maintenance-mode}'

# List all pods in maintenance mode
kubectl get pods -n confluent -o json | jq -r '.items[] | select(.metadata.annotations."platform.confluent.io/maintenance-mode") | .metadata.name'
```

### Common Issues

1. **Pod Name Mismatch**: Ensure the pod names in the annotation match the actual pod names
2 **Configuration Not Generated**: Verify the operator is running and the CR annotation is correct. 
    Check operator logs, it corresponding ConfigMap (-init-config) is not updated

## Best Practices

1. **Gradual Maintenance**: Put pods into maintenance mode one at a time to maintain service availability
2. **Backup Configuration**: Always backup configuration files before making changes
3. **Test Changes**: Test configuration changes in a non-production environment first
4. **Monitor Impact**: Monitor cluster health during maintenance operations
5. **Clean Exit**: Always remove maintenance mode annotations when done

## Supported Components

The maintenance mode feature is supported for all Confluent Platform components:

- ✅ **Kafka** (both Zookeeper and KRaft modes)
- ✅ **SchemaRegistry**
- ✅ **KsqlDB**
- ✅ **Connect**
- ✅ **ControlCenter**
- ✅ **KafkaRestProxy**
- ✅ **Zookeeper**
- ✅ **KRaftController**
- ✅ **USMAgent**
- ✅ **Gateway**

## Security Considerations

- Maintenance mode pods remain accessible for manual intervention
- Ensure proper RBAC permissions for maintenance operations
- Log all maintenance activities for audit purposes
- Avoid exposing maintenance mode pods to untrusted networks
- Use secure methods (e.g., `kubectl exec` over TLS) for accessing pods
- Avoid putting multiple pods into maintenance mode simultaneously in production environments, as this may lead to service disruption
- Prefer using maintenance mode during off-peak hours to minimize impact

## Limitations

- Pods in maintenance mode consume cluster resources but don't serve traffic
- Only affects the specific pods listed in the annotation
- Requires manual intervention (delete pod) to enter & exit maintenance mode
- When pods are in maintenance mode, cluster roll operation is blocked until all pods exit maintenance mode
