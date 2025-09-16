## Introduction
In this example we will be deploying a Day-2 components like Kafka Topic and SR using oauth client assertion flow.

## Pre-requisite
Deploy keycloak by following the steps [here](../keycloak/README.md).

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```bash
export TUTORIAL_HOME=<Tutorial directory>/security/oauth/client_assertion/day-2
```

## Deployment

1. Apply cp_components.yaml
```bash
kubectl apply -f cp_components.yaml
```

## Testing
1. Test Curl requests against SR cluster at 8081, after port forwarding
```bash
curl --location 'https://localhost:8081/subjects' \
--header 'Accept: application/json' \
--header 'Authorization: Bearer <oauth-token>'    
```
Note: Token passes here are issued by IDP like keycloak, and are valid for 5 minutes.
