# Troubleshoot Confluent for Kubernetes

This topic provides information about troubleshooting your Confluent deployment.

<ol>
<li> 
For some reason, the Kafka Cluster Roll is blocked (can be seen in the Operator logs or from the Kafka CR status). 
   It can happen for many reasons - pods are not in a running state, network issue. To overcome the issue, run the following command
   
    kubectl -n <namespace> annotate kafka <name-of-kafka-cluster> platform.confluent.io/roll-metadata-
</li>
<li>

If for some reason, Kubernetes resources cannot be deleted: Confluent Operator pod got deleted before other resources, operator
   can’t delete resources, the namespace is in termination state etc . Use the following command to remove the finalizer.

     kubectl -n <namespace> get <resource> --no-headers | awk '{print $1 }' | xargs kubectl -n <namespace> patch <resource> -p '{"metadata":{"finalizers":[]}}' --type=merge
</li>
<li>

If for some reason all the pods requires manual deletion (NOT RECOMMENDED) then run the following command.

      kubectl -n <namespace> delete pod -l platform.confluent.io/type=<cr-type> 

where `<cr-type>` can be one of the following: `kafka/zookeeper/schemaregistry/ksqldb/connect/controlcenter`

Note: If a pod is already in `crashloopback` statue then  operator will not honor the changes till pod goes back to 
the running state:  can happen either waiting for the Kubernetes scheduler or use `--force --grace-period=0` with above command.
Please use cation for kafka pod as it will trigger the data loss.
</li>
<li> 

If you want to block the reconcile, mostly useful to control the upgrade path, then add following annotations

<b>Add</b>

      kubectl -n <namespace> annotate <cr-type> <cluster_name> platform.confluent.io/block-reconcile=true


<b>Remove</b> (If you forget to remove then subsequent changes on the APIs will be ignored)

      kubectl -n <namespace> annotate <cr-type> <cluster_name> platform.confluent.io/block-reconcile-

<li>

Confluent Operator uses a watch model for the resources it creates. If for some reason you want to force trigger the reconcile then 
   add the following annotations

      kubectl -n <namespace> annotate <cluster-type> <cluster_name> platform.confluent.io/force-reconcile=true

After the reconcile is triggered, the above annotations will be disabled. This command is mostly useful in situation like
the auto-generated certificate is expired and required to notify operator to create new one.
</li>
<li>

You can ignore following `Warning` as Confluent Operator will automatically rework again to apply the changes. 
   In most of the scenario these are benign and will go away (no more logs). 
   If you keep seeing the same type of `Warning` again and again you should create a support ticket for further investigation.

`Operation cannot be fulfilled xxxx, the object has been modified please apply your changes to the latest version and try again`
</li>
<li>

 If CP RBAC enabled Kafka Cluster is torn down and then redeployed with same cluster name. All the existing `ConfluentRolebindings` are still associated with previous Kafka Cluster. To make existing `ConfluentRolebindings` to be synced with new Kafka cluster you need to manually delete the `KafkaRestClass` and recreated it again.
</li>
<li>

If `ConfluentRolebindings` are stuck in `DELETING` state (mostly happens if associated kafka cluster is removed) 
   then you need to manually remove the finalizer for these `ConfluentRolebindings`.

Example

```yaml
$ kubectl get cfrb
NAMESPACE         NAME                         STATUS     KAFKACLUSTERID           PRINCIPAL        ROLE             KAFKARESTCLASS            AGE
operator-7gffem   c3-connect-operator-7gffem   DELETING   8itASw0_S6qDfdl72b7Uyg   User:c3          SystemAdmin      operator-7gffem/default   7d19h
operator-7gffem   c3-ksql-operator-7gffem      DELETING   8itASw0_S6qDfdl72b7Uyg   User:c3          ResourceOwner    operator-7gffem/default   7d19h
operator-7gffem   c3-operator-7gffem           DELETING   8itASw0_S6qDfdl72b7Uyg   User:c3          ClusterAdmin     operator-7gffem/default   7d19h
operator-7gffem   c3-sr-operator-7gffem        DELETING   8itASw0_S6qDfdl72b7Uyg   User:c3          SystemAdmin      operator-7gffem/default   7d19h
operator-7gffem   connect-operator-7gffem-0    DELETING   8itASw0_S6qDfdl72b7Uyg   User:connect     SystemAdmin      operator-7gffem/default   7d19h
operator-7gffem   connect-operator-7gffem-1    DELETING   8itASw0_S6qDfdl72b7Uyg   User:connect     SystemAdmin      operator-7gffem/default   7d19h
operator-7gffem   internal-connect-0           DELETING   8itASw0_S6qDfdl72b7Uyg   User:connect     SecurityAdmin    operator-7gffem/default   7d19h
operator-7gffem   internal-connect-1           DELETING   8itASw0_S6qDfdl72b7Uyg   User:connect     ResourceOwner    operator-7gffem/default   7d19h
operator-7gffem   internal-connect-2           DELETING   8itASw0_S6qDfdl72b7Uyg   User:connect     DeveloperWrite   operator-7gffem/default   7d19h
```

     for rb in $(kubectl n <namespace> get cfrb | grep "DELETING" | awk '{print $1}'); do kubectl -n <namespace>  patch cfrb $rb -p '{"metadata":{"finalizers":[]}}' --type=merge; done

If you are trying to remove the finalizer for all the `ConfluentRolebindings` resources in a namespace no matter there status, for example when the namespace stuck in terminating state and need to clean up all the `ConfluentRolebindings`, then run the following command

     for rb in $(kubectl -n <namespace> get cfrb -ojsonpath='{.items[*].metadata.name}'); do kubectl -n <namespace>  patch cfrb $rb -p '{"metadata":{"finalizers":[]}}' --type=merge; done

`<namespace>` replace your namespace when running above command.
</li>

</ol>
