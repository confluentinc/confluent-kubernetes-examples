# Deploy CFK and CP with Okta OAuth/OIDC SSO and TLS

This workflow deploys and configures a Confluent Platform cluster using the Confluent for Kubernetes operator with the following features:

- **Full TLS network encryption** with auto-generated certificates
- **OAuth/OIDC Authentication** support
- **Role Based Access Control (RBAC)** Authorization
- **Single Sign-On (SSO)** with Okta for Confluent Control Center (C3)
- **Resource management** with CPU and Memory pod limits and requests
- **Rack placement** and oneReplicaPerNode for Kafka Broker pods
- **Client testing** with Okta Client ID and Secret

## Prerequisites

### Kubernetes Cluster Requirements

- **Kubernetes cluster** with appropriate access
  - Access and set KubeContext to the target Kubernetes cluster
  - Default Storage Class configured
  - Worker nodes with sufficient resources

### Command Line Tools

Ensure the following command line tools are installed:

```bash
{
  command -v git kubectl helm cfssl curl jq
}
```

### Repository Setup

Clone the repository and navigate to the appropriate directory:

```bash
{
  git clone https://github.com/confluentinc/confluent-kubernetes-examples.git
  cd confluent-kubernetes-examples/security/oauth/okta/tls
}
```

### Environment Configuration

Set up the required environment variables:

```bash
{
  # Set the environment variables
  export CP_HOME=$(pwd)
  export CP_NS=confluent
  export CP_COMP=(kraftcontroller kafka schemaregistry connect ksqldb kafkarestproxy controlcenter)
  export CERTS_HOME=${CP_HOME}/../certs

  echo "Displaying environment variables"
  echo " CP_NS=${CP_NS} \n CP_COMP=${CP_COMP} \n CP_HOME=${CP_HOME} \n CERTS_HOME=${CERTS_HOME}"
}
```
### Namespace and Service Account Setup

Create namespace and set context:

```bash
{
  # Create namespace and set the context
  kubectl create namespace ${CP_NS}
  kubectl config set-context --current --namespace=${CP_NS}
}
```

Create a service account for the Confluent Platform:

```bash
{
  # Create service account and bind cluster role
  kubectl create serviceaccount confluent-platform
  kubectl create clusterrole confluent-platform --resource=nodes,pods --verb=get,list
  kubectl create clusterrolebinding confluent-platform \
    --clusterrole=confluent-platform \
    --serviceaccount=${CP_NS}:confluent-platform
}
```

### Okta Identity Provider Configuration

The Okta identity provider (IdP) is used for OAuth/OIDC authentication. Follow these steps to configure Okta for OAuth/OIDC authentication.

#### Create an Okta Integrator Account

1. **Sign up** for an Okta Integrator account at [https://developer.okta.com/signup/](https://developer.okta.com/signup/)
   - Click "Sign up for Integrator Free Plan"

2. **Login** to the Okta integrator admin console

   - Example URL: `https://integrator-4487007-admin.okta.com/admin/dashboard`
   - Export the Okta domain to an environment variable
     ```bash
     {
       # Replace with the actual Okta domain
       export OKTA_DOMAIN="integrator-4487007-admin.okta.com"
       echo "OKTA_DOMAIN=${OKTA_DOMAIN}"
     }
     ```

3. **Verify configuration** by checking the well-known endpoint for the default authorization server

    ```sh
    {
      # Verify the default authorization server configuration
      curl -k https://${OKTA_DOMAIN}/oauth2/default/.well-known/openid-configuration | jq .
    }
    ```

> **Note**: [Okta Developer Edition](https://developer.okta.com/blog/2025/05/13/okta-developer-edition-changes) has been deprecated.

#### Add API Authorization Server

An authorization server issues access tokens to clients for accessing protected resources in the Confluent Platform. While we can use the default authorization server, we'll create a new one for better organization.

1. **Navigate** to: `Security` → `API` → `Authorization Servers` → `Add Authorization Server`

2. **Configure** the authorization server:
   - **Name**: `confluent`
   - **Audience**: `api://confluent`
   - **Description**: `Confluent Platform OAuth/OIDC`
   - Click `Save`

##### Add a Scope

Scopes define permissions that clients can request from the authorization server.

1. **Navigate** to: `Scopes` → `Add Scope`
2. **Configure** the scope:
   - **Name**: `confluent`
   - **Display phrase**: `confluent`
   - **Description**: `Confluent Platform Scope`
   - Click `Create`

##### Add a Groups Claim

Claims provide information about the user (e.g., email, name, group membership) in ID and access tokens.

1. **Navigate** to: `Claims` → `Add Claim`
2. **Configure** the claim:
   - **Name**: `groups`
   - **Include in token type**: Leave `ID Token` selected
   - **Value type**: `Groups`
   - **Filter**: `Matches regex` with pattern `.*` (matches all groups)
   - Click `Create`

##### Add Access Policy

Access policies define conditions for client API access.

1. **Navigate** to: `Access Policies` → `Add Policy`
2. **Configure** the policy:
   - **Name**: `confluent`
   - **Description**: `Confluent Platform OAuth/OIDC`
   - **Assign to**: `All clients`
   - Click `Create Policy`

3. **Add Rule** by clicking `Add Rule`:
   - **Rule Name**: `confluent`
   - **Grant types**: `Client Credentials`, `Authorization Code`, `Device Authorization Grant`
   - **User assignment**: `Any user assigned the app`
   - **Scopes**: `Any scopes`
   - **Access token lifetime**: `1 hour`
   - **Refresh token lifetime**: `90 days` (expire if not used every `7 days`)
   - Click `Create Rule`

#### Add Applications

Applications are clients that request access tokens from the authorization server to access protected resources.

##### Service-to-Service Application

For Confluent Platform services with OAuth, create an `API Services` application with `client credentials` grant type.

1. **Navigate** to: `Applications` → `Applications` → `Create App Integration`
2. **Select** sign-in method: `API Services` and click `Next`
3. **Configure** the application:
   - **App integration name**: `Confluent Server S2S`
   - Click `Save`
4. **Edit settings**:
   - Under `General Settings`, click `Edit`
   - **Uncheck** `Require Demonstrating Proof of Possession (DPoP) header in token requests`
   - Click `Save`

> **Important**: Note the generated `Client ID` and `Client Secret` for later use.

##### Client Service-to-Service Application for testing

For client testing, create one more `API Services` application with `client credentials` grant type.

1. **Navigate** to: `Applications` → `Applications` → `Create App Integration`
2. **Select** sign-in method: `API Services` and click `Next`
3. **Configure** the application:
   - **App integration name**: `Confluent Client S2S`
   - Click `Save`
4. **Edit settings**:
   - Under `General Settings`, click `Edit`
   - **Uncheck** `Require Demonstrating Proof of Possession (DPoP) header in token requests`
   - Click `Save`

> **Important**: Note the generated `Client ID` and `Client Secret` for later use.

##### User-to-Service Application

For Confluent Control Center SSO with Okta, create an OIDC application with authorization code grant type.

1. **Navigate** to: `Applications` → `Applications` → `Create App Integration`
2. **Select** sign-in method: `OIDC - OpenID Connect`
3. **Select** application type: `Native Application` and click `Next`
4. **Configure** the application:
   - **App integration name**: `Confluent SSO U2S`
   - **Grant types**: Select `Authorization Code`, `Refresh Token`, and `Device Authorization`
   - **Sign-in redirect URIs**: Click `+Add URI`
     - `https://localhost:9021/api/metadata/security/1.0/oidc/authorization-code/callback`
     - `https://localhost/cli_callback`
     - `http://localhost:8080/authorization-code/callback` (for testing)
      > **Note**: `localhost` is used for testing. In production, use actual domain names.
   - **Controlled access**: Check `Allow everyone in the organization to access`
   - **Federation Broker Mode**: Disabled
   - Click `Save`

5. **Edit additional settings**:
   - Under `Client Credentials`, click `Edit`
   - **Client authentication**: Select `Client secret`
   - **PKCE**: Uncheck `Proof Key for Code Exchange (PKCE)`
   - Click `Save`

> **Important**: Note the generated `Client ID` and `Client Secret` for later use.

6. **Verify assignments**: Check the Assignments tab to ensure the application is assigned to appropriate users or groups.

#### Well-Known Configuration

Retrieve the well-known configuration for the `confluent` authorization server.

1. **Get Metadata URL**: Navigate to `Security` → `API` → `Authorization Servers` → `confluent` → `Metadata URL`

2. **Fetch configuration**:

```bash
{
  # Replace with the actual Okta domain and confluent authorization server
  # Get OpenID configuration
  curl -s -k https://${OKTA_DOMAIN}/oauth2/austyga8unDE3r3c0697/.well-known/openid-configuration | \
    jq '{issuer,authorization_endpoint,token_endpoint,registration_endpoint,jwks_uri}'

  # Alternative: OAuth authorization server configuration
  curl -s -k https://${OKTA_DOMAIN}/oauth2/austyga8unDE3r3c0697/.well-known/oauth-authorization-server | \
    jq '{issuer,authorization_endpoint,token_endpoint,registration_endpoint,jwks_uri}'
}
```

Expected output might look like this, vary depending on the Okta domain and application.

```json
{
  "issuer": "https://integrator-4487007.okta.com/oauth2/austyga8unDE3r3c0697",
  "authorization_endpoint": "https://integrator-4487007.okta.com/oauth2/austyga8unDE3r3c0697/v1/authorize",
  "token_endpoint": "https://integrator-4487007.okta.com/oauth2/austyga8unDE3r3c0697/v1/token",
  "registration_endpoint": "https://integrator-4487007.okta.com/oauth2/v1/clients",
  "jwks_uri": "https://integrator-4487007.okta.com/oauth2/austyga8unDE3r3c0697/v1/keys"
}
```

> **Note**: Based on the above output, the conflufent platform manifest files need to be updated with the correct values for oauth and oidc settings.

#### OAuth Configuration Files

Set environment variables for the Okta application credentials:

```bash
{
  # OAuth JAAS configuration for service-to-service authentication
  export S2S_CLIENT_ID="0oatyggyffLeL9AyC697"
  export S2S_CLIENT_SECRET="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

  # OAuth JAAS configuration for client testing
  export CLIENT_CLIENT_ID="0oaut4itbi0EM26kW697"
  export CLIENT_CLIENT_SECRET="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

  # OIDC client secret for sso/user authentication
  export USER_CLIENT_ID="0oatygdlayC0HZTNq697"
  export USER_CLIENT_SECRET="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

  echo "Displaying Okta environment variables"
  echo "S2S_CLIENT_ID=${S2S_CLIENT_ID}"
  echo "S2S_CLIENT_SECRET=${S2S_CLIENT_SECRET}"
  echo "CLIENT_CLIENT_ID=${CLIENT_CLIENT_ID}"
  echo "CLIENT_CLIENT_SECRET=${CLIENT_CLIENT_SECRET}"
  echo "USER_CLIENT_ID=${USER_CLIENT_ID}"
  echo "USER_CLIENT_SECRET=${USER_CLIENT_SECRET}"
}
```

#### Create Kubernetes Secrets for OAuth and OIDC

Create Kubernetes secrets for OAuth and SSO authentication:

```bash
{
  # Create secret for OAuth JAAS configuration using environment variables
  kubectl create secret generic oauth-jass \
    --from-literal=oauth.txt="clientId=${S2S_CLIENT_ID}"$'\n'"clientSecret=${S2S_CLIENT_SECRET}"$'\n'

  # Create secret for OIDC client configuration (for C3 SSO)
  kubectl create secret generic oauth-jass-oidc \
    --from-literal=oidcClientSecret.txt="clientId=${USER_CLIENT_ID}"$'\n'"clientSecret=${USER_CLIENT_SECRET}"$'\n'

  echo "\nVerifying OAuth secret is created correctly"
  kubectl get secret oauth-jass -o jsonpath='{.data.oauth\.txt}' | base64 -d
  echo "\nVerifying OIDC secret is created correctly"
  kubectl get secret oauth-jass-oidc -o jsonpath='{.data.oidcClientSecret\.txt}' | base64 -d
}
```

### Generate self-signed certificates

Generate a Certificate Authority (CA) for self-signed TLS certificates:

```bash
{
  # Generate CA private key
  openssl genrsa -out ${CERTS_HOME}/ca-key.pem 2048

  # Generate CA certificate
  openssl req -new -key ${CERTS_HOME}/ca-key.pem -x509 \
    -days 1000 \
    -out ${CERTS_HOME}/ca.pem \
    -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA"
}
```

> **Note**: Review [server-domain.json](../certs/server-domain.json) for the certificate details and make any changes as needed.

Generate and verify certificate:

```sh
{
  # Generate server certificate
  echo "Generating server certificate"
  cfssl gencert -ca=${CERTS_HOME}/ca.pem \
    -ca-key=${CERTS_HOME}/ca-key.pem \
    -config=${CERTS_HOME}/ca-config.json \
    -profile=server \
    ${CERTS_HOME}/server-domain.json | cfssljson -bare ${CERTS_HOME}/server

  # Create full chain certificate
  echo "Creating full chain certificate"
  cat ${CERTS_HOME}/server.pem ${CERTS_HOME}/ca.pem > ${CERTS_HOME}/server-fullchain.pem
  echo "Verifying full chain certificate"
  openssl storeutl -noout -text -certs ${CERTS_HOME}/server-fullchain.pem | grep "Subject:"
  echo "Verifying server certificate"
  openssl x509 -in ${CERTS_HOME}/server.pem -text -noout | grep "DNS:"
}
```

Extract and combine Okta CA certificates

```bash
{
  # Check the Okta domain
  echo "OKTA_DOMAIN=${OKTA_DOMAIN}"

  # Extract Okta certificate chain
  openssl s_client -showcerts -connect ${OKTA_DOMAIN}:443 </dev/null 2>/dev/null | \
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/ {print}' > ${CERTS_HOME}/okta-cacert.pem

  # Create combined certificate chain (if ca.pem exists)
  if [ -f ${CERTS_HOME}/ca.pem ]; then
    cat ${CERTS_HOME}/ca.pem ${CERTS_HOME}/okta-cacert.pem > ${CERTS_HOME}/ca-okta.pem
    echo "Verifying certificate chain"
    openssl storeutl -noout -text -certs ${CERTS_HOME}/ca-okta.pem | grep "Subject:"
  fi
}
```

Create Kubernetes secret for the custom certificate authority and Okta CA:

```bash
{
  # Create Kubernetes secret for the custom certificate authority and Okta CA
  kubectl create secret generic tls-certs \
    --from-file=fullchain.pem=${CERTS_HOME}/server-fullchain.pem \
    --from-file=cacerts.pem=${CERTS_HOME}/ca-okta.pem \
    --from-file=privkey.pem=${CERTS_HOME}/server-key.pem

  # Extract CA certificate from secret (if needed)
  kubectl get secret tls-certs -o jsonpath='{.data.fullchain\.pem}' | base64 -d
}
```

### MDS Token Key Pair

Generate the MDS (Metadata Service) token key pair for authentication:

```bash
{
  # Generate MDS token key pair
  echo "Creating MDS token key pair in: ${CERTS_HOME}"
  openssl genrsa -out ${CERTS_HOME}/mdsTokenKeyPair.pem 2048
  openssl rsa -in ${CERTS_HOME}/mdsTokenKeyPair.pem -outform PEM -pubout -out ${CERTS_HOME}/mdsPublicKey.pem

  # Verify key pair
  openssl rsa -in ${CERTS_HOME}/mdsTokenKeyPair.pem -pubout -outform PEM | \
    openssl rsa -pubin -outform DER | openssl base64

  # Create Kubernetes secret
  kubectl create secret generic mds-token \
    --from-file=mdsPublicKey.pem=${CERTS_HOME}/mdsPublicKey.pem \
    --from-file=mdsTokenKeyPair.pem=${CERTS_HOME}/mdsTokenKeyPair.pem

  # Verify secret creation
  kubectl get secret mds-token -o jsonpath='{.data}' | jq .
}
```

## Confluent for Kubernetes Operator Deployment

Deploy the Confluent for Kubernetes operator using Helm:

```bash
{
  # Deploy CFK operator
  echo "*** Deploying CFK helm chart ***"
  helm repo add confluentinc https://packages.confluent.io/helm
  helm repo update confluentinc
  # 3.0.0 - 0.1263.8
  helm upgrade --install confluent-operator \
    confluentinc/confluent-for-kubernetes \
    --set kRaftEnabled=true \
    --version 0.1263.8

  # List deployed Helm charts
  echo "*** Helm Deployments ***"
  helm ls

  # Wait for CFK operator to be ready
  echo "*** Waiting for CFK operator to be ready ***"
  kubectl wait pod -l app.kubernetes.io/name=confluent-operator \
    --for=condition=ready --timeout=180s
}
```

## Confluent Platform Deployment

> **Note:** The Okta domain URL for **oauth** and Server S2S client IDs for **superUsers** settings need to be updated in the manifest files to reflect the correct values for the deployment. Please verify that these values match your Okta configuration before proceeding.

### Deploy CP Core

Deploy the core Confluent Platform components:

```bash
{
  # Deploy core components (KRaftController, Kafka)
  kubectl apply -f ${CP_HOME}/cp-core.yaml
  sleep 5

  # Wait for all pods to be ready
  echo "\n*** Waiting for all pods to be ready ***"
  kubectl wait --for=condition=ready pod --all --timeout=660s
  kubectl get pods
}
```

### Deploy CP Components

Deploy Confluent Platform components:

```bash
{
  # Deploy components (Connect, ksqlDB, Kafka REST Proxy, Kafka REST Class, Schema Registry, Control Center)
  kubectl apply -f ${CP_HOME}/cp-components.yaml
  sleep 5

  # Wait for all pods to be ready
  echo "\n*** Waiting for all pods to be ready ***"
  kubectl wait --for=condition=ready pod --all --timeout=660s
  kubectl get pods
}
```

### Grant RBAC Permissions for Control Center SSO

Apply RBAC configurations for user groups

> **Note:** For testing purposes, the **cfrb-c3-sa.yaml** file has been updated to grant **ResourceOwner** role to the **Everyone** default Okta group. Please verify or modify the group name and role as needed.

```bash
{
  # Apply RBAC group configuration
  kubectl apply -f ${CP_HOME}/cfrb-c3-sa.yaml

  # Verify RBAC configurations
  kubectl get -f ${CP_HOME}/cfrb-c3-sa.yaml
}
```

### Access Control Center

Access the Confluent Control Center web interface:

Open a new terminal window and run the following command to access the Control Center web interface:

```bash
{
  # Port-forward to Control Center
  kubectl port-forward svc/controlcenter 9021:9021 &
  sleep 5

  # Open Control Center in browser
  open https://localhost:9021
}
```

> **Note**: As self-signed certificate is used, click on **Advanced** and then **Proceed to localhost (unsafe)** to access the Control Center web interface to avoid browser warnings **This site is not secure** and **Your connection is not private**.

Click on `Log in via SSO` and provide email address that you provided when signing up for the Okta integrator free plan.

Navigate through different tabs to verify the deployment and the configuration.

## Okta/OAuth Client Test

Let's grant `ResourceOwner` role to the Client Client ID and Secret created earlier to test the connection to the Kafka cluster.

Grant the Client access to the topics and groups.

```bash
  {
    # Replace with the appropriate Okta Client ID
    # Apply RBAC to grant Client access to the topics and groups
    kubectl apply -f ${CP_HOME}/cfrb-client-ro.yaml

    # Verify RBAC configurations
    kubectl get -f ${CP_HOME}/cfrb-client-ro.yaml
  }
```

Execute into one of kafka pods

```bash
{
  # Execute into kafka-0 pod
  kubectl exec -it kafka-0 -c kafka -- bash
}
```

- Run the following commands to test the connection to the Kafka cluster.

  ```bash
  {
    # Replace with the appropriate Okta Client S2S Client ID and Secret and Token Endpoint
    export OKTA_TOKEN_ENDPOINT="https://integrator-4487007.okta.com/oauth2/austyga8unDE3r3c0697/v1/token"
    export KAFKA_OPTS="-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls=${OKTA_TOKEN_ENDPOINT}"
    export CLIENT_ID="0oaut4itbi0EM26kW697"
    export CLIENT_SECRET="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    echo "OKTA_TOKEN_ENDPOINT=${OKTA_TOKEN_ENDPOINT}"
    echo "CLIENT_ID=${CLIENT_ID}"
    echo "CLIENT_SECRET=${CLIENT_SECRET}"
    echo "KAFKA_OPTS=${KAFKA_OPTS}"

    # generate the client properties file
    cat <<EOF > ${HOME}/okta-client.properties
  sasl.mechanism=OAUTHBEARER
  security.protocol=SASL_SSL
  sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginCallbackHandler
  sasl.oauthbearer.token.endpoint.url=${OKTA_TOKEN_ENDPOINT}
  sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="${CLIENT_ID}" clientSecret="${CLIENT_SECRET}" scope="confluent";
  org.apache.kafka.sasl.oauthbearer.allowed.urls=*
  ssl.truststore.location=/mnt/sslcerts/truststore.p12
  ssl.truststore.password=mystorepassword
  EOF
    
    # Display the client properties file and verify the values
    cat ${HOME}/okta-client.properties
        
    BS_SERVER=kafka.confluent.svc.cluster.local:9071
    TOPIC_NAME=csg-ps-okta-test-topic-01
    CLIENT_PROP=${HOME}/okta-client.properties

    # List topics
    kafka-topics --bootstrap-server ${BS_SERVER} --list --command-config ${CLIENT_PROP}
    
    # Create topic
    kafka-topics --bootstrap-server ${BS_SERVER} --create --topic ${TOPIC_NAME} --partitions 3 --replication-factor 3 --command-config ${CLIENT_PROP}
    
    # Produce messages
    seq 1 5 | kafka-console-producer --bootstrap-server ${BS_SERVER} --topic ${TOPIC_NAME} --producer.config ${CLIENT_PROP}
    
    # Consume messages
    kafka-console-consumer --bootstrap-server ${BS_SERVER} --topic ${TOPIC_NAME} --consumer.config ${CLIENT_PROP} --from-beginning --group csg-ps-okta-group1-${TOPIC_NAME}
    
    # Exit the pod
    exit
  }
  ```

> **Note**: That's it! We have successfully tested the connection to the Kafka cluster using Okta OAuth client.

## Cleanup

> **Caution**: The cleanup process will permanently delete all Confluent Platform data and configurations.

To remove the entire Confluent Platform deployment:

```bash
{
  # Delete RBAC configurations
  kubectl delete -f ${CP_HOME}/cfrb-c3-sa.yaml -f ${CP_HOME}/cfrb-client-ro.yaml

  # Delete CP components
  kubectl delete -f ${CP_HOME}/cp-components.yaml

  # Delete CP core components
  kubectl delete -f ${CP_HOME}/cp-core.yaml

  # If RBAC are in Error state
  kubectl get cfrb
  # Force remove finalizers
  kubectl patch $(kubectl get cfrb -o name) -p '{"metadata":{"finalizers":null}}' --type=merge

  # Delete CFK operator
  helm delete confluent-operator

  # Delete namespace
  kubectl delete namespace ${CP_NS}

  # Delete CRDs (optional, affects all CFK installations)
  kubectl delete crd $(kubectl get crd | grep confluent | awk '{print $1}')
}
```
---