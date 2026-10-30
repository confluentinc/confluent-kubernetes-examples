# Confluent Gateway Centralized Governance Enforcement

With centralized governance enforcement enabled, Gateway lets only records that match their schema reach Kafka. It can also encrypt fields (GW field-level encryption, GWFLE) or the whole payload (GW full payload encryption, GW FPE) on produce and decrypt them on fetch.

You define schemas and rule sets in Schema Registry. Gateway doesn't store policies of its own. It reads them from Schema Registry and enforces them on every produce and fetch.

## Prerequisites

### Licenses

| Capability                          | CP Gateway Add-On                                                                                       | CPC Gateway                     | CC Gateway Add-On               |
|-------------------------------------|---------------------------------------------------------------------------------------------------------|---------------------------------|---------------------------------|
| Schema ID enforcement               | Confluent Platform Enterprise License                                                                   | Confluent Private Cloud License | Confluent Cloud Gateway License |
| Deep schema validation              | Confluent Platform Enterprise License                                                                   | Confluent Private Cloud License | Confluent Cloud Gateway License |
| GW field-level encryption (GWFLE)   | Confluent Platform Enterprise License and an encryption license (CSFLE or Flexible Encryption license) | Confluent Private Cloud License | Confluent Cloud Gateway License |
| GW full payload encryption (GW FPE) | Confluent Platform Enterprise License and an encryption license (CSFLE or Flexible Encryption license) | Confluent Private Cloud License | Confluent Cloud Gateway License |

For how to pass a license to Gateway, see [license-configuration](../license-configuration).

### Schema Registry extensions

Schema Registry needs two extensions to store rules and data keys.

| Feature                                          | Rule-set extension | DEK registry extension |
|--------------------------------------------------|--------------------|------------------------|
| Schema ID enforcement and deep schema validation | No                 | No                     |
| CEL and other rule sets                          | Yes                | No                     |
| GWFLE                                            | Yes                | Yes                    |
| GW FPE                                           | Yes                | Yes                    |

Without the rule-set extension, Schema Registry drops the rule set and keeps the schema. The DEK registry stores the data keys.

To enable both extensions on a CFK-managed Schema Registry, set `configOverrides` on the `SchemaRegistry` CR:

```yaml
spec:
  configOverrides:
    server:
      - resource.extension.class=io.confluent.kafka.schemaregistry.rulehandler.RuleSetResourceExtension,io.confluent.dekregistry.DekRegistryResourceExtension
```

Outside CFK, add the same `resource.extension.class` line to `schema-registry.properties`.
