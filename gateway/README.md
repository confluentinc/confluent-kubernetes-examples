# Confluent Gateway Examples

## Configuration Scenarios

| Dimension                  | Options                           | Description                                  |
|----------------------------|-----------------------------------|----------------------------------------------|
| **Authentication Mode**    | Passthrough / Authentication Swap | Client to cluster authentication type        |
| **Routing Strategy**       | Port-based / Host-based           | How requests are routed to Kafka brokers     |
| **Client TLS**             | None / TLS / mTLS                 | Encryption between client and gateway        |
| **Cluster TLS**            | None / TLS / mTLS                 | Encryption between gateway and Kafka cluster |
| **Client Authentication**  | PLAIN / mTLS                      | Authentication mechanism for clients         |
| **Cluster Authentication** | PLAIN / OAUTHBEARER               | Authentication mechanism for Kafka cluster   |

## Example Scenarios

### Identity passthrough authentication

| Scenario                                           | Auth Mode | Routing | Client TLS | Cluster TLS | Client Auth | Cluster Auth | Description |
|----------------------------------------------------| --- | --- | --- | --- | --- | --- | --- |
| [passthrough-sasl-plain](./passthrough-sasl-plain) | Passthrough | Port | None | None | PLAIN | PLAIN | Simple plaintext setup with basic authentication |
