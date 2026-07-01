## Dynamic Quorum - Greenfield Deployments

This directory contains examples for deploying KRaft controllers with dynamic quorum (KIP-853) in greenfield (new) deployments.

### What is Greenfield?

Greenfield deployments start from scratch with no existing infrastructure. These examples show how to set up dynamic quorum from the beginning, so the cluster starts with `kraft.version=1` from day one.

### Available Examples

| Example | Security | MRC | Description |
|---------|----------|-----|-------------|
| [Quickstart](./quickstart/) | None | No | Single-region, plaintext. Simplest way to try dynamic quorum. |
| [Secured (LDAP RBAC)](./secured/) | TLS + SASL/PLAIN + LDAP RBAC | No | Single-region with full security stack. |
| [MRC LoadBalancer (Secured)](./mrc/2dc-greenfield-loadbalancer/) | TLS + SASL/PLAIN + OAuth + RBAC | Yes | Two-datacenter MRC with LoadBalancer external access. |

### Key Concepts

**Bootstrap Pod**: The first controller pod that formats storage with `--standalone` and becomes the initial voter in the quorum.

**Observer Pods**: Additional controller pods that format with `--no-initial-controllers` and start as observers. They can be promoted to voters later.

**ConfigMap Coordination**: A shared ConfigMap (`kraftcontroller-dynamic-quorum`) tracks bootstrap status to coordinate pod startup and prevent split-brain.

### General Workflow

1. **Setup**: Create ConfigMap, RBAC, and deploy KRaftController CR.
2. **Bootstrap**: Bootstrap pod initializes the cluster as a single-node quorum.
3. **Join**: Observer pods join as observers.
4. **Promote**: Observers are promoted to voters (automatic in CP 8.2+, manual in earlier versions).
5. **Deploy**: Deploy Kafka brokers that connect to the KRaft controllers.

### Resources

- [KIP-853: KRaft Controller Membership Changes](https://cwiki.apache.org/confluence/display/KAFKA/KIP-853%3A+KRaft+Controller+Membership+Changes)
- [Main Dynamic Quorum README](../README.md)
