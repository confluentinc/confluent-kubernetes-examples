# Distributing Pods and Partition Replicas Across Failure Domains

Whether failure domains are AZs (1DC HA) or regions (multi-DC), the goal is the same: **KRaft voter pods and Kafka partition replicas in different failure domains**. Two pieces of plumbing, both built on standard K8s + Kafka mechanisms (CFK is mostly a pass-through):

- [(a) Pod placement](#a-pod-placement) — *where pods land*
- [(b) Rack-aware partition placement](#b-rack-aware-partition-placement) — *where partition replicas land within those pods*

## (a) Pod placement

Standard K8s scheduling. Two situations:

### Within a K8s cluster (1DC multi-AZ)

Use `KRaftController.spec.podTemplate` and `Kafka.spec.podTemplate` with either:

- `topologySpreadConstraints` (`topologyKey: topology.kubernetes.io/zone`, `maxSkew: 1`), or
- `affinity.podAntiAffinity` on the same topology key.

CFK passes these K8s primitives through unchanged.

### Across K8s clusters (multi-DC)

Pods spread by virtue of running in different clusters — no extra config needed for the cross-region spread itself. AZ-level primitives still apply inside each region if you want that too.

## (b) Rack-aware partition placement

A **Kafka feature**, not a K8s scheduling feature. Pod placement is just substrate — Kafka's partition assigner needs each broker's `broker.rack` to actually spread *replicas* across failure domains.

### How to set it

Set `Kafka.spec.rackAssignment.nodeLabels: [<label-key>]`:

- `topology.kubernetes.io/zone` — AZ-level rack
- `topology.kubernetes.io/region` — region-level rack

### How it works under the hood

CFK does **not** read the node label itself in the operator. Instead:

1. CFK's Kafka StatefulSet transformer sets an env var `RACK_NODE_LABELS=<json-array>` on the Kafka init container.
2. It also mounts the broker pod's ServiceAccount token onto the init container.
3. At pod-start time, the init container hits the K8s API using that SA token, reads the configured node label off the broker's scheduling node, and writes `broker.rack=<value>` into `kafka.properties`.

### RBAC requirement

Because the **broker pod** (not the operator) reads node labels at startup, the **Kafka broker's ServiceAccount** needs `get nodes` cluster-level permission.

The CFK godoc for `RackAssignment.NodeLabels` says *"This feature requires CFK to run with the cluster-level access"* — practically that means **grant the broker SA a ClusterRoleBinding to a role with `nodes/get`**. The default CFK Helm chart's `clusterrole.yaml` does NOT include this grant; wire it yourself before deploying a Kafka CR with `rackAssignment`.

### Static-topology alternative

If your broker count and rack mapping never change, you can skip `rackAssignment` entirely and set `KAFKA_BROKER_RACK` directly via `Kafka.spec.podTemplate.envVars`.

## Avoid ordinal rack values

Don't use `0`, `1`, `2`, etc. as `broker.rack` values. If region 1's brokers are racks `0,1` and region 2's are also `0,1`, the partition assigner can't distinguish regions and may put both replicas of a partition in the same one.

The legacy `rackAssignment.availabilityZoneCount` field configures `broker.rack` via the formula `pod_id % azCount`. Documented in `kafka_types.go` as "mainly for backwards compatibility with Operator 1.x" — don't use it.

## Verifying the setup on a live cluster

After deploying a Kafka CR with `topologySpreadConstraints` and/or `rackAssignment.nodeLabels`, confirm both pieces took effect:

```bash
# (a) topologySpreadConstraints reach the pod spec:
kubectl get pod <kafka-pod> -n <ns> -o jsonpath='{.spec.topologySpreadConstraints}'

# (b) broker.rack is set in the rendered kafka.properties:
kubectl exec <kafka-pod> -n <ns> -c kafka -- \
  grep ^broker.rack /opt/confluentinc/etc/kafka/kafka.properties

# Compare to the node's label (should match):
NODE=$(kubectl get pod <kafka-pod> -n <ns> -o jsonpath='{.spec.nodeName}')
kubectl get node $NODE -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'
```
