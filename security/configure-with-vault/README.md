# Managing sensitive credentials and certificates in HashiCorp Vault

Confluent for Kubernetes provides the ability to securely provide sensitive credentials/certificates to the Confluent Platform deployment. Confluent for Kubernetes supports the following two mechanisms for this:
- Kubernetes Secrets: Provide sensitive credentials/certificates as a Kubernetes Secret, and reference the Kubernetes Secret in the Confluent Platform component CustomResource.
- Directory path in container: Inject the sensitive credentials/certificates into the Confluent Platform component pod and on a directory path in the container. Reference the directory path in the Confluent Platform component CustomResource.

This scenario example describes how to set up and use the Directory path in container approach with Hashicorp Vault.

Set the tutorial directory for this scenario example under the directory you downloaded
the tutorial files:

```   
$ export TUTORIAL_HOME=<This_Git_repository_directory>/security/configure-with-vault
```

## Configure Hashicorp Vault

Note: Hashicorp Vault is a third party software product that is not supported or distributed by Confluent. In this scenario, you will deploy and configure Hashicorp Vault in a way to support this scenario. There are multiple ways to configure and use Hashicorp Vault - follow their product docs for that information.

### Install Vault

Using the Helm Chart, install the latest version of the Vault server running in development mode to a namespace `hashicorp`.

Running a Vault server in development is automatically initialized and unsealed. This is ideal in a learning environment, but not recomended for a production environment. 

```
$ kubectl create ns hashicorp

$ helm repo add hashicorp https://helm.releases.hashicorp.com
$ helm upgrade --install vault --set='server.dev.enabled=true' hashicorp/vault --namespace hashicorp
```

Once installed, you should see two pods:

```
$ kubectl get pods -n hashicorp
NAME                                    READY   STATUS    RESTARTS   AGE
vault-0                                 1/1     Running   0          23s
vault-agent-injector-85b7b88795-q5vcp   1/1     Running   0          24s
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
$ kubectl --namespace hashicorp cp $TUTORIAL_HOME/app-policy.hcl vault-0:/tmp
```

Open an interactive shell session in the Vault container and apply the policy:

```
$ kubectl exec -it vault-0 --namespace hashicorp -- /bin/sh

/ $ vault write sys/policy/app policy=@/tmp/app-policy.hcl
```

### Configure Vault permissions

Open an interactive shell session in the Vault container:

```
$ kubectl exec -it vault-0 --namespace hashicorp -- /bin/sh
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

Create role name `confluent-operator` to map k8s namespace confluent for the given default service account to use Vault policy `app`:

```
vault write auth/kubernetes/role/confluent-operator bound_service_account_names=default \ bound_service_account_namespaces=confluent policies=app ttl=1h
```


## Write credentials in Vault

In this next set of steps, you will take Confluent Platform credentials and store them in Vault.

The directory $TUTORIAL_HOME/credentials contains all the credentials required by a 
Confluent Platform deployment. For your deployment, you'll edit these files to incorporate
your credentials.

This scenario example document does not explain the credentials and their format. To understand
that, read our Security docs and read the two main security tutorials:
- https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/security/production-secure-deploy
- https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/security/secure-authn-encrypt-deploy

Copy the credential files directory and its contents to a directory in the Vault pod. In 
this scenario example, you'll use `/tmp` as the parent directory. You can change this 
as desired.

```
$ kubectl --namespace hashicorp cp $TUTORIAL_HOME/credentials vault-0:/tmp
```

Open an interactive shell session in the Vault container:

```
$ kubectl exec -it vault-0 --namespace hashicorp -- /bin/sh
```

Write the credentials to Vault:

```
/ $
cat /tmp/credentials/controlcenter/basic-server.txt | base64 | vault kv put /secret/controlcenter/basic.txt basic=-
cat /tmp/credentials/connect/basic-server.txt | base64 | vault kv put /secret/connect/basic.txt basic=-
cat /tmp/credentials/connect/basic-client.txt | base64 | vault kv put /secret/connect-client/basic.txt basic=-
cat /tmp/credentials/schemaregistry/basic-server.txt | base64 | vault kv put /secret/schemaregistry/basic.txt basic=-
cat /tmp/credentials/schemaregistry/basic-client.txt | base64 | vault kv put /secret/schemaregistry-client/basic.txt basic=-
cat /tmp/credentials/ksqldb/basic-server.txt | base64 | vault kv put /secret/ksqldb/basic.txt basic=-
cat /tmp/credentials/ksqldb/basic-client.txt | base64 | vault kv put /secret/ksqldb-client/basic.txt basic=-
cat /tmp/credentials/zookeeper-server/digest-jaas.conf | base64 | vault kv put /secret/zookeeper/digest-jaas.conf digest=-
cat /tmp/credentials/kafka-client/plain-jaas.conf | base64 | vault kv put /secret/kafka-client/plain-jaas.conf plainjaas=-
cat /tmp/credentials/kafka-server/plain-jaas.conf | base64 | vault kv put /secret/kafka-server/plain-jaas.conf plainjaas=-
cat /tmp/credentials/kafka-server/apikeys.json | base64 | vault kv put /secret/kafka-server/apikeys.json apikeys=-
cat /tmp/credentials/kafka-server/digest-jaas.conf | base64 | vault kv put /secret/kafka-server/digest-jaas.conf digestjaas=-
cat /tmp/credentials/license.txt | base64 | vault kv put /secret/license.txt license=-
vault kv put secret/jksPassword.txt password=jksPassword=mystorepassword
```

## Write certificate stores in Vault

Each Confluent Platform component requires a keystore and truststore to be created and 
configured.

When you use the Kubernetes Secrets method to provide TLS certificates, Confluent for Kubernetes
will automate creating and configuring the keystore and truststore.

When you use the "Directory path in container" mechanism, which you'll need to use if you
are using Vault to provide the TLS certificate information, then Confluent for Kubernetes
does not automate the creation of keystore and truststore. You'll need to create the keystore and
truststore first.

In this next set of steps, you will generate TLS certificates, create keystores 
and truststores, and store them in Vault. If you have your own TLS certificates, substitute 
those in to the commands.

```
# Create Certificate Authority

cfssl gencert -initca $TUTORIAL_HOME/../../assets/certs/ca-csr.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/ca -

# Create server certificates with the appropriate SANs (SANs listed in server-domain.json)
cfssl gencert -ca=$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
-ca-key=$TUTORIAL_HOME/../../assets/certs/generated/ca-key.pem \
-config=$TUTORIAL_HOME/../../assets/certs/ca-config.json \
-profile=server $TUTORIAL_HOME/../../assets/certs/server-domain.json | cfssljson -bare $TUTORIAL_HOME/../../assets/certs/generated/server

# Generate the keystore

cd $TUTORIAL_HOME
sh $TUTORIAL_HOME/../../scripts/create-keystore.sh  \
$TUTORIAL_HOME/../../assets/certs/generated/server.pem \
$TUTORIAL_HOME/../../assets/certs/generated/server-key.pem mystorepassword

# Generate the truststore

sh $TUTORIAL_HOME/../../scripts/create-truststore.sh  \
$TUTORIAL_HOME/../../assets/certs/generated/ca.pem \
mystorepassword
```

Copy the jks files directory and its contents to a directory in the Vault pod. In 
this scenario example, you'll use `/tmp` as the parent directory. You can change this 
as desired.

```
$ kubectl --namespace hashicorp cp $TUTORIAL_HOME/jks vault-0:/tmp
```

Open an interactive shell session in the Vault container:

```
$ kubectl exec -it vault-0 --namespace hashicorp -- /bin/sh
```

Write the certificate stores to Vault:

```
/ $
cat /tmp/jks/keystore.jks | base64 | vault kv put /secret/keystore.jks keystore=-
cat /tmp/jks/truststore.jks | base64 | vault kv put /secret/truststore.jks truststore=-
```


## Deploy Confluent Platform (without RBAC)

Read the main scenario example documentation to understand the concepts:
https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/security/production-secure-deploy

Deploy Confluent Platform, using pod annotations to configure each component 
to use credentials and certificate stores injected by Vault:

- Certificates Retrieval
- SASL_SSL users
- Basic Authentication for all CP Component
- License configured for all CP component (not using the Operator license)

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform-norbac-vault.yaml --namespace confluent
```

## Deploy Confluent Platform (with RBAC)

Read the main scenario example documentation to understand the concepts:
https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/security/production-secure-deploy

There's two differences when using Directory path in container mechanism:

- You'll need to create a KafkaRetstClass with a Kubernetes secret for the credentials.
  Confluent for Kubernetes 2.0.x does not support using directory path in container for 
  this specific credential
- You'll need to apply the required rolebindings for each component. 

