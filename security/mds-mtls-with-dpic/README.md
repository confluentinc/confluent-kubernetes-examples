# Managing sensitive credentials and certificates in HashiCorp Vault

Confluent for Kubernetes provides the ability to securely provide sensitive credentials/certificates to the Confluent Platform deployment. Confluent for Kubernetes supports the following two mechanisms for this:
- Kubernetes Secrets: Provide sensitive credentials/certificates as a Kubernetes Secret, and reference the Kubernetes Secret in the Confluent Platform component CustomResource.
- Directory path in container: Inject the sensitive credentials/certificates into the Confluent Platform component pod and on a directory path in the container. Reference the directory path in the Confluent Platform component CustomResource.

This scenario example describes how to set up and use the Directory path in container approach with Hashicorp Vault to pass certs in RBAC enabled mTLS cluster.

Set the tutorial directory for this scenario example under the directory you downloaded
the tutorial files:

```   
$ export TUTORIAL_HOME=<This_Git_repository_directory>/security/mds-mtls-with-dpic
$ kubectl create namespace confluent
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
The `confluent-sa` Service Account will be associated with our deployment of Confluent Platform,
enabling it to access the secrets that we stored in Vault.

## Write credentials in Vault

In this next set of steps, you will take Confluent Platform credentials and store them in Vault.

Copy the MDS credential files to a directory in the Vault pod. In
this scenario example, you'll use `/tmp` as the parent directory. You can change this
as desired.

```
$ kubectl -n hashicorp cp $TUTORIAL_HOME/../../assets/certs/mds-publickey.txt vault-0:/tmp
$ kubectl -n hashicorp cp $TUTORIAL_HOME/../../assets/certs/mds-tokenkeypair.txt vault-0:/tmp
```

Open an interactive shell session in the Vault container:

```
$ kubectl exec -it vault-0 -n hashicorp -- /bin/sh
```

Write the credentials to Vault:
```
cat /tmp/mds-publickey.txt | base64 | vault kv put /secret/mdsPublicKey.pem mdspublickey=-
cat /tmp/mds-tokenkeypair.txt | base64 | vault kv put /secret/mdsTokenKeyPair.pem mdstokenkeypair=-
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

In this scenario, you'll configure authentication using the mTLS mechanism. With mTLS, Confluent components and clients use TLS certificates for authentication. The certificate has a CN that identifies the principal name.

Each Confluent component service should have its own TLS certificate. In this scenario, you'll
generate a server certificate for each Confluent component service. In this next set of steps, you will generate TLS certificates, create keystores
and truststores, and store them in Vault. If you have your own TLS certificates, substitute
those in to the commands. Follow [these instructions](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/assets/certs/component-certs/README.md) to generate these certificates.

```
cd $TUTORIAL_HOME

# Generate the kraft keystore

sh $TUTORIAL_HOME/../../scripts/create-keystore-mtls.sh  \
$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kraft-server.pem \
$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kraft-server-key.pem mystorepassword kraftkeystore

# Generate the kafka keystore

sh $TUTORIAL_HOME/../../scripts/create-keystore-mtls.sh  \
$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server.pem \
$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server-key.pem mystorepassword kafkakeystore

# Generate the schema registry keystore

sh $TUTORIAL_HOME/../../scripts/create-keystore-mtls.sh  \
$TUTORIAL_HOME/../../assets/certs/component-certs/generated/schemaregistry-server.pem \
$TUTORIAL_HOME/../../assets/certs/component-certs/generated/schemaregistry-server-key.pem mystorepassword srkeystore

# Generate the rest proxy keystore

sh $TUTORIAL_HOME/../../scripts/create-keystore-mtls.sh  \
$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafkarestproxy-server.pem \
$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafkarestproxy-server-key.pem mystorepassword krpkeystore

# Generate the connect keystore

sh $TUTORIAL_HOME/../../scripts/create-keystore-mtls.sh  \
$TUTORIAL_HOME/../../assets/certs/component-certs/generated/connect-server.pem \
$TUTORIAL_HOME/../../assets/certs/component-certs/generated/connect-server-key.pem mystorepassword connectkeystore

# Generate the control center keystore

sh $TUTORIAL_HOME/../../scripts/create-keystore-mtls.sh  \
$TUTORIAL_HOME/../../assets/certs/component-certs/generated/controlcenter-server.pem \
$TUTORIAL_HOME/../../assets/certs/component-certs/generated/controlcenter-server-key.pem mystorepassword c3keystore

# Generate the truststore

sh $TUTORIAL_HOME/../../scripts/create-truststore.sh  \
$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
mystorepassword

# PEM certs for Kafka Rest Class. Only the PEM format is supported for Admin REST.
cp $TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem $TUTORIAL_HOME/jks
cp $TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server.pem $TUTORIAL_HOME/jks
cp $TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server-key.pem $TUTORIAL_HOME/jks

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
cat /tmp/jks/kraftkeystore.jks | base64 | vault kv put /secret/kraftkeystore.jks keystore=-
cat /tmp/jks/kafkakeystore.jks | base64 | vault kv put /secret/kafkakeystore.jks keystore=-
cat /tmp/jks/srkeystore.jks | base64 | vault kv put /secret/srkeystore.jks keystore=-
cat /tmp/jks/krpkeystore.jks | base64 | vault kv put /secret/krpkeystore.jks keystore=-
cat /tmp/jks/connectkeystore.jks | base64 | vault kv put /secret/connectkeystore.jks keystore=-
cat /tmp/jks/c3keystore.jks | base64 | vault kv put /secret/c3keystore.jks keystore=-
cat /tmp/jks/truststore.jks | base64 | vault kv put /secret/truststore.jks truststore=-
cat /tmp/jks/cacerts.pem | base64 | vault kv put /secret/cacerts.pem cacerts=-
cat /tmp/jks/kafka-server.pem | base64 | vault kv put /secret/fullchain.pem fullchain=-
cat /tmp/jks/kafka-server-key.pem | base64 | vault kv put /secret/privkey.pem privkey=-
vault kv put secret/jksPassword.txt password=jksPassword=mystorepassword
```

## Provide file based credentials

* Create a Kubernetes secret object for external users, which can be used for C3 login.

This secret object contains file based username/password. They kubernetes secret should have key "userstore.txt"
The users must be added in the format <username>:<password>

```
kubectl create secret generic file-secret \
--from-file=userstore.txt=$TUTORIAL_HOME/fileUserPassword.txt \
-n confluent
```


## Deploy Confluent for Kubernetes

```
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes -f $TUTORIAL_HOME/helm-values.yaml -n confluent
```

helm-values.yaml will use pod annotations to store CP component certificates injected by vault secrets in CFK pod.
These certificates are required to create internal rolebindings.
`confluent-sa` serviceAccount is also created via helm install of CFK.

## Deploy Confluent Platform with mTLS RBAC

Deploy Confluent Platform, using pod annotations to configure each component
to use credentials and certificate stores injected by Vault:

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform.yaml
```

Looking at `$TUTORIAL_HOME/confluent-platform.yaml` for each CP component
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

```
metadata:
  name: kafka
  annotations:
    platform.confluent.io/dpic-append-path: "kafka"
```

The above annotation is added to avoid any path or file name collisions between the component server secrets in CFK pod.

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


## Tear Down

This set of commands will remove all Kubernetes objects that you created in this scenario. This
will in turn delete the Confluent Platform and Confluent for Kubernetes deployment.

```
kubectl delete confluentrolebinding --all -n confluent

kubectl delete -f $TUTORIAL_HOME/confluent-platform.yaml

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


