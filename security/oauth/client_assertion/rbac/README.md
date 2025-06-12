## Introduction
In this example we will be deploying a kafka cluster with ERP and MDS enabled. We will be using OAuth client assertion flow for authentication and authorization. We will be using keycloak as IDP. We will be using RBAC for authorization.

## Pre-requisite
Deploy keycloak by following the steps [here](../keycloak/README.md).

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

    ```bash
    export TUTORIAL_HOME=<Tutorial directory>/security/oauth/client_assertion/rbac
    ```

## Deployment

1. Create jass config secret
    ```bash
    kubectl create -n operator secret generic oauth-jass --from-file=oauth.txt=oauth_jass.txt
    ```
2. Apply cp_components.yaml
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
