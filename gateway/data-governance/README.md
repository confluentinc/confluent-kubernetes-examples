# Confluent Gateway Data Governance Examples

With a data governance policy enabled, Gateway lets only records that match their schema reach Kafka. It can also run CSFLE and CSPE rules itself, encrypting fields or the whole payload on produce and decrypting them on fetch.

You define schemas and rule sets in Schema Registry. Gateway doesn't store policies of its own. It reads them from Schema Registry and enforces them on every produce and fetch.

## Prerequisites

### Licenses

Every Gateway product includes centralized governance. With an on-premises CP or CPC Schema Registry, rules and encryption also need a Schema Registry license to store them.

| Feature                 | Confluent Enterprise License         | Confluent Private Cloud License | Confluent Cloud Gateway License |
|-------------------------|--------------------------------------|---------------------------------|---------------------------------|
| **Gateway**             |                                      |                                 |                                 |
| Centralized governance  | Included                             | Included                        | Included                        |
| **Schema Registry**     |                                      |                                 |                                 |
| CEL and other rule sets | Included                             | Included                        | Not applicable¹                 |
| CSFLE                   | CSFLE or Flexible Encryption license | Included                        | Not applicable¹                 |
| CSPE                    | Flexible Encryption license          | Included                        | Not applicable¹                 |

¹ Confluent Cloud Gateway runs with the fully managed Confluent Cloud Schema Registry.

Gateway runs all the rules. These licenses let Schema Registry accept and store them.

For how to pass a license to Gateway, see [license-configuration](../license-configuration).

### Schema Registry extensions

Schema Registry needs two extensions to store rules and data keys.

| Feature                                          | Rule-set extension | DEK registry extension |
|--------------------------------------------------|--------------------|------------------------|
| Schema ID enforcement and deep schema validation | No                 | No                     |
| CEL and other rule sets                          | Yes                | No                     |
| CSFLE                                            | Yes                | Yes                    |
| CSPE                                             | Yes                | Yes                    |

Without the rule-set extension, Schema Registry drops the rule set and keeps the schema. The DEK registry stores the data keys.

To enable both extensions on a CFK-managed Schema Registry, set `configOverrides` on the `SchemaRegistry` CR:

```yaml
spec:
  configOverrides:
    server:
      - resource.extension.class=io.confluent.kafka.schemaregistry.rulehandler.RuleSetResourceExtension,io.confluent.dekregistry.DekRegistryResourceExtension
```

Outside CFK, add the same `resource.extension.class` line to `schema-registry.properties`.
