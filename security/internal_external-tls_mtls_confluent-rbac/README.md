# Security setup

In this workflow scenario, you'll set up a Confluent Platform cluster with the following security:
- Full TLS network encryption using both user provided certificates for external domains and auto-generated certs for internal domains
- mTLS authentication
- Confluent RBAC authorization

This scenario uses static host based routing with an ingress controller to provide external access to certain
REST based Confluent Platform components. View the [static host based routing scenario doc](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/networking/external-access-static-host-based) for a comprehensive walkthrough of that.

Before continuing with the scenario, ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites).

This scenario workflow requires the following CLI tools to be available on the machine you are using:

- openssl
- cfssl

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/internal_external-tls_mtls_confluent-rbac
```
  
## Deploy Confluent for Kubernetes

Set up the Helm Chart:

```
helm repo add confluentinc https://packages.confluent.io/helm
```

Install Confluent For Kubernetes using Helm:

```
helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace confluent
```
  
Check that the Confluent For Kubernetes pod comes up and is running:

```
kubectl get pods --namespace confluent
```

## Deploy OpenLDAP

This repo includes a Helm chart for [OpenLdap](https://github.com/osixia/docker-openldap). The chart `values.yaml`
includes the set of principal definitions that Confluent Platform needs for RBAC.

Deploy OpenLdap:

```
helm upgrade --install -f $TUTORIAL_HOME/../../assets/openldap/ldaps-rbac.yaml test-ldap $TUTORIAL_HOME/../../assets/openldap --namespace confluent
```

Validate that OpenLDAP is running:  

```
kubectl get pods --namespace confluent
```

Log in to the LDAP pod:

```
kubectl --namespace confluent exec -it ldap-0 -- bash

# Run the LDAP search command
ldapsearch -LLL -x -H ldap://ldap.confluent.svc.cluster.local:389 -b 'dc=test,dc=com' -D "cn=mds,dc=test,dc=com" -w 'Developer!'

# Exit out of the LDAP pod
exit
```

## Create TLS certificates

In this scenario, you'll configure authentication using the mTLS mechanism. With mTLS, Confluent components and clients use TLS certificates for authentication. The certificate has a CN that identifies the principal name.
     
## Deploy configuration secrets

You'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.
   
To support the above deployment scenario, you need to provide the following
credentials:

* Component TLS Certificates

* Authentication credentials for Zookeeper, Kafka, Control Center, remaining CP components

* RBAC principal credentials

In this scenario, you'll use both:
-  auto-generated certificates for internal network encryption
-  user provided certificates for external network encryption

### Configure auto-generated certificates

Confluent For Kubernetes provides auto-generated certificates for Confluent Platform
components to use for TLS network encryption. You'll need to generate and provide a
Certificate Authority (CA).

Generate a CA pair to use:

```
openssl genrsa -out $TUTORIAL_HOME/ca-key.pem 2048

openssl req -new -key $TUTORIAL_HOME/ca-key.pem -x509 \
  -days 1000 \
  -out $TUTORIAL_HOME/ca.pem \
  -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Operator/CN=TestCA"
```

Create a Kubernetes secret for the certificate authority:

```
kubectl create secret tls ca-pair-sslcerts \
  --cert=$TUTORIAL_HOME/ca.pem \
  --key=$TUTORIAL_HOME/ca-key.pem -n confluent
```

### Provide external component TLS certificates for Kafka

In this scenario, you'll be allowing Kafka clients to connect with Kafka through the external-to-Kubernetes network.

For that purpose, you'll provide a server certificate that secures the external domain used for Kafka access.

```
# If you dont have one, create a root certificate authority for the external component certs
openssl genrsa -out $TUTORIAL_HOME/externalRootCAkey.pem 2048

openssl req -x509  -new -nodes \
  -key $TUTORIAL_HOME/externalRootCAkey.pem \
  -days 3650 \
  -out $TUTORIAL_HOME/externalCacerts.pem \
  -subj "/C=US/ST=CA/L=MVT/O=TestOrg/OU=Cloud/CN=TestCA"

# Create Kafka server certificates
cfssl gencert -ca=$TUTORIAL_HOME/externalCacerts.pem \
-ca-key=$TUTORIAL_HOME/externalRootCAkey.pem \
-config=$TUTORIAL_HOME/../../assets/certs/ca-config.json \
-profile=server $TUTORIAL_HOME/kafka-server-domain.json | cfssljson -bare $TUTORIAL_HOME/kafka-server

```

Provide the certificates to Kafka through a Kubernetes Secret:

```
kubectl create secret generic tls-kafka \
  --from-file=fullchain.pem=$TUTORIAL_HOME/kafka-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/externalCacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/kafka-server-key.pem \
  --namespace confluent
```

### Provide authentication credentials

Create a Kubernetes secret object for Control Center.

This secret object contains file based properties. These files are in the
format that each respective Confluent component requires for authentication
credentials.

```   
kubectl create secret generic credential \
  --from-file=basic.txt=$TUTORIAL_HOME/creds-control-center-users.txt \
  --from-file=ldap.txt=$TUTORIAL_HOME/ldap.txt \
  --namespace confluent
```

### Provide RBAC principal credentials

Create a Kubernetes secret object for MDS:

```
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../assets/certs/mds-publickey.txt \
  --from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../assets/certs/mds-tokenkeypair.txt \
  --namespace confluent
   
# Kafka RBAC credential
kubectl create secret generic mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/kafka-client.txt \
  --namespace confluent
# Control Center RBAC credential
kubectl create secret generic c3-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/c3-mds-client.txt \
  --namespace confluent
# Connect RBAC credential
kubectl create secret generic connect-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/connect-mds-client.txt \
  --namespace confluent
# Schema Registry RBAC credential
kubectl create secret generic sr-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/sr-mds-client.txt \
  --namespace confluent
# ksqlDB RBAC credential
kubectl create secret generic ksqldb-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/ksqldb-mds-client.txt \
  --namespace confluent
# Kafka REST credential
kubectl create secret generic rest-credential \
  --from-file=bearer.txt=$TUTORIAL_HOME/kafka-client.txt \
  --from-file=basic.txt=$TUTORIAL_HOME/kafka-client.txt \
  --namespace confluent
```

## Deploy Confluent Platform

Deploy Confluent Platform:

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform-mtls-rbac.yaml --namespace confluent
```

Check that all Confluent Platform resources are deployed:

```
kubectl get pods --namespace confluent
```

If any component does not deploy, it could be due to missing configuration information in secrets.
The Kubernetes events will tell you if there are any issues with secrets. For example:

```
kubectl get events --namespace confluent
Warning  KeyInSecretRefIssue  kafka/kafka  required key [ldap.txt] missing in secretRef [credential] for auth type [ldap_simple]
```

The default required RoleBindings for each Confluent component are created
automatically, and maintained as `confluentrolebinding` custom resources.

```
kubectl get confluentrolebinding --namespace confluent
```

## Create RBAC Rolebindings for Control Center admin

Create Control Center Role Binding for a Control Center `testadmin` user.

```
kubectl apply -f $TUTORIAL_HOME/controlcenter-testadmin-rolebindings.yaml --namespace confluent
```

# Configure External Access through Ingress Controller

The Ingress Controller will support TLS encryption. For this, you'll need to provide a server certificate
to use for encypting traffic.

```
# Generate a server certificate from the external root certificate authority
cfssl gencert -ca=$TUTORIAL_HOME/externalCacerts.pem \
-ca-key=$TUTORIAL_HOME/externalRootCAkey.pem \
-config=$TUTORIAL_HOME/../../assets/certs/ca-config.json \
-profile=server $TUTORIAL_HOME/ingress-server-domain.json | cfssljson -bare $TUTORIAL_HOME/ingress-server

kubectl create secret tls tls-nginx-cert \
  --cert=$TUTORIAL_HOME/ingress-server.pem \
  --key=$TUTORIAL_HOME/ingress-server-key.pem \
  --namespace confluent
```

## Install the Nginx Ingress Controller

```
# Add the Kubernetes NginX Helm repo and update the repo
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install the Nginx controller
helm upgrade  --install ingress-nginx ingress-nginx/ingress-nginx
```

## Create Ingress Resources

Create internal bootstrap services for each Confluent Platform component that will round-robin route to each
components' server pods.

```
# Create Confluent Platform component bootstrap services
kubectl apply -f $TUTORIAL_HOME/connect-bootstrap-service.yaml
kubectl apply -f $TUTORIAL_HOME/ksqldb-bootstrap-service.yaml
kubectl apply -f $TUTORIAL_HOME/mds-bootstrap-service.yaml
```

Create an Ingress resource that includes a collection of rules that the Ingress controller uses to route the inbound 
traffic to each Confluent Platform component. These will point to the bootstrap services created above.

In the resource file, `$TUTORIAL_HOME/ingress-service-hostbased.yaml`, replace `mydomain.com` with the value of your
external domain.

```
# Create the Ingress resource:
kubectl apply -f $TUTORIAL_HOME/ingress-service-hostbased.yaml
```

## Set up DNS

Create DNS records for Confluent Platform component HTTP endpoints using the ingress controller load balancer externalIP.

```
# Retrieve the external IP addresses of the ingress load balancer:
kubectl get svc
NAME                                 TYPE           CLUSTER-IP     EXTERNAL-IP       PORT(S)
...
ingress-nginx-controller             LoadBalancer   10.98.82.133   104.197.186.121   80:31568/TCP,443:31295/TCP
```

| DNS name | IP address |
| -------- | ---------- |
| controlcenter.mydomain.com | The `EXTERNAL-IP` value of the ingress load balancer service |
| connect.mydomain.com | The `EXTERNAL-IP` value of the ingress load balancer service |
| ksqldb.mydomain.com | The `EXTERNAL-IP` value of the ingress load balancer service |

## Validate

### Validate in Control Center

Use Control Center to monitor the Confluent Platform, and see the created topic
and data. You can visit the external URL you set up for Control Center, or visit the URL
through a local port forwarding like below:

Set up port forwarding to Control Center web UI from local machine:

```
kubectl port-forward controlcenter-0 9021:9021 --namespace confluent
```

Browse to Control Center. You will log in as the `testadmin` user, with `testadmin` password.

```
https://localhost:9021
```

The `testadmin` user (`testadmin` password) has the `SystemAdmin` role granted and will have access to the
cluster and broker information.

### Validate component REST Access

You should be able to access the REST endpoint over the external domain name.

Use curl to access ksqldb cluster status. Provide the certificates you created to authenticate:

```
curl -sX GET "https://ksqldb.mydomain.com:443/clusterStatus" --cacert $TUTORIAL_HOME/externalCacerts.pem --key $TUTORIAL_HOME/kafka-server-key.pem --cert $TUTORIAL_HOME/kafka-server.pem
```

### Validate MDS Access

```
confluent login \
 --url https://mds.mydomain.com \
 --ca-cert-path $TUTORIAL_HOME/externalCacerts.pem

```

## Tear down

```
kubectl delete confluentrolebinding --all --namespace confluent
  
kubectl delete -f $TUTORIAL_HOME/confluent-platform-mtls-rbac.yaml --namespace confluent

kubectl delete secret rest-credential ksqldb-mds-client sr-mds-client connect-mds-client c3-mds-client mds-client --namespace confluent

kubectl delete secret mds-token --namespace confluent

kubectl delete secret credential --namespace confluent

kubectl delete secret tls-kafka --namespace confluent

helm delete test-ldap --namespace confluent

helm delete operator --namespace confluent
```

## Appendix: Troubleshooting

### Gather data to troubleshoot

```
# Check for any error messages in events
kubectl get events --namespace confluent

# Check for any pod failures
kubectl get pods --namespace confluent

# For pod failures, check logs
kubectl logs <pod-name> --namespace confluent
```
