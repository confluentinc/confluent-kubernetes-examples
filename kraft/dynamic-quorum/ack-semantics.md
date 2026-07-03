# Ack Semantics: KRaft vs Kafka

How KRaft metadata writes and Kafka topic writes acknowledge — and how the two layers of fault tolerance interact. Read this alongside [`FAULT_TOLERANCE.md`](FAULT_TOLERANCE.md), which focuses on the KRaft layer's fault tolerance in isolation.

## Two layers of fault tolerance

A KRaft-based Kafka cluster has **two layers of fault tolerance**, each with its own math:

| Layer | What's stored | Fault tolerance bound |
|---|---|---|
| **KRaft metadata quorum** | Cluster metadata (topics, partitions, ACLs, configs) | `floor((N-1)/2)` voter failures for `N` voters (every write requires a majority ack); see [`FAULT_TOLERANCE.md`](FAULT_TOLERANCE.md) for the table |
| **Kafka topic data** (per partition ISR) | Producer-written records | `replication.factor - min.insync.replicas` replicas out of ISR while writes still succeed (assumes `acks=all`) |

The two layers have separate availability math, but they are **not operationally independent** — do not plan on either side surviving the other's outage cleanly:

- **Kafka brokers depend on KRaft for metadata operations.** Any operation that mutates metadata — ISR membership changes, leader elections, topic/ACL changes — needs a live KRaft quorum. If KRaft is unavailable, brokers can keep serving reads and `acks=all` writes against their *current* leader/ISR state as long as no partition needs an ISR change; once one does, the controller-side commit blocks. In particular, ISR shrink may not progress while KRaft is down: a single unresponsive broker still listed in ISR can stall `acks=all` writes (the leader waits for an ack it won't get, and the `AlterPartition` record can't be committed without KRaft). Behavior here depends on partition-by-partition state; don't assume any specific guarantee.
- **KRaft can depend on Kafka, depending on configuration.** With RBAC enabled, KRaft talks to MDS (which runs on Kafka brokers) for authn/authz. If Kafka is down long enough, KRaft pods can hit timeouts (~10 min) and crashloop until brokers return.

Net: state weakly. Kafka may keep serving traffic for a while when KRaft is down, but that depends on replicas, partitions, ISR state, and whether anything triggers an unresolvable metadata operation. Don't bank on it.

## KRaft writes vs Kafka writes — different ack semantics

This is the source of most confusion. KRaft and Kafka **look** similar (both use a log-replicated state machine, both support followers/observers) but their write-acknowledgement rules are different.

### Kafka topic write (producer → broker)

The producer's `acks` setting controls when the broker acknowledges a write:

- `acks=0` — fire-and-forget. The producer doesn't wait for any ack. Any record the leader hasn't yet persisted is lost.
- `acks=1` — leader-only ack. The producer waits until the leader has written to its local log; followers may not yet have the record. If the leader fails before replication, the write is lost.
- `acks=all` (alias `acks=-1`) — the leader waits for **every member of the current ISR** to acknowledge. `min.insync.replicas` is a **precondition gate**, not an ack-count threshold: if `|ISR| < min.insync.replicas` the write is rejected up-front with `NotEnoughReplicasException`. Once the gate passes, the leader waits for the full ISR.

`min.insync.replicas` counts **replicas** (leader counts), not "followers" — the leader is itself in ISR. `min.insync.replicas=2` with `replication.factor=3` means "leader + at least 1 follower must be in ISR before writes are accepted." Under `acks=all` this tolerates `RF − min.insync.replicas` replicas falling out of ISR before writes start failing.

### KRaft metadata write (controller leader → controller followers)

- Leader appends to its local log, then waits for **a majority of voters** (more than half) to acknowledge.
- This is the standard Raft majority rule. There is no `min.isr`-style knob for KRaft; the threshold is hard-coded by the topology size.
- 5 voters → need 3 acks → tolerates 2 voter failures.
- 3 voters → need 2 acks → tolerates 1 voter failure.

**Consequence**: KRaft's durability floor is fixed at majority — there is no equivalent of `acks=0/1` or `min.isr=1` to drop below it. Kafka topics, by contrast, are configurable: from `acks=0` (no durability) up through `acks=all` with full-ISR acks. A Kafka topic with `min.isr=2, RF=3` tolerates 1 replica out of ISR; the KRaft metadata partition with 3 voters also tolerates 1 voter failure — same number, but KRaft's bound is structural while Kafka's is a configuration choice.
