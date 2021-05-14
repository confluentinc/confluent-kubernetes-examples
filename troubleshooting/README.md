# Troubleshoot Confluent for Kubernetes

This document provides information on troubleshooting your Confluent deployment process.

<ol>
<li> 
If the Kafka Cluster Roll is blocked (can be seen in Confluent Operator logs or from the Kafka CR status). 
   This can happen for many reasons, such as pods not being in a running state or due to some network issue. To overcome this issue, run the following command:
   
    kubectl -n <namespace> annotate kafka <name-of-kafka-cluster> platform.confluent.io/roll-metadata-
</li>
<li>

If Kubernetes resources cannot be deleted, i.e. if Confluent Operator pod gets deleted before other resources, if operator
   can’t delete resources, or if the namespace is in termination state etc. Use the following command to remove the finalizer:

     kubectl -n <namespace> get <resource> --no-headers | awk '{print $1 }' | xargs kubectl -n <namespace> patch <resource> -p '{"metadata":{"finalizers":[]}}' --type=merge
</li>
<li>

If all the pods require manual deletion (NOT RECOMMENDED) then run the following command:

      kubectl -n <namespace> delete pod -l platform.confluent.io/type=<cr-type> 

where `<cr-type>` can be one of the following: `kafka/zookeeper/schemaregistry/ksqldb/connect/controlcenter`

`Note:` If a pod is already in `crashloopback` state, then the Confluent Operator will not honor the changes until pod goes back to the running state. You can also use `--force --grace-period=0` with the above command.
Please use caution when deleting Kafka pod as it will trigger data loss.
</li>
<li> 

If you want to block reconciliation (useful to control the upgrade path), add following annotations:

<b>Add</b>

      kubectl -n <namespace> annotate <cr-type> <cluster_name> platform.confluent.io/block-reconcile=true


<b>Remove</b> (if you forget to remove, then subsequent changes on the APIs will be ignored)

      kubectl -n <namespace> annotate <cr-type> <cluster_name> platform.confluent.io/block-reconcile-

<li>

Confluent Operator uses a watch model for the resources it creates. If for some reason you want to force trigger the reconciliation then 
   add the following annotation:

      kubectl -n <namespace> annotate <cluster-type> <cluster_name> platform.confluent.io/force-reconcile=true

After the reconcile is triggered, this annotation will be disabled automatically. This command is useful in situation where
the auto-generated certificate is expired and requires the Operator to be notified to create a new certificate.
</li>
<li>

You can ignore the following `Warning` as the Confluent Operator will automatically rework to apply the changes. 
   In most scenarios, these are benign and will go away (no more logs). 
   If you keep seeing the same type of `Warning` repeatedly, you should create a support ticket for further investigation.

`Operation cannot be fulfilled xxxx, the object has been modified please apply your changes to the latest version and try again`
</li>
<li>

 If CP RBAC enabled Kafka Cluster is deleted and redeployed with same cluster name. Then, all the existing `ConfluentRolebindings` are still associated with previous Kafka Cluster. To make existing `ConfluentRolebindings` sync with new Kafka cluster, you need to manually delete the `KafkaRestClass` and recreate it again.
</li>
<li>

If `ConfluentRolebindings` are stuck in `DELETING` state (occurs if associated Kafka cluster is removed). 
   You need to manually remove the finalizer for these `ConfluentRolebindings`.

Example

```yaml
$ kubectl get cfrb
 NAME                        STATUS     KAFKACLUSTERID           PRINCIPAL        ROLE             KAFKARESTCLASS            AGE
c3-connect-operator-7gffem   DELETING   8itASw0_S6qDfdl72b7Uyg   User:c3          SystemAdmin      operator-7gffem/default   7d19h
c3-ksql-operator-7gffem      DELETING   8itASw0_S6qDfdl72b7Uyg   User:c3          ResourceOwner    operator-7gffem/default   7d19h
c3-operator-7gffem           DELETING   8itASw0_S6qDfdl72b7Uyg   User:c3          ClusterAdmin     operator-7gffem/default   7d19h
c3-sr-operator-7gffem        DELETING   8itASw0_S6qDfdl72b7Uyg   User:c3          SystemAdmin      operator-7gffem/default   7d19h
connect-operator-7gffem-0    DELETING   8itASw0_S6qDfdl72b7Uyg   User:connect     SystemAdmin      operator-7gffem/default   7d19h
connect-operator-7gffem-1    DELETING   8itASw0_S6qDfdl72b7Uyg   User:connect     SystemAdmin      operator-7gffem/default   7d19h
internal-connect-0           DELETING   8itASw0_S6qDfdl72b7Uyg   User:connect     SecurityAdmin    operator-7gffem/default   7d19h
internal-connect-1           DELETING   8itASw0_S6qDfdl72b7Uyg   User:connect     ResourceOwner    operator-7gffem/default   7d19h
internal-connect-2           DELETING   8itASw0_S6qDfdl72b7Uyg   User:connect     DeveloperWrite   operator-7gffem/default   7d19h
```

    for rb in $(kubectl n <namespace> get cfrb --no-headers | grep "DELETING" | awk '{print $1}'); do kubectl -n <namespace>  patch cfrb $rb -p '{"metadata":{"finalizers":[]}}' --type=merge; done

If you are trying to remove the finalizer for all the `ConfluentRolebindings` resources in a namespace (no matter their status; for example, when the namespace stuck in terminating state and need to clean up all the `ConfluentRolebindings`), then run the following command: 

    for rb in $(kubectl -n <namespace> get cfrb --no-headers -ojsonpath='{.items[*].metadata.name}'); do kubectl -n <namespace>  patch cfrb $rb -p '{"metadata":{"finalizers":[]}}' --type=merge; done

Add your namespace in `<namespace>` when running the above command.
</li>
<li>

For a Kafka CR API, two different listeners can’t share the same TLS secret reference. If configured, it will impact the volume mount path and `statefulset` will fail. Always use global TLS if you need to share TLS configuration.
</li>
<li>

KafkaTopic deletion (`kubectl delete kafkatopic <topic-name>`) uses Kubernetes finalizer feature to remove topic from the destination Kafka cluster through Kafka Rest API. If finalizer fails to delete because of network issue or unavailable of kafka clusters (deleted), the kubectl delete command will hang. In this scenario patch the `kafkatopic` with following commands that will remove the topic resource.

    kubectl -n <namespace> patch kafkatopic <topic-name> -p '{"metadata":{"finalizers":[]}}' --type=merge

</li>
</ol>
