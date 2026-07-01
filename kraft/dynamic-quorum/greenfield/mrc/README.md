# Dynamic Quorum - Multi-Region Clusters (MRC)

This directory contains examples for deploying KRaft controllers with dynamic quorum (KIP-853) in multi-region cluster (MRC) configurations.

## Available Examples

### [Two-Datacenter (2DC) Setup](./2dc-greenfield-loadbalancer/)
✅ **Complete and ready to use**

- Active-active configuration across two regions
- Cross-region KRaft controller quorum with 2+1 split
- Stretch clusters with dynamic membership
- LoadBalancer external access for cross-region communication

**Use this when:**
- Deploying across 2 Kubernetes clusters in different regions
- Need geographic redundancy and disaster recovery
- Want to survive single datacenter failure
- Running in cloud (GKE, EKS, AKS) with cross-region networking

### [Disaster Recovery (2.5DC, Secured)](../../disaster-recovery/)
✅ **Complete; includes quorum-loss + no-quorum-loss recovery scripts**

- 3 GKE clusters: 2 Kafka-bearing regions + 1 KRaft-only tiebreaker
- 5-voter KRaft quorum (2+2+1) with cluster ID patched across regions
- TLS + SASL/PLAIN + OAuth-MDS RBAC, shared CA, shared MDS keypair
- Pre-emptive metadata-log move via a pod-overlay sidecar

**Use this when:**
- You need to exercise majority-region failure (3 of 5 voters lost) and recovery
- Validating CFK behavior when KRaft quorum is rebuilt via `kafka-metadata-recovery`

## Other topologies

3DC (2-2-2 / 3-3-3) and the other multi-region shapes — voter math, quorum placement, and DR behavior — are covered in the [topology guides](../../topology-guides/) ([3DC](../../topology-guides/3dc.md)) and [`choosing-a-topology.md`](../../choosing-a-topology.md). This directory ships the 2DC worked example; the primitives generalize to those layouts.

## Use Cases

Multi-region clusters with dynamic quorum enable:

- **High Availability**: Survive datacenter failures
- **Disaster Recovery**: Maintain quorum across regions
- **Geographic Distribution**: Place controllers close to data
- **Elastic Scaling**: Add/remove controllers dynamically across regions

## Key Considerations

When deploying dynamic quorum across regions:

1. **Network Latency**: Higher latency affects consensus performance (keep <100ms RTT)
2. **Quorum Placement**: Ensure quorum can be maintained if a region fails (2+1 split for 2DC)
3. **Observer Strategy**: Use observers for read scaling without affecting quorum write latency
4. **Bootstrap Coordination**: Carefully orchestrate multi-region bootstrap (region 1 first, then region 2)
5. **Cross-Region Networking**: Requires VPC peering, VPN, or public LoadBalancer endpoints

## Related Documentation

- [Greenfield Quickstart](../quickstart/) - Start here to understand basics
- [Greenfield Overview](../) - All greenfield examples
- [Disaster Recovery](../../disaster-recovery/) - Failure scenarios + worked DR procedures (no-quorum-loss, data-safe and lossy quorum-loss). See also [Fault Tolerance](../../FAULT_TOLERANCE.md) for the underlying math and [Topology Guides](../../topology-guides/) for per-topology walkthroughs.
- [Main Dynamic Quorum README](../../README.md) - Overview of all examples

## Quick Start

The 2DC MRC deployment has its own README with the full, secured, step-by-step procedure — environment variables, certificates, per-region resource apply, DNS sync, and quorum verification.

See [`2dc-greenfield-loadbalancer/README.md`](2dc-greenfield-loadbalancer/README.md) for the complete walkthrough.
