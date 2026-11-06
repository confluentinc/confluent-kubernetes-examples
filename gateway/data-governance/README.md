# Confluent Gateway Centralized Governance Enforcement

With centralized governance enforcement enabled, Gateway lets only records that match their schema
reach Kafka.
It can also encrypt fields (GW field-level encryption, GWFLE) or the whole payload (GW payload
encryption, GWPE) on produce and decrypt them on fetch.

You define schemas and rule sets in Schema Registry.
Gateway doesn't store policies of its own.
It reads them from Schema Registry and enforces them on every produce and fetch.

## What Gateway enforces

Two settings control what Gateway enforces:
- `enabled` in the Gateway CR, for the record key or value.
- `enableAt` in the rule set of the schema, in Schema Registry.

Gateway runs the same checks on produce and on fetch.
The record key and value are checked separately, each against its own subject, schema and enabled
setting.

| Gateway `enabled` | Schema `enableAt`           | Schema ID enforcement | Deep schema validation | CEL conditions and transforms | GWFLE            | GWPE             |
|-------------------|-----------------------------|-----------------------|------------------------|-------------------------------|------------------|------------------|
| `false`           | any                         | —                     | —                      | —                             | —                | —                |
| `true`            | `CLIENT` or `SERVER`        | ✔                     | ✔                      | Client or server              | Client or server | Client or server |
| `true`            | `GATEWAY`, `ALL` or not set | ✔                     | ✔                      | ✔ †                           | ✔ †              | ✔ †              |
| `true`            | `NONE`                      | ✔                     | ✔                      | — no one                      | — no one         | — no one         |

- Clients serialize with Confluent's Schema Registry serializers so each record carries a schema ID.
- `enabled: false` is a full bypass: Gateway doesn't read the schema ID, whatever the schema says.
- † Only when the schema carries that rule. Otherwise Gateway forwards the record unchanged.

## Prerequisites

### Licenses

| Capability                          | CP Gateway Add-On                                                                                       | CPC Gateway                     | CC Gateway Add-On               |
|-------------------------------------|---------------------------------------------------------------------------------------------------------|---------------------------------|---------------------------------|
| Schema ID enforcement               | Confluent Platform Enterprise License                                                                   | Confluent Private Cloud License | Confluent Cloud Gateway License |
| Deep schema validation              | Confluent Platform Enterprise License                                                                   | Confluent Private Cloud License | Confluent Cloud Gateway License |
| GW field-level encryption (GWFLE)   | Confluent Platform Enterprise License and an encryption license (CSFLE or Flexible Encryption license) | Confluent Private Cloud License | Confluent Cloud Gateway License |
| GW payload encryption (GWPE)        | Confluent Platform Enterprise License and an encryption license (CSFLE or Flexible Encryption license) | Confluent Private Cloud License | Confluent Cloud Gateway License |

For how to pass a license to Gateway, see [license-configuration](../license-configuration).

### Schema Registry extensions

Schema Registry needs two extensions to store rules and data keys.

| Feature                                          | Rule-set extension | DEK registry extension |
|--------------------------------------------------|--------------------|------------------------|
| Schema ID enforcement and deep schema validation | No                 | No                     |
| CEL and other rule sets                          | Yes                | No                     |
| GWFLE                                            | Yes                | Yes                    |
| GWPE                                             | Yes                | Yes                    |

Without the rule-set extension, Schema Registry drops the rule set and keeps the schema.
The DEK registry stores the data keys.

To enable both extensions on a CFK-managed Schema Registry, set `configOverrides` on the
`SchemaRegistry` CR:

```yaml
spec:
  configOverrides:
    server:
      - resource.extension.class=io.confluent.kafka.schemaregistry.rulehandler.RuleSetResourceExtension,io.confluent.dekregistry.DekRegistryResourceExtension
```

Outside CFK, add the same `resource.extension.class` line to `schema-registry.properties`.

## Examples

| Example                                      | Description                                                                                                               |
|----------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| [schema-validation](./schema-validation)     | Schema ID enforcement and deep schema validation on record values, with a per-topic override                              |
| [encryption](./encryption)                   | GW field-level encryption (GWFLE) of a tagged field and GW payload encryption (GWPE) of the record value                  |
| [cel-rules](./cel-rules)                     | CEL and CEL_FIELD data quality rules that reject records which fail a condition                                           |
| [schema-registry-tls](./schema-registry-tls) | The schema-validation example with Schema Registry over TLS and basic authentication, with certificates from cert-manager |
