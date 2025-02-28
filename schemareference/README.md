## Schema CR

The schema cr is a declarative way to manage schemas. A schema CR represents the state of a Subject, and is used
to manage the versions that belong to the subject. This includes creating and deleting of subjects and schema versions. The schema CR can only manage new subjects created by CFK and not any existing schemas. The state of the schema CR status represents that of the latest schema version for the subject.

## Prerequisite
1. have a running Zookeeper/Kraft, Kafka, SchemaRegistry setup

## Create Schema CR

In this example, we will create 2 schemas: address-value and customer-value. customer-value will refer to the latest address-value using schema referencing

- Deploy the schema data configmap

       kubectl apply -f address-schema-config.yaml
       kubectl apply -f customer-schema-config.yaml

- Deploy the schemas

       kubectl apply -f address-schema.yaml
       kubectl apply -f customer-schema.yaml

    Note:
      - In this example, we configured schema to reference the schemaregistry cluster through discovery. For discovery to work,
        schemaRegistry should be deployed in the same namespace as the schema namespace. Otherwise, schema can be configured to reference

     - If schemaRegistryRef is configured, make sure the correct authentication and TLS are set:
            - Refer [Here](../../../design/templates/common/authentication/rest_endpoint/authentication.md#Rest-Client-Side) to configure authentication
            - Refer [Here](../../../config/samples/README.md) to to create secrets properly (for authentcation and/or TLS)


  - Test command examples
    PreReq: `kubectl exec schemaregistry-0 bash -it`

      - verify subject created

            curl http://schemaregistry.confluent.svc.cluster.local:8081/subjects

      - verify versions created

            curl http://schemaregistry.confluent.svc.cluster.local:8081/subjects/address-subject/versions
            curl http://schemaregistry.confluent.svc.cluster.local:8081/subjects/customer-value/versions

      - verify versions created with right schema

            curl http://schemaregistry.confluent.svc.cluster.local:8081/subjects/address-subject/versions/1
            curl http://schemaregistry.confluent.svc.cluster.local:8081/subjects/customer-value/versions/1

## Check the schema versions
- Check the schema status of both the schemas. address-value should have its version set to 1.
   customer-value should have its version as 1 and should refer to address-value version 1

## Creating new schemas
- Update the configref for the address schema

        kubectl apply -f address-schema-config2.yaml

  Check the schema status. If the create succeeded, the status should have an updated ID and version to reflect the state of the latest schema under the subject for the schema CR as well as a non failed create condition.
  
  address-value should now have version 2 in status


- Within 2 minutes, auto-reconcile will be triggered on the customer-value schema, which will update the referenced version of address-value to 2
  
- ### Optional: 
  For instant reconcile of customer-value to sync with latest address-value, run command 

        kubectl annotate schema customer-value -n confluent platform.confluent.io/force-reconcile="true"

  Check the status of customer-value, it should refer to address-value version 2 now


## Deleting the subject
- Delete the schema CR

       kubectl delete -f customer-schema.yaml
       kubectl delete -f address-schema.yaml
       

  `curl http://schemaregistry.confluent.svc.cluster.local:8081/subjects`

  Note: if this does not work due to perhaps an http client error or schemaregistry already being deleted (data could still be in kafka), we can remove the finalizer from the schema CR if we want to delete the CR. 
