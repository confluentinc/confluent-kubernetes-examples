# Security setup

In this workflow scenario, you'll set up a Confluent Platform cluster with the following security:
- Full TLS network encryption with user provided certificates
- mTLS authentication on MDS Server for RBAC, along with mTLS on all cp components
- File Based User Store in MDS for Confluent Control Center user credentials

# Managing user store credentials in HashiCorp Vault
In this example, we will use secret stored in vault for file based User Store in MDS

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/mds-mtls-with-vault
```


## Configure Hashicorp Vault

Note: Hashicorp Vault is a third party software product that is not supported or distributed by Confluent. In this scenario, you will deploy and configure Hashicorp Vault in a way to support this scenario. There are multiple ways to configure and use Hashicorp Vault - follow their product docs for that information.

### Install Vault

Using the Helm Chart, install the latest version of the Vault server running in development mode to a namespace `hashicorp`.

Running a Vault server in development is automatically initialized and unsealed. This is ideal in a learning environment, but not recommended for a production environment.

```
kubectl create ns hashicorp

helm repo add hashicorp https://helm.releases.hashicorp.com
helm upgrade --install vault --set='server.dev.enabled=true' hashicorp/vault -n hashicorp
```

Once installed, you should see two pods:

```
kubectl get pods -n hashicorp
NAME                                    READY   STATUS    RESTARTS   AGE
vault-0                                 1/1     Running   0          23s
vault-agent-injector-85b7b88795-q5vcp   1/1     Running   0          24s
```


### Initialize Vault authentication

Open an interactive shell session in the Vault container:

```
kubectl exec -it vault-0 -n hashicorp -- /bin/sh
```

Instruct Vault to treat Kubernetes as a trusted identity provider for authentication to Vault:

```
/ $ vault auth enable kubernetes
```

Configure Vault to know how to connect to the Kubernetes API (the API of the very same Kubernetes cluster where Vault is deployed) to authenticate requests made to Vault by a principal whose identity is tied to Kubernetes, such as a Kubernetes Service Account.

```
/ $ vault write auth/kubernetes/config \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```


### Configure Vault Policy

Create a Vault policy file for all secrets stored in path `/secret/`:

```
cat <<EOF > $TUTORIAL_HOME/app-policy.hcl
path "secret*" {
capabilities = ["read"]
}
EOF
```

Copy the app policy file to the Vault pod:

```
## Coopy the file to the /tmp location on the Vault pod disk
kubectl -n hashicorp cp $TUTORIAL_HOME/app-policy.hcl vault-0:/tmp
```

Open an interactive shell session in the Vault container and apply the policy:

```
kubectl exec -it vault-0 -n hashicorp -- /bin/sh

/ $ vault write sys/policy/app policy=@/tmp/app-policy.hcl
```

Then, grant the `confluent-sa` Service Account access to all secrets stored in path `/secret`
by binding it to the above policy. We’ll create the Service Account in the following step
when we prepare to deploy Confluent Platform, but we can perform the policy binding now
while we’re still in the Vault shell:

```
vault write auth/kubernetes/role/confluent-operator \
    bound_service_account_names=confluent-sa \
    bound_service_account_namespaces=confluent \
    policies=app \
    ttl=24h
```

## Create confluent Namespace
```
kubectl create namespace confluent
kubectl create serviceaccount confluent-sa -n confluent
```

## Deploy Confluent for Kubernetes

* Set up the Helm Chart:
```
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
```

* Install Confluent For Kubernetes using Helm:
```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes -n confluent
```

The `confluent-sa` Service Account will be associated with our deployment of Confluent Platform,
enabling it to access the secrets that we stored in Vault.

## Write credentials in Vault

In this next set of steps, you will take user store credentials and store them in Vault.

The file $TUTORIAL_HOME/fileUserPassword.txt contains file based username/password.
The users must be added in the format <username>:<password>
For your deployment, you'll edit these files to incorporate your credentials.

Copy the credential files directory and its contents to a directory in the Vault pod. In
this scenario example, you'll use `/tmp` as the parent directory. You can change this
as desired.
```
kubectl -n hashicorp cp $TUTORIAL_HOME/fileUserPassword.txt vault-0:/tmp
```
Open an interactive shell session in the Vault container:

```
kubectl exec -it vault-0 -n hashicorp -- /bin/sh
```

Write the credentials to Vault:

```
cat /tmp/fileUserPassword.txt | base64 | vault kv put /secret/fileuser.txt fileuser=-
```

## Create TLS certificates

In this scenario, you'll configure authentication using the mTLS mechanism. With mTLS, Confluent components and clients use TLS certificates for authentication. The certificate has a CN that identifies the principal name.

Each Confluent component service should have its own TLS certificate. In this scenario, you'll
generate a server certificate for each Confluent component service. Follow [these instructions](../../assets/certs/component-certs/README.md) to generate these certificates.

## Deploy configuration secrets

You'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.

To support the above deployment scenario, you need to provide the following
credentials:

* Component TLS Certificates. The principal extracted from these certificates will be used for Authentication

* File Based User Credentials

* RBAC principal credentials

You can either provide your own certificates, or generate test certificates. Follow instructions
in the below `Appendix: Create your own certificates` section to see how to generate certificates
and set the appropriate SANs.


## Provide component TLS certificates

```
kubectl create secret generic tls-kraft \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kraft-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kraft-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-kafka \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-controlcenter \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/controlcenter-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/controlcenter-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-schemaregistry \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/schemaregistry-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/schemaregistry-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-connect \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/connect-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/connect-server-key.pem \
  --namespace confluent
  
kubectl create secret generic tls-kafkarestproxy \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafkarestproxy-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafkarestproxy-server-key.pem \
  --namespace confluent

```

## Provide RBAC principal credentials

* Create a Kubernetes secret object for MDS:

```
kubectl create secret generic mds-token \
--from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../assets/certs/mds-publickey.txt \
--from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../assets/certs/mds-tokenkeypair.txt \
-n confluent
```

## Deploy Confluent Platform

* Deploy Confluent Platform
```
kubectl apply -f $TUTORIAL_HOME/confluent-platform.yaml
```

* Check that all Confluent Platform resources are deployed:

```
kubectl get pods -n confluent
```

## Create RBAC Rolebindings for Control Center user

```
kubectl apply -f $TUTORIAL_HOME/controlcenter-rolebinding.yaml
```

## Validate

### Validate in Control Center

Use Control Center to monitor the Confluent Platform. You can visit the external URL you set up for Control Center, or visit the URL through a local port forwarding like below:

* Set up port forwarding to Control Center web UI from local machine:

```
kubectl port-forward controlcenter-0 9021:9021 -n confluent
```

* Browse to Control Center, use the credentials testuser1 as user, and password1 as password to login to Control Center.
```
https://localhost:9021
```

## Tear down

```
kubectl delete confluentrolebinding --all -n confluent
kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml -n confluent
kubectl delete secret mds-token -n confluent
kubectl delete secret tls-kafka tls-connect tls-schemaregistry tls-kafkarestproxy tls-controlcenter --namespace confluent
helm delete confluent-operator -n confluent
helm delete vault -n hashicorp
```

## Appendix: Troubleshooting

In this scenario, for each Kafka component pod, there will be multiple containers included:

- CP component container (for example `kafka`)
- Vault agent (`vault-agent`)
- CP component init container (`config-init-container`)
- Vault agent init container (`vault-agent-init`)

To get logs for debugging, you'll need to specify the container name. For example, to get
`kafka` pod containerlogs:

```
kubectl logs kafka-0 -c vault-agent-init
kubectl logs kafka-0 -c kafka
kubectl logs kafka-0 -c vault-agent
```

## Appendix: Create your own certificates

When testing, it's often helpful to generate your own certificates to validate the architecture and deployment. You'll want both these to be represented in the certificate SAN:

* external domain names
* internal Kubernetes domain names
* Install libraries on Mac OS

The internal Kubernetes domain name depends on the namespace you deploy to. If you deploy to confluent namespace, then the internal domain names will be:
* .kraftcontroller.confluent.svc.cluster.local
* .kafka.confluent.svc.cluster.local
* .confluent.svc.cluster.local

Create your certificates by following the steps:
* Install libraries on Mac OS
```
brew install cfssl
```
* Create Certificate Authority
```
mkdir $TUTORIAL_HOME/../../assets/certs/generated && cfssl gencert -initca $TUTORIAL_HOME/../../assets/certs/ca-csr.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/ca -
```
* Validate Certificate Authority
```
openssl x509 -in $TUTORIAL_HOME/../../assets/certs/generated/ca.pem -text -noout
```
* Create server certificates with the appropriate SANs (SANs listed in server-domain.json)
```
cfssl gencert -ca=$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
-ca-key=$TUTORIAL_HOME/../../assets/certs/generated/ca-key.pem \
-config=$TUTORIAL_HOME/../../assets/certs/ca-config.json \
-profile=server $TUTORIAL_HOME/../../assets/certs/server-domain.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/server
``` 

* Validate server certificate and SANs
```
openssl x509 -in $TUTORIAL_HOME/../../assets/certs/generated/server.pem -text -noout
```
