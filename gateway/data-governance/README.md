# Confluent Gateway Data Governance Examples

With a data governance policy enabled, Gateway lets only records that match their schema reach Kafka. It can also run CSFLE and CSPE rules itself, encrypting fields or the whole payload on produce and decrypting them on fetch.

You define schemas and rule sets in Schema Registry. Gateway doesn't store policies of its own. It reads them from Schema Registry and enforces them on every produce and fetch.

## Licensing

### Gateway

Every Gateway license includes data governance, covering schema validation, rules and encryption.

| Deployment              | Gateway license   |
|-------------------------|-------------------|
| Confluent Platform      | CP Gateway add-on |
| Confluent Private Cloud | Included          |
| Confluent Cloud         | CC Gateway add-on |

For how to pass a license to Gateway, see [license-configuration](../license-configuration).

### Schema Registry

Rule sets and encryption also need Schema Registry entitlements. Gateway runs all the rules. These licenses let Schema Registry accept and store them.

| Feature                                          | Confluent Platform                  | Confluent Private Cloud | Confluent Cloud            |
|--------------------------------------------------|-------------------------------------|-------------------------|----------------------------|
| Schema ID enforcement and deep schema validation | Nothing extra                       | Nothing extra           | Nothing extra              |
| CEL and other rule sets                          | Confluent Enterprise license        | Included                | Stream Governance Advanced |
| CSFLE                                            | CSFLE or Flexible Encryption add-on | Included                | Stream Governance Advanced |
| CSPE                                             | Flexible Encryption add-on          | Included                | Stream Governance Advanced |

## Schema Registry extensions

Schema Registry also needs extensions to carry the rules.

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
