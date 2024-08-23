## Introduction
In this example we will be deploying a kafka cluster with ERP and MDS enabled. We will be using OAuth for authentication and authorization. We will be using keycloak as IDP. We will be using RBAC for authorization.

## Pre-requisite

Follow [Sso](../keycloak/) example to deploy keycloak

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

1. Create jass config secret
    ```bash
    kubectl create -n operator secret generic oauth-jass --from-file=oauth.txt=oauth_jass.txt
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
5. Test Curl requests against rest proxy at 8082, after port forwarding
    ```bash
    curl --location 'https://localhost:8082/v3/clusters' \
    --header 'Accept: application/json' \
    --header 'Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCIgOiAiSldUIiwia2lkIiA6ICJkaXZId3QyUUpHWjdIc2JPSXBadmpNb1kyQ0hrOE1KM3g1WXlmZU4zaEJrIn0.eyJleHAiOjE3MTYxOTMwNjAsImlhdCI6MTcxNjE5Mjc2MCwianRpIjoiMThmOGExYjItNDk1ZS00NGJmLThhOGUtYTkwZjA1YjRhY2FhIiwiaXNzIjoiaHR0cDovL2xvY2FsaG9zdDo4MDgwL3JlYWxtcy9zc29fdGVzdCIsInN1YiI6ImY0OTljZmUxLThhMjktNDcyNy1iNWYxLWM3ODdlMzg5N2RkNyIsInR5cCI6IkJlYXJlciIsImF6cCI6InNzb2xvZ2luIiwiYWNyIjoiMSIsInJlYWxtX2FjY2VzcyI6eyJyb2xlcyI6WyJkZWZhdWx0LXJvbGVzLXNzb190ZXN0LTEiXX0sInNjb3BlIjoicHJvZmlsZSBlbWFpbCIsImVtYWlsX3ZlcmlmaWVkIjpmYWxzZSwiY2xpZW50SG9zdCI6IjEyNy4wLjAuMSIsInByZWZlcnJlZF91c2VybmFtZSI6InNlcnZpY2UtYWNjb3VudC1zc29sb2dpbiIsImNsaWVudEFkZHJlc3MiOiIxMjcuMC4wLjEiLCJjbGllbnRfaWQiOiJzc29sb2dpbiJ9.ODtBkzFiTgCJua6UDlS_9Gaq_XW4xN-sCOStZ936kJFXydGW72nzXMA8y5LwmGvSftqogUn1O27ERLkW5v3o6zb1BhEUZd4l1BJjzNByHkc70hgw9gIhL1RZ9rWR6PgXAFp_KbSIwpH6lZMTCxa7UTDFpaa2Vik5D9cZB-ONRcZhYcRycYJ1Ac3rTQZsYAr03wiMXXgK22s4fsPipicJboos3-c-4eGt2MXyRIJGnDM9VquFNDkOfhAAdP_KyFojRw4mo6Edd5yFbvLAU5-xrhXQ_ppS5eMhAZ0MwFn-aoKISr0uLc19v6-d8z9JeQVpyOaa4RRX1JkQHkIn_BWSdA'    
    ```
   Note: Token passes here are issued by IDP like keycloak, and are valid for 5 minutes.