## Introduction
This playbook deploys Kraft, Kafka and SR using OAuth Client Assertion flow.

## Pre-requisite
Deploy keycloak by following the steps [here](../keycloak/README.md).

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```bash
export TUTORIAL_HOME=<Tutorial directory>/security/oauth/client_assertion/non-rbac
```

## CP Deployment

1. Create jass config pass through secret
```bash
kubectl create -n operator secret generic pass-through-repl --from-file=oauth-jass.conf=oauth_jass_repl.txt
```
2. Apply cp_components.yaml
```bash
kubectl apply -f cp_components.yaml
```
   
## Testing

1. Copy updated kafka.properties and private_key in /tmp
```bash
kubectl cp -n operator kafka.properties  kafka-0:/tmp/kafka.properties
   
kubectl cp -n operator private_key.pem  kafka-0:/tmp/private_key.pem
```

private_key.pem is created in playbooks/features/sso directory. It is used to sign the JWT token for client assertion.

2. Do Shell
```bash
kubectl -n operator exec kafka-0 -it /bin/bash
```

3. Whitelist the token endpoints
```bash
export KAFKA_OPTS="-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls=*"
```

4. Run topic command
```bash
kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9071 --topic test-topic-internal --create --replication-factor 3 --command-config /tmp/kafka.properties
kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9092 --topic test-topic-external --create --replication-factor 3 --command-config /tmp/kafka.properties
kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9072 --topic test-topic-replication --create --replication-factor 3 --command-config /tmp/kafka.properties
kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9094 --topic test-topic-custom --create --replication-factor 3 --command-config /tmp/kafka.properties
```

5. Test Curl requests against SR cluster at 8081, after port forwarding
```bash
curl -k --location 'https://schemaregistry.operator.svc.cluster.local:8081/subjects' \
--header 'Accept: application/json' \
--header 'Authorization: Bearer <oauth-token>'    
```
Note: Token passes here are issued by IDP like keycloak, and are valid for 5 minutes.
