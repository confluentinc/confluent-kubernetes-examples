### Introduction
As part of this tutorial we will install test keycloak

### Steps

1. Set Tutorial Home
```bash
export TUTORIAL_HOME= <Tutorial directory>/security/oauth/keycloak
```

2. Deploy keycloak
```bash
kubectl apply -f $TUTORIAL_HOME/keycloak_deploy.yaml
```

### Validate keycloak is successfully deployed

```bash
 while true; do kubectl port-forward service/keycloak 8080:8080 -n operator; done;
 // Add entry in /etc/hosts
 127.0.0.1    keycloak
 // in second terminal
 curl --location 'http://keycloak:8080/realms/sso_test/protocol/openid-connect/token' \
--header 'Content-Type: application/x-www-form-urlencoded' \
--header 'Authorization: Basic c3NvbG9naW46S2JMUmloMUh6akRDMjY3UGVmdUtVN1FJb1o4aGdIREs=' \
--data-urlencode 'grant_type=client_credentials'
```
