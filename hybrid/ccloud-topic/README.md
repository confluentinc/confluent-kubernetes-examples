# Create and manage topic on Confluent Cloud 

You can use Confluent for Kubernetes to create, edit, and delete the topic on Confluent Cloud.

Before continuing with the scenario, ensure that you have set up the
[prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites).

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:
```   
export TUTORIAL_HOME=<Tutorial directory>/hybrid/ccloud-topic
```  

## Deploy Confluent for Kubernetes

Set up the Helm Chart:
```
 helm repo add confluentinc https://packages.confluent.io/helm
```

Install Confluent for Kubernetes using Helm:
```
helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace confluent
```

Check that the Confluent for Kubernetes pod comes up and is running:
```     
kubectl get pods --namespace confluent
```

## Create authentication credentials

Confluent Cloud provides an API key/secret for Kafka. Create a Kubernetes secret object for Confluent Cloud Kafka access.
This secret object contains file based properties. 
```
kubectl create secret generic cloud-rest-access \
  --from-file=basic.txt=$TUTORIAL_HOME/creds-kafka-sasl-user.txt --namespace confluent
```

## Create Kafka Topic

Edit the ``topic.yaml`` custom resource file, and update the details in the following places:

- ``<rest-endpoint>`` : Admin REST APIs endpoint.
- ``<cluster-id>`` : ID of the Confluent Cloud Kafka cluster

Create the Kafka topic: 
```
kubectl apply -f $TUTORIAL_HOME/topic.yaml
```

## Update Kafka Topic

You can update the editable settings of the topic in the topic CR, `topic.yaml`. To update the kafka topic config, add the config under `spec.configs` in the kafka topic custom resource file, apply the changes using the `kubectl apply -f topic.yaml` command.

Limitations:

- [Custom topic settings for all cluster types](https://docs.confluent.io/cloud/current/clusters/broker-config.html#custom-topic-settings-for-all-cluster-types)
- You cannot update topics with the `_` character in the topic name.
- `spec.replicas` and `spec.partitionCount` cannot be updated using KafkaTopic CR.

## Validate

### Validate in Confluent Cloud Console

- Sign in to your Confluent account.
- If you have more than one environment, select an environment.
- Select a cluster from the navigation bar and click the `Topics` menu. 
- The Topics page displays the created topic
- Select the created topic, and view the `Configuration` of the topic from the Confluent Cloud Console.

## Tear down

- This command will delete the topic: 
```
kubectl delete -f $TUTORIAL_HOME/test.yaml
```

- Delete the secret: 
```
kubectl delete secrets cloud-rest-access --namespace confluent
```

- Uninstall the operator  
```
helm delete operator --namespace confluent
```