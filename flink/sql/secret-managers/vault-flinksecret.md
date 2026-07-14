# HashiCorp Vault → FlinkSecret

With Vault, use the **Vault Secrets Operator (VSO)**, which syncs a Vault path into a
real Kubernetes Secret — exactly what a FlinkSecret's `spec.secretRef` needs.

> Note: the repo's existing Vault example, [`security/configure-with-vault`](../../../security/configure-with-vault),
> uses the **vault-agent-injector**, which mounts secrets as files *inside a pod*.
> That pattern fits CP components that read `directoryPathInContainer`, but a
> FlinkSecret needs a named Kubernetes Secret object, so VSO is the right fit here.

## Steps (adapt to your cluster)

1. Install VSO and configure Kubernetes auth + a KV v2 mount in Vault. See
   https://developer.hashicorp.com/vault/docs/platform/k8s/vso

2. Write the credentials to Vault:

   ```bash
   vault kv put secret/flink/connection \
     schema.registry.basic.auth.user.info='sr-user:sr-password' \
     sasl.jaas.config="org.apache.kafka.common.security.plain.PlainLoginModule required username='kafka-user' password='kafka-password';"
   ```

3. Apply a `VaultStaticSecret` that produces the SAME Secret the FlinkSecret
   references (`flink-connection-credentials`):

   ```yaml
   apiVersion: secrets.hashicorp.com/v1beta1
   kind: VaultStaticSecret
   metadata:
     name: flink-connection-credentials
     namespace: operator
   spec:
     type: kv-v2
     mount: secret
     path: flink/connection
     refreshAfter: 1h
     destination:
       create: true
       name: flink-connection-credentials   # matches FlinkSecret spec.secretRef
   ```

The `FlinkSecret` in [`../sql/flinksecret.yaml`](../sql/flinksecret.yaml) is
unchanged — drop the inline `Secret` and let VSO own `flink-connection-credentials`.
On rotation, VSO updates the Secret and CFK re-syncs CMF automatically.
