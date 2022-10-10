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

Running a Vault server in development is automatically initialized and unsealed. This is ideal in a learning environment, but not recommended for a production environment.

```
$ kubectl create ns hashicorp

$ helm repo add hashicorp https://helm.releases.hashicorp.com
$ helm upgrade --install vault --set='server.dev.enabled=true' hashicorp/vault -n hashicorp
```

Once installed, you should see two pods:

```
$ kubectl get pods -n hashicorp
NAME                                    READY   STATUS    RESTARTS   AGE
vault-0                                 1/1     Running   0          23s
vault-agent-injector-85b7b88795-q5vcp   1/1     Running   0          24s
```


### Initialize Vault authentication

Open an interactive shell session in the Vault container:

```
$ kubectl exec -it vault-0 -n hashicorp -- /bin/sh
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
$ kubectl -n hashicorp cp $TUTORIAL_HOME/app-policy.hcl vault-0:/tmp
```

Open an interactive shell session in the Vault container and apply the policy:

```
$ kubectl exec -it vault-0 -n hashicorp -- /bin/sh

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


## Deploy Confluent for Kubernetes


```
kubectl create namespace confluent
kubectl create serviceaccount confluent-sa -n confluent
```

```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes
```

The `confluent-sa` Service Account will be associated with our deployment of Confluent Platform, 
enabling it to access the secrets that we stored in Vault.


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
$ kubectl -n hashicorp cp $TUTORIAL_HOME/credentials vault-0:/tmp
$ kubectl -n hashicorp cp $TUTORIAL_HOME/../../assets/certs/mds-publickey.txt vault-0:/tmp/credentials/rbac/
$ kubectl -n hashicorp cp $TUTORIAL_HOME/../../assets/certs/mds-tokenkeypair.txt vault-0:/tmp/credentials/rbac/
```

Open an interactive shell session in the Vault container:

```
$ kubectl exec -it vault-0 -n hashicorp -- /bin/sh
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

```
cat /tmp/credentials/rbac/mds-publickey.txt | base64 | vault kv put /secret/mds-publickey.txt mdspublickey=-
cat /tmp/credentials/rbac/mds-tokenkeypair.txt | base64 | vault kv put /secret/mds-tokenkeypair.txt mdstokenkeypair=-
cat /tmp/credentials/rbac/ldap.txt | base64 | vault kv put /secret/ldap.txt ldapsimple=-
cat /tmp/credentials/rbac/mds-client-connect.txt | base64 | vault kv put /secret/connect/bearer.txt bearer=-
cat /tmp/credentials/rbac/mds-client-controlcenter.txt | base64 | vault kv put /secret/controlcenter/bearer.txt bearer=-
cat /tmp/credentials/rbac/mds-client-kafka-rest.txt | base64 | vault kv put /secret/kafka/bearer.txt bearer=-
cat /tmp/credentials/rbac/mds-client-ksql.txt | base64 | vault kv put /secret/ksqldb/bearer.txt bearer=-
cat /tmp/credentials/rbac/mds-client-schemaregistry.txt | base64 | vault kv put /secret/schemaregistry/bearer.txt bearer=-
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
$ kubectl -n hashicorp cp $TUTORIAL_HOME/jks vault-0:/tmp
```

Open an interactive shell session in the Vault container:

```
$ kubectl exec -it vault-0 -n hashicorp -- /bin/sh
```

Write the certificate stores to Vault:

```
/ $
cat /tmp/jks/keystore.jks | base64 | vault kv put /secret/keystore.jks keystore=-
cat /tmp/jks/truststore.jks | base64 | vault kv put /secret/truststore.jks truststore=-
```


## Deploy Confluent Platform (without RBAC)

Read the main scenario example documentation to understand the concepts:
https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/security/secure-authn-encrypt-deploy

Deploy Confluent Platform, using pod annotations to configure each component 
to use credentials and certificate stores injected by Vault:

- Certificates Retrieval
- SASL_SSL users
- Basic Authentication for all CP Component
- License configured for all CP component (not using the Operator license)

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform-norbac-vault.yaml -n confluent
```

Looking at `$TUTORIAL_HOME/confluent-platform-norbac-vault.yaml` for each CP component 
CustomResource (CR), these are the configuration snippets that are relevant to this 
scenario:

```
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
spec:
  ...
  podTemplate:
    serviceAccountName: confluent-sa
    ...
```

The above CR snippet binds Kafka to the service account `confluent-sa`, which is the service account that is 
authorized to read credentials from Vault.

```
podTemplate:
    ...
    annotations:
      vault.hashicorp.com/agent-inject: "true"
      vault.hashicorp.com/agent-inject-status: update
      vault.hashicorp.com/preserve-secret-case: "true"
      vault.hashicorp.com/agent-inject-secret-jksPassword.txt: secret/jksPassword.txt
      vault.hashicorp.com/agent-inject-template-jksPassword.txt: |
        {{- with secret "secret/jksPassword.txt" -}}
        {{ .Data.data.password }}
        {{- end }}
      ...
      vault.hashicorp.com/role: confluent-operator
```

The above annotations will trigger all the magic that will result in the Vault secrets 
being written to an in-memory filesystem dynamically mounted to the Confluent Platform 
component worker container. The format of the files will match what’s required by 
Confluent Platform.


## Deploy Confluent Platform (with RBAC)

Read the main scenario example documentation to understand the concepts:
https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/security/production-secure-deploy

Note: There are two differences from the above scenario, when using "Directory in path container":

- You'll need to use Kubernetes secrets for the KafkaRestClass authentication. Confluent for Kubernetes 
2.0.x does not support using directory path in container for this specific credential. Instructions for
how to do this are immediately below.
- You'll need to apply the RBAC rolebindings for the CP components. These will not be created 
automatically. You'll do this by applying the CustomResources defined in 
`$TUTORIAL_HOME/rbac/internal-rolebinding.yaml`, in a later step in this scenario workflow.

Create a KafkaRestClass object with a user that has cluster access to create rolebindings 
for Confluent Platform RBAC. In this scenario, that is user `kafka`:

```
kubectl -n confluent create secret generic rest-credential \
  --from-file=bearer.txt=$TUTORIAL_HOME/credentials/rbac/kafkarestclass/bearer.txt

kubectl -n confluent apply -f $TUTORIAL_HOME/rbac/kafka-rest.yaml
```

### Deploy OpenLDAP

This repo includes a Helm chart for [OpenLdap](https://github.com/osixia/docker-openldap). 
The chart `values.yaml` includes the set of principal definitions that Confluent Platform 
needs for RBAC.

Deploy OpenLDAP:

```
helm upgrade --install -f $TUTORIAL_HOME/../../assets/openldap/ldaps-rbac.yaml test-ldap $TUTORIAL_HOME/../../assets/openldap -n confluent
```

Validate that OpenLDAP is running:  

```
kubectl get pods -n confluent
```

### Deploy Confluent Platform

Deploy Zookeeper and Kafka first:

```
kubectl apply -f $TUTORIAL_HOME/rbac/zk_kafka.yaml -n confluent
```

Create the RBAC Rolebindings needed for the CP components:

```
kubectl apply -f $TUTORIAL_HOME/rbac/internal-rolebinding.yaml -n confluent
```

Deploy the CP components:

```
kubectl apply -f $TUTORIAL_HOME/rbac/cp_component.yaml -n confluent
```


## Tear Down

This set of commands will remove all Kubernetes objects that you created in this scenario. This
will in turn delete the Confluent Platform and Confluent for Kubernetes deployment.

```
kubectl delete -f $TUTORIAL_HOME/confluent-platform-norbac-vault.yaml -n confluent

kubectl delete -f $TUTORIAL_HOME/rbac/cp_component.yaml -n confluent

kubectl delete -f $TUTORIAL_HOME/rbac/internal-rolebinding.yaml -n confluent

kubectl delete -f $TUTORIAL_HOME/rbac/kafka-rest.yaml -n confluent

kubectl delete -f $TUTORIAL_HOME/rbac/rbac/zk_kafka.yaml -n confluent

kubectl delete secret rest-credential -n confluent

helm delete test-ldap -n confluent

helm delete confluent-operator -n confluent

helm delete vault -n hashicorp

```

## Appendix: Troubleshooting

In this scenario, for each Confluent Platform component pod, there will be multiple containers included:

- CP component container (for example `connect`)
- Vault agent (`vault-agent`)
- CP component init container (`config-init-container`)
- Vault agent init container (`vault-agent-init`)

To get logs for debugging, you'll need to specify the container name. For example, to get 
`connect` pod containerlogs:

```
kubectl logs connect-0 -c vault-agent-init
kubectl logs connect-0 -c connect
kubectl logs connect-0 -c vault-agent
```

If your pod is stuck in the init container state, then it might help to re-deploy the CP component:

```
kubectl delete -f component.yaml

kubectl apply -f component.yaml
```


