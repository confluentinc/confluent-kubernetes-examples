# Create and manage schema on Confluent Cloud 

You can use Confluent for Kubernetes to create, edit, and delete the schema on Confluent Cloud.

Before continuing with the scenario, ensure that you have set up the
[prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites).

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:
```
export TUTORIAL_HOME=<Tutorial directory>/hybrid/ccloud-schema
```

## Deploy Confluent for Kubernetes

Set up the Helm Chart:
```
helm repo add confluentinc https://packages.confluent.io/helm
```

Create a namespace for the Confluent Platform deployment:
```
kubectl create namespace confluent
```

Install Confluent for Kubernetes using Helm:
```
helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace confluent
```

Check that the Confluent for Kubernetes pod comes up and is running:
```
kubectl get pods --namespace confluent
```

## Schema Registry service account permissions

The service account used for Schema Registry API keys must have the following roles assigned on the Schema Registry resource (All schema subjects `*`):

| Role | Resource | Resource Type |
|---|---|---|
| `ResourceOwner` | `*` (All schema subjects) | Schema subject |
| `DeveloperWrite` | `*` (All schema subjects) | Schema subject |
| `DeveloperRead` | `*` (All schema subjects) | Schema subject |

## Create authentication credentials

The `creds-schema-user.txt` file should contain your Confluent Cloud Schema Registry credential.
Update the file with your Confluent Cloud Schema Registry credential.

Confluent Cloud provides an API key/secret for Schema Registry. Create a Kubernetes secret object for Confluent Cloud Schema Registry access.
This secret object contains file based properties. 
```
kubectl create secret generic schema-registry-access \
  --from-file=basic.txt=$TUTORIAL_HOME/creds-schema-user.txt --namespace confluent
```

## Create the ConfigMap for the schema

Apply the ConfigMap containing the Avro schema definition:
```
kubectl apply -f $TUTORIAL_HOME/mycfk-schema-configCM.yaml
```

## Create Schema

Edit the `schema.yaml` custom resource file, and update the details in the following places:

- `<schema-registry-endpoint>` : Schema Registry REST APIs endpoint. You can find this in the Confluent Cloud Console under your environment's Schema Registry settings (e.g., `https://psrc-XXXXX.region.provider.confluent.cloud`).

Create the schema: 
```bash
kubectl apply -f $TUTORIAL_HOME/schema.yaml
```

## Validate

### Validate in the kubectl context

```bash
kubectl get schema -n confluent
```

You should see the schema in the output.
```bash
❯ kubectl get schema -n confluent

NAME                        FORMAT   ID       VERSION   STATUS      AGE
mycfk-schema-config-value   avro     100002   1         SUCCEEDED   34s
```

### Validate in Confluent Cloud Console

- Sign in to your Confluent Cloud account.
- If you have more than one environment, select an environment.
- Select Schema Registry from the navigation bar and click the `Data Contracts` menu. 
- The Data Contracts page displays the created schema.
- Select the created schema to view the schema details.

Use the `versions` endpoint to get the list of versions for the schema. You should see the version `1` in the output.
```bash
curl -u <schema-api-key>:<schema-api-secret> https://<schema-registry-endpoint>/subjects/mycfk-schema-config-value/versions
```

Use the `versions/{version}/schema` endpoint to get the schema for a specific version.
```bash
curl -u <schema-api-key>:<schema-api-secret> https://<schema-registry-endpoint>/subjects/mycfk-schema-config-value/versions/1/schema
```

## Tear down

- This command will delete the schema: 
```bash
kubectl delete -f $TUTORIAL_HOME/schema.yaml
```

- Delete the schema registry access secret: 
```bash
kubectl delete secrets schema-registry-access --namespace confluent
```

- Delete the schema config map: 
```bash
kubectl delete configmap mycfk-schema-config --namespace confluent
```

- Uninstall the operator  
```bash
helm delete operator --namespace confluent
```

- Delete the namespace:
```bash
kubectl delete namespace confluent
```