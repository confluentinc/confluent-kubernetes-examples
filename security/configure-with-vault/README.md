# Managing sensitive credentials and configurations in HashiCorp Vault

Confluent for Kubernetes provides the ability to securely provide sensitive credentials/configurations to the Confluent Platform deployment. Confluent for Kubernetes supports the following two mechanisms for this:
- Kubernetes Secrets: Provide sensitive credentials/configurations as a Kubernetes Secret, and reference the Kubernetes Secret in the Confluent Platform component CustomResource.
- Directory path in container: Inject the sensitive credentials/configurations into the Confluent Platform component pod and on a directory path in the container. Reference the directory path in the Confluent Platform component CustomResource.

This scenario example describes how to set up and use the Directory path in container approach with Hashicorp Vault.

Set the tutorial directory for this scenario example under the directory you downloaded
the tutorial files:

```   
$ export TUTORIAL_HOME=<Tutorial directory>/security/configure-with-vault
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

Create a Vault policy file:

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
kubectl -n confluent cp $TUTORIAL_HOME/app-policy.hcl vault-0:/tmp
```

Exec in to the Vault pod and apply the policy:

```
kubectl -n confluent exec -it vault-0 sh

vault write sys/policy/app policy=@/tmp/app-policy.hcl
```

### Configure Vault permissions

Exec into the Vault pod:

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
vault write auth/kubernetes/role/confluent-operator bound_service_account_names=default \ bound_service_account_namespaces=operator policies=app ttl=1h
```

