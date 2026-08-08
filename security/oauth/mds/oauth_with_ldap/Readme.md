## Introduction
In this example we will be deploying a kafka cluster with ERP and MDS enabled based on LDAP+OAUTH. We will be using OAuth for authentication and authorization. We will be using keycloak as IDP. We will be using RBAC for authorization.

## Pre-requisite

Follow [Sso](../../keycloak/) example to deploy keycloak

## Deploy Confluent for Kubernetes

1. Set up the Helm Chart:
```bash
   helm repo add confluentinc https://packages.confluent.io/helm
```
Note that it is assumed that your Kubernetes cluster has a ``confluent`` namespace available, otherwise you can create it by running ``kubectl create namespace confluent``. 

2.. Install Confluent For Kubernetes using Helm:
```bash
     helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace operator
```
3. Check that the Confluent For Kubernetes pod comes up and is running:
```bash    
     kubectl get pods --namespace operator
```

## Deployment

1. Create jaas config secret
    ```bash
    kubectl create -n operator secret generic oauth-jaas --from-file=oauth.txt=oauth_jaas.txt
    ```
2. apply cp_components.yaml
    ```bash
    kubectl apply -f cp_components.yaml
    ```

## Testing

1. Copy updated kafka.properties in /tmp
    ```bash
    kubectl cp -n operator kafka.properties  kafka-0:/tmp/kafka.properties
    ```
2. Do Shell
   ```bash
   kubectl -n operator exec kafka-0 -it /bin/bash
   ```
3. Run topic command against token listener 9073 as with rbac we spawn a new listener
   ```bash
   kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9073 --topic test-topic --create --replication-factor 3 --command-config /tmp/kafka.properties
    kafka-topics --bootstrap-server kafka.operator.svc.cluster.local:9073 --topic test-topic --describe --command-config /tmp/kafka.properties
   ```
4. Validate operator should not throw errors for kafka-rest-class controller, as these logs indicate operator client is able to successfully connect with ERP
5. Test Curl requests with IDP token
    ```bash
    curl --location 'https://localhost:8090/kafka/v3/clusters' \
    --header 'Accept: application/json' \
    --header 'Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCIgOiAiSldUIiwia2lkIiA6ICJkaXZId3QyUUpHWjdIc2JPSXBadmpNb1kyQ0hrOE1KM3g1WXlmZU4zaEJrIn0.eyJleHAiOjE3MTYxOTMwNjAsImlhdCI6MTcxNjE5Mjc2MCwianRpIjoiMThmOGExYjItNDk1ZS00NGJmLThhOGUtYTkwZjA1YjRhY2FhIiwiaXNzIjoiaHR0cDovL2xvY2FsaG9zdDo4MDgwL3JlYWxtcy9zc29fdGVzdCIsInN1YiI6ImY0OTljZmUxLThhMjktNDcyNy1iNWYxLWM3ODdlMzg5N2RkNyIsInR5cCI6IkJlYXJlciIsImF6cCI6InNzb2xvZ2luIiwiYWNyIjoiMSIsInJlYWxtX2FjY2VzcyI6eyJyb2xlcyI6WyJkZWZhdWx0LXJvbGVzLXNzb190ZXN0LTEiXX0sInNjb3BlIjoicHJvZmlsZSBlbWFpbCIsImVtYWlsX3ZlcmlmaWVkIjpmYWxzZSwiY2xpZW50SG9zdCI6IjEyNy4wLjAuMSIsInByZWZlcnJlZF91c2VybmFtZSI6InNlcnZpY2UtYWNjb3VudC1zc29sb2dpbiIsImNsaWVudEFkZHJlc3MiOiIxMjcuMC4wLjEiLCJjbGllbnRfaWQiOiJzc29sb2dpbiJ9.ODtBkzFiTgCJua6UDlS_9Gaq_XW4xN-sCOStZ936kJFXydGW72nzXMA8y5LwmGvSftqogUn1O27ERLkW5v3o6zb1BhEUZd4l1BJjzNByHkc70hgw9gIhL1RZ9rWR6PgXAFp_KbSIwpH6lZMTCxa7UTDFpaa2Vik5D9cZB-ONRcZhYcRycYJ1Ac3rTQZsYAr03wiMXXgK22s4fsPipicJboos3-c-4eGt2MXyRIJGnDM9VquFNDkOfhAAdP_KyFojRw4mo6Edd5yFbvLAU5-xrhXQ_ppS5eMhAZ0MwFn-aoKISr0uLc19v6-d8z9JeQVpyOaa4RRX1JkQHkIn_BWSdA'    
    ```
   ```bash
    curl --location 'https://localhost:8090/security/1.0/roles' \
    --header 'Accept: application/json' \
    --header 'Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCIgOiAiSldUIiwia2lkIiA6ICJkaXZId3QyUUpHWjdIc2JPSXBadmpNb1kyQ0hrOE1KM3g1WXlmZU4zaEJrIn0.eyJleHAiOjE3MTYzNjY5MjksImlhdCI6MTcxNjM2NjYyOSwianRpIjoiZDA2MmU2ODUtMmNjYS00N2Y1LTk4NWQtNjBiMzdkODcxYTc4IiwiaXNzIjoiaHR0cDovL2tleWNsb2FrOjgwODAvcmVhbG1zL3Nzb190ZXN0Iiwic3ViIjoiZjQ5OWNmZTEtOGEyOS00NzI3LWI1ZjEtYzc4N2UzODk3ZGQ3IiwidHlwIjoiQmVhcmVyIiwiYXpwIjoic3NvbG9naW4iLCJhY3IiOiIxIiwicmVhbG1fYWNjZXNzIjp7InJvbGVzIjpbImRlZmF1bHQtcm9sZXMtc3NvX3Rlc3QtMSJdfSwic2NvcGUiOiJwcm9maWxlIGVtYWlsIiwiZW1haWxfdmVyaWZpZWQiOmZhbHNlLCJjbGllbnRIb3N0IjoiMTI3LjAuMC4xIiwicHJlZmVycmVkX3VzZXJuYW1lIjoic2VydmljZS1hY2NvdW50LXNzb2xvZ2luIiwiY2xpZW50QWRkcmVzcyI6IjEyNy4wLjAuMSIsImNsaWVudF9pZCI6InNzb2xvZ2luIn0.7dCYbwdazRk1dmMV2n2NY2GTS3N_38FFTSwGlsfZWDmdPnJozkHaay-HPgf5PzJmlTL-hIBlttEUozRlU-Tkbxo4IeVgwHxFLfy1jpO2h1qqDY9JlIXCi3M4Dh8w7zpZm-jvaUQdyTeHmmT-5OXmG0R5zC7wzw3PhPRMDeS_Fv_3e4asEnQYD_lFPk9phUW4ObYsJ8QMvk79Q1dobHEHsGZOAp6IbpN7bBPJKEUN_cmcYN0j3jl_PWBGGnRy1uEIUQXIzdA-A4iBeE8VeIvypDI3lUic0kqmM71JOvDNM5xHdBQMjA52WmUG030CFKHQPXSc1sa2_LIRuJX1m_KhuQ'
    ```
   Note: Token passes here are issued by IDP like keycloak, and are valid for 5 minutes.
6. Test Curl request with LDAP token
    ```bash
    curl --location 'https://localhost:8090/kafka/v3/clusters' \
    --header 'Accept: application/json' \
    --header 'Authorization: Basic a2Fma2E6a2Fma2Etc2VjcmV0'    
    ```
   ```bash
    curl --location 'https://localhost:8090/security/1.0/roles' \
    --header 'Accept: application/json' \
    --header 'Authorization: Basic a2Fma2E6a2Fma2Etc2VjcmV0'
    ```
   Note: base64 coded username password (kafka/kafka-secret)