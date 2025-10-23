# C3_SSO_setup_cfk
This involves setting up IDP (Azure Entra ID ) & Service Provider (Confluent Platform kafka Cluster)

Steps to configure SSO using OIDC based IDP Azure Entra ID for C3 deployed via CFK  referring :

 [Configure single sign-on (SSO) using OpenID Connect (OIDC) | Confluent Documentation  
](https://docs.confluent.io/platform/current/security/authentication/sso-for-c3/configure-sso-using-oidc.html#configuration-prerequisites-and-process)

 [Configure Authentication for Confluent Platform Components Using Confluent for Kubernetes | Confluent Documentation](https://docs.confluent.io/operator/current/co-authenticate-cp.html#co-authenticate-c3-sso
) 

# Setup IDP (Identity Provider) Azure EntraID 


# Step 1 - Establish trust between the IdP and Confluent Platform

You can sign up with a free trial on Azure  Microsoft Azure 

# 1.1 Register OIDC client Application (Add Redirect URi once the CFK cluster is deployed )

<img width="1292" height="961" alt="Register an application" src="https://github.com/user-attachments/assets/5f37ae45-d28e-4796-8359-ae68b6364632" />


# 1.2 Create Client Secret

<img width="1367" height="669" alt="unknown" src="https://github.com/user-attachments/assets/0e6318de-c7e4-4e3e-a6d7-fa54073c06ef" />


# 1.3 Add group claims in Token Configuration.

<img width="1715" height="898" alt="unknown" src="https://github.com/user-attachments/assets/f1c1b530-39f5-4a99-b48a-11b037614dbe" />


# 1.4 Capture IDP endpoints required to fetch, authorize, and verify tokens from OpenID Connect metadata document URL

https://login.microsoftonline.com/0893715b-959b-4906-a185-2789e1ead045/v2.0/.well-known/openid-configuration

Token endpoint URL (token_endpoint) 

Authorization endpoint URL (authorization_endpoint)

JSON Web Key Set (JWKS) URL (jwks_uri)

Issuer URL (issuer)

Example: 

````
token_endpoint":"https://login.microsoftonline.com/0893715b-959b-4906-a185-2789e1ead045/oauth2/v2.0/token
authorization_endpoint":"https://login.microsoftonline.com/0893715b-959b-4906-a185-2789e1ead045/oauth2/v2.0/authorize
jwks_uri":"https://login.microsoftonline.com/0893715b-959b-4906-a185-2789e1ead045/discovery/v2.0/keys
issuer":"https://login.microsoftonline.com/0893715b-959b-4906-a185-2789e1ead045/v2.0
`````
  
# 1.5 Add Redirect URI in Azure Entra ID once the kafka cluster is deployed .

Control Center can be accessed on controlcenter-0-internal service or if C3 is deployed for external access; ExternalIp can be used.

The URL should follow this format:

````
https://<c3-hostname>:<c3-port>/api/metadata/security/1.0/oidc/authorization-code/callback

Example: 
https://localhost:9021/api/metadata/security/1.0/oidc/authorization-code/callback

````

![image](https://github.com/user-attachments/assets/81020af1-cba5-44b9-b5f9-c928ca4203fb)

# Deploy CFK cluster (Service Provider)


# Step 2 - Enable SSO using OIDC on Confluent Control Center and Metadata Service (MDS)

# Deploy kraft based CFK cluster using referring example : https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/security/control-center-sso

In this Example setup the Kafka CR is configured with MDS and LDAP as the MDS identity provider.

# Prerequisites:

a. Create a K8s cluster on any cloud provider (AKS/EKS/GKE) 

b. A namespace created in the Kubernetes cluster - confluent

Kubectl configured to target the confluent namespace:

```
kubectl config set-context --current --namespace=confluent
```

Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/control-center-sso
```

# 2.1 Deploy Confluent for Kubernetes

Set up the Helm Chart:

```
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
```

Install Confluent For Kubernetes using Helm:
```
helm upgrade --install operator confluentinc/confluent-for-kubernetes --set kRaftEnabled=true -n confluent
```
Check that the Confluent for Kubernetes pod comes up and is running:

```
kubectl get pods -n confluent
```

# 2.2 Deploy OpenLDAP

This repo includes a Helm chart for OpenLdap. The chart values.yaml includes the set of principal definitions that Confluent Platform needs for RBAC.
```
helm upgrade --install -f $TUTORIAL_HOME/../../assets/openldap/ldaps-rbac.yaml test-ldap $TUTORIAL_HOME/../../assets/openldap --namespace confluent
```
Validate that OpenLDAP is running:
```
kubectl get pods -n confluent
```

# 2.3 Deploy configuration secrets

Provide component TLS certificates

The [Azure IDP certs](https://learn.microsoft.com/en-us/azure/security/fundamentals/tls-certificate-changes#what-change) should to be imported in MDS truststore

Convert the certificates to .pem

````
openssl x509 -in DigiCertGlobalRootG2.crt -out DigiCertGlobalRootG2.pem -outform PEM
openssl x509 -in DigiCertGlobalRootCA.crt -out DigiCertGlobalRootCA.pem -outform PEM
openssl x509 -in DigiCertGlobalRootG3.crt -out DigiCertGlobalRootG3.pem -outform PEM
openssl x509 -in DigiCertTLSECCP384RootG5.crt -out DigiCertTLSECCP384RootG5.pem -outform PEM
openssl x509 -in DigiCertTLSRSA4096RootG5.crt  -out DigiCertTLSRSA4096RootG5.pem -outform PEM
openssl x509 -in Microsoft RSA Root Certificate Authority 2017.crt -out Microsoft RSA Root Certificate Authority 2017.pem -outform PEM
openssl x509 -in 'Microsoft ECC Root Certificate Authority 2017.crt' -out 'Microsoft ECC Root Certificate Authority 2017.pem’ -outform PEM
````
Concat all .pem file to a single file.
````
cat 'DigiCertGlobalRootG2.pem' 'DigiCertGlobalRootCA.pem' 'DigiCertGlobalRootG3.pem' 'DigiCertTLSECCP384RootG5.pem' 'DigiCertTLSRSA4096RootG5.pem' 'Microsoft RSA Root Certificate Authority 2017.pem' 'Microsoft ECC Root Certificate Authority 2017.pem' 'D-TRUST_Root_Class_3_CA_2_2009.pem' >> Azure_idp.pem
````
You can create your own certs by following : https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/security/control-center-sso#appendix-create-your-own-certificates

# Add Azure IDP certs to ca.pem 
```
cd $TUTORIAL_HOME/../../assets/certs/generated/
cat ~/Downloads/Azure_idp.pem >> ca.pem
````
# Generate Secret to provide TLS certificates
```
kubectl create secret generic tls-group1 \
--from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/generated/server.pem \
--from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
--from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/generated/server-key.pem \
-n confluent
```
# Provide authentication credentials

Edit $TUTORIAL_HOME/oidcClientSecret.txt to add the ClientId / ClientSecret generated in 

# Create Client Secret 
```
clientId=e7d240c4-5735-43b2-a746-963001eba90e
clientSecret=<xxx>
```
# Create a Kubernetes secret object for KraftController, Kafka, and Control Center.
```
kubectl create secret generic credential \
--from-file=plain-users.json=$TUTORIAL_HOME/creds-kafka-sasl-users.json \
--from-file=plain.txt=$TUTORIAL_HOME/creds-client-kafka-sasl-user.txt \
--from-file=ldap.txt=$TUTORIAL_HOME/ldap.txt \
--from-file=oidcClientSecret.txt=$TUTORIAL_HOME/oidcClientSecret.txt \
-n confluent
```
# Provide RBAC principal credentials

# Create a Kubernetes secret object for MDS:

````
kubectl create secret generic mds-token \
--from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../assets/certs/mds-publickey.txt \
--from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../assets/certs/mds-tokenkeypair.txt \
-n confluent
````
# Create Kafka RBAC credential

````
kubectl create secret generic mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
-n confluent
````
# Create Control Center RBAC credential

```
kubectl create secret generic c3-mds-client \
--from-file=bearer.txt=$TUTORIAL_HOME/c3-mds-client.txt \
-n confluent
````
# Create Kafka REST credential

````
kubectl create secret generic rest-credential \
--from-file=bearer.txt=$TUTORIAL_HOME/bearer.txt \
--from-file=basic.txt=$TUTORIAL_HOME/bearer.txt \
-n confluent
````
# 2.4 Deploy Confluent Platform

Add SSO configs derived from Step 1.5 to $TUTORIAL_HOME/confluent-platform.yaml

Capture IDP endpoints required to fetch, authorize, and verify tokens from OpenID Connect metadata document URL

https://login.microsoftonline.com/0893715b-959b-4906-a185-2789e1ead045/v2.0/.well-known/openid-configuration

Token endpoint URL (token_endpoint) : 

Authorization endpoint URL (authorization_endpoint)

JSON Web Key Set (JWKS) URL (jwks_uri)

Issuer URL (issuer)

# Deploy Kafka Cluster

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform.yaml
````
Check that all Confluent Platform resources are deployed:

```
kubectl get pods -n confluent
```

Check C3 pods logs to check for the User: principal 

```
kubectl logs controlcenter-0 -n confluent | grep "User:"
```

Sample logs 
````
[INFO] 2025-03-06 13:48:22,610 [qtp766446793-231] io.confluent.rest-utils.requests write - 10.16.0.5 - ZdpHlzTwv2DCnYJRMsWCeeXE6F4kUooA0d7qflmAui4 [06/Mar/2025:13:48:22 +0000] "POST /security/1.0/lookup/principals/User:ZdpHlzTwv2DCnYJRMsWCeeXE6F4kUooA0d7qflmAui4/visibility HTTP/1.1" 200 139 "-" "Jetty/9.4.54.v20240208" requestTime-16 httpStatusCode-200
[INFO] 2025-03-06 13:48:22,612 [qtp766446793-227] io.confluent.rest-utils.requests write - 10.16.0.5 - ZdpHlzTwv2DCnYJRMsWCeeXE6F4kUooA0d7qflmAui4 [06/Mar/2025:13:48:22 +0000] "POST /security/1.0/lookup/principals/User:ZdpHlzTwv2DCnYJRMsWCeeXE6F4kUooA0d7qflmAui4/visibility HTTP/1.1" 200 139 "-" "Jetty/9.4.54.v20240208" requestTime-20 httpStatusCode-200
````
# 2.5 Add the Role Bindings to principal in controlcenter-rolebinding.yaml

Example :

```
---
apiVersion: platform.confluent.io/v1beta1
kind: ConfluentRolebinding
metadata:
  name: c3-user-rb
  namespace: confluent
spec:
  principal:
    type: user
    name: ZdpHlzTwv2DCnYJRMsWCeeXE6F4kUooA0d7qflmAui4
  role: SystemAdmin
````
```
kubectl apply -f  $TUTORIAL_HOME/controlcenter-rolebinding.yaml
```
Set up port forwarding to Control Center web UI from local machine:
````

kubectl port-forward controlcenter-0 9021:9021 -n confluent
````

Access C3 URL to login via SSO:
```
https://localhost:9021
```
  
C3 UI should be successfully accessible via SSO.




