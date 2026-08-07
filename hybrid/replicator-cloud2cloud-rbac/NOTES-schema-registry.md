# Personal notes: Schema Registry with Replicator + SMT

Notes from the cloud-to-cloud Replicator demos (`replicator-cloud2cloud-acls`, `replicator-cloud2cloud-rbac`).  
Focus: Avro, converters, shared vs separate Schema Registry, and how topic rename interacts with subjects.

Demo topic naming used here:

| Source | Destination (post-SMT) |
|---|---|
| `demo.orders.avro.v1` | `cloud.demo.orders.avro.v1` (RBAC) / `ccloud-eu.demo.orders.avro.v1` (ACLs) |
| `demo.customers.avro.v1` | `cloud.demo.customers.avro.v1` |
| `demo.inventory.avro.v1` | `cloud.demo.inventory.avro.v1` |

---

## Short version

| Setup | What to use | Result |
|---|---|---|
| **Shared SR** (same registry for source + dest) | `ByteArrayConverter` passthrough | Works. Payload keeps **source schema ID**; consumers resolve Avro by ID. |
| **Separate SRs** | ByteArrayConverter **alone** | **Breaks.** Dest consumer looks up schema ID in dest SR → `40403 schema not found`. |
| **Separate SRs** (correct approach) | ByteArrayConverter **+** Schema Linking / schema migration | Schemas (and IDs, depending on approach) available on dest before/while data flows. |
| Replicator + SMT + **`AvroConverter`** | Avoid | Registers `["null","bytes"]` under the **post-SMT** subject. |

---

## Why ByteArrayConverter (not AvroConverter)

Replicator already carries the Kafka value as **opaque bytes** (including Avro wire format: magic byte + schema ID + payload).

If you set:

```text
value.converter = io.confluent.connect.avro.AvroConverter
```

Connect treats those bytes as a Connect `BYTES` value. On produce, AvroConverter serializes that as an Avro schema like:

```json
["null", "bytes"]
```

and registers it under the **post-SMT** topic subject (e.g. `cloud.demo.orders.avro.v1-value`).

That is why we saw:

- Pre-SMT / source subject → correct record schema (e.g. `DemoRecord`)
- Post-SMT subject → `["null","bytes"]`

**Fix:** pass the wire format through unchanged:

```text
key.converter    = io.confluent.connect.replicator.util.ByteArrayConverter
value.converter  = io.confluent.connect.replicator.util.ByteArrayConverter
header.converter = io.confluent.connect.replicator.util.ByteArrayConverter
```

Same pattern as the base `replicator-cloud2cloud` tutorial.

---

## Shared Schema Registry

Source and destination Kafka clusters use **one** Schema Registry.

### What happens on produce (source)

1. Producer registers schema under e.g. `demo.orders.avro.v1-value`.
2. Messages contain schema ID `N`.

### What Replicator does (ByteArrayConverter)

1. Reads bytes from source (still schema ID `N`).
2. RegexRouter renames topic → `cloud.demo.orders.avro.v1` (or `ccloud-eu.demo.orders.avro.v1`).
3. Writes **same bytes** to dest. Schema ID in the payload is unchanged.

### What consumers do on dest

1. Read message from the post-SMT topic.
2. Avro deserializer calls dest SR `GET /schemas/ids/N`.
3. Shared SR has ID `N` → decode succeeds. **Works.**

### Subjects under post-SMT names

With ByteArrayConverter, `cloud.demo....-value` is often **never registered**. That is expected.

UI “schema for topic” is usually `{topic}-value` lookup. For post-SMT topics there may be no subject; consumers still work **by schema ID**.

### Why pre-SMT dest topics “have” the right schema in the UI

We pre-create `demo.*` on dest because:

- `topic.rename.format: ${topic}` → Replicator **admin** uses the pre-SMT name on dest
- RegexRouter → **produce** uses `cloud.demo.*` / `ccloud-eu.demo.*`

Subjects live on the **SR cluster**, not per Kafka cluster. Subject `demo.orders.avro.v1-value` was registered when producing to the **source** topic. Dest also has a Kafka topic named `demo.orders.avro.v1`, so the UI looks up the same shared subject — **name association**, not because Replicator wrote Avro into that dest topic. Actual replicated data is on the post-SMT topics.

---

## Non-shared (separate) Schema Registries

Source SR ≠ dest SR. Schema IDs are **not** the same ID space unless you migrate/link them.

### What breaks with ByteArrayConverter only

1. Message still carries source schema ID `N`.
2. Dest consumer asks **dest** SR for ID `N`.
3. Dest SR does not have it → `schema not found` / `40403`.

Passthrough only works when both sides resolve the **same** schema ID space (shared SR, or dest SR that imported those IDs).

### What to do instead

1. **Schema Linking** (typical Confluent Cloud)  
   Link source → dest SR so subjects/schemas are available on dest, then keep ByteArrayConverter on Replicator.

2. **Replicator schema translation / migration** (classic CP pattern)  
   - Still use `ByteArrayConverter` for data  
   - Migrate schemas (e.g. `_schemas` / SR migration APIs)  
   - Optional: `schema.subject.translator.class=io.confluent.connect.replicator.schemas.DefaultSubjectTranslator`  
   - Translator renames subjects using **`topic.rename.format`**, **not** RegexRouter  

   Implication: if SMT owns the rename but `topic.rename.format` is `${topic}`, subject translation will **not** automatically follow the SMT name. Align rename strategy if you rely on `DefaultSubjectTranslator`.

3. Do **not** “fix” separate SRs by switching Replicator to AvroConverter for SMT renames — you get the `["null","bytes"]` problem again.

---

## RegexRouter + topic.rename.format (reminder)

| Path | Name used |
|---|---|
| Replicator admin (create/describe/config) | `topic.rename.format` (here: same as source → `demo.*` on dest) |
| Produce after SMT | RegexRouter result → `cloud.demo.*` / `ccloud-eu.demo.*` |

With `topic.auto.create: false`:

- Missing **post-SMT** topic → `UNKNOWN_TOPIC_OR_PARTITION` on produce  
- Missing **pre-SMT** topic on dest → admin describe failures (under ACLs, often authorization on that name)

---

## Quick decision guide

```text
Same Schema Registry for src + dest?
  YES → ByteArrayConverter. Consume by schema ID. Done.
  NO  → Plan Schema Linking (or schema migration) first,
        then ByteArrayConverter for the data plane.
        Align subject rename with how topics are renamed
        if using DefaultSubjectTranslator.
```

Never use AvroConverter on Replicator just to “copy schemas” across an SMT rename.
