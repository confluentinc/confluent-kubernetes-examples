# Confluent Gateway Examples

## Configuration Scenarios

| Dimension                  | Options                            | Description                                  |
|----------------------------|------------------------------------|----------------------------------------------|
| **Authentication Mode**    | Passthrough / Authentication Swap  | Client to cluster authentication type        |
| **Routing Strategy**       | Port-based / Host-based            | How brokers are distinguished                |
| **Client TLS**             | None / TLS / mTLS                  | Encryption between client and gateway        |
| **Cluster TLS**            | None / TLS / mTLS                  | Encryption between gateway and Kafka cluster |
| **Client Authentication**  | PLAIN / SCRAM / mTLS / OAUTHBEARER | Authentication mechanism for clients         |
| **Cluster Authentication** | PLAIN / OAUTHBEARER                | Authentication mechanism for Kafka cluster   |

## Example Scenarios

### Identity passthrough authentication

| Scenario                                           | Auth Mode | Routing | Client TLS | Cluster TLS | Client Auth | Cluster Auth | Description |
|----------------------------------------------------| --- | --- | --- | --- | --- | --- | --- |
| [passthrough-sasl-plain](./passthrough-sasl-plain) | Passthrough | Port | None | None | PLAIN | PLAIN | Simple plaintext setup with basic authentication |
| [passthrough-sasl-ssl](./passthrough-sasl-ssl)     | Passthrough | Host | TLS | TLS | PLAIN | PLAIN | Host-based routing with TLS encryption and SASL/PLAIN authentication |
| [passthrough-sasl-ssl-ccloud](./passthrough-sasl-ssl-ccloud) | Passthrough | Host | TLS | TLS | PLAIN | PLAIN | Confluent Cloud with a JKS truststore secret for the Let's Encrypt CA and API key passthrough |
| [passthrough-sasl-ssl-ccloud-pem](./passthrough-sasl-ssl-ccloud-pem) | Passthrough | Host | TLS | TLS | PLAIN | PLAIN | Confluent Cloud with a PEM secret for the Let's Encrypt CA and API key passthrough |
| [passthrough-sasl-ssl-ccloud-default-truststore](./passthrough-sasl-ssl-ccloud-default-truststore) | Passthrough | Host | TLS | TLS | PLAIN | PLAIN | Confluent Cloud with the default Java truststore (no CA secret) and API key passthrough |
| [passthrough-oauth-ssl-ccloud](./passthrough-oauth-ssl-ccloud) | Passthrough | Host | TLS | TLS | OAUTHBEARER | OAUTHBEARER | Confluent Cloud with OAuth passthrough and a logical cluster extension header |
| [authswap-sasl-plain-sasl-plain](./authswap-sasl-plain-sasl-plain) | Authentication Swap | Port | None | None | PLAIN | PLAIN | Simple authentication swap setup with SASL/PLAIN authentication |
| [authswap-none-sasl-plain](./authswap-none-sasl-plain) | Authentication Swap | Port | None | None | NONE | PLAIN | Authentication swap from ANONYMOUS clients to SASL/PLAIN |
| [authswap-sasl-plain-none](./authswap-sasl-plain-none) | Authentication Swap | Port | None | None | PLAIN | NONE | Authentication swap from SASL/PLAIN clients to no authentication |
| [authswap-sasl-scram-sasl-plain](./authswap-sasl-scram-sasl-plain) | Authentication Swap | Port | None | None | SCRAM | PLAIN | Authentication swap from SASL/SCRAM to SASL/PLAIN |
| [authswap-sasl-scram-sasl-oauth](./authswap-sasl-scram-sasl-oauth) | Authentication Swap | Port | None | None | SCRAM | OAUTHBEARER | Authentication swap from SASL/SCRAM to OAUTHBEARER |
| [authswap-sasl-oauth-sasl-oauth](./authswap-sasl-oauth-sasl-oauth) | Authentication Swap | Port | None | None | OAUTHBEARER | OAUTHBEARER | Authentication swap from OAUTHBEARER to swapped OAUTHBEARER credentials |
