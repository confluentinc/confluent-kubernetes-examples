# Deploy on Red Hat Openshift

When deploying Confluent for Kubernetes on Red Hat Openshift, there are two considerations:

- Pod Security

## Pod Security

CFK, by default, configures the Pod Security Context to run as non-root with a UID and GUID `1001`.

In OpenShift, by default SCC does not allow a pod to run with the above security context.

Now, you've got a choice:

1) Recommended: Deploy with default SCC policy
2) Advanced: Deploy with a custom SCC policy

We recommend you to use (1).

## Recommended: Install Confluent for Kubernetes with default SCC

To install Confluent for Kubernees:

```
# Disable the custom pod security context, use the default

helm install cfk-operator confluentinc/confluent-for-kubernetes \ 
--set podSecurity.enabled=false
```

In every component CustomResource, add:

```
spec:
  podTemplate:
    podSecurityContext: {} # Disable the custom pod security context, use the default
```

## (2) Install Confluent for Kubernetes (with randomUID)

```
# In the CFK Operator Helm chart, there is a section in the values.yaml for pod security:
podSecurity:
  enabled: true
  securityContext:
    fsGroup: 1001
    runAsUser: 1001
    runAsNonRoot: true

# For example, to use the group id `1004` and user id `1004`
helm install cfk-operator confluentinc/confluent-for-kubernetes \ 
--set podSecurity.enabled=true 
--set podSecurity.securityContext.fsGroup=1004
--set podSecurity.securityContext.runAsUser=1004

# Also set the scc.yaml to contain the above in the defined ranges

...
fsGroup:
  type: MustRunAs
  ranges:
    # Configure allowed group ID to be between 1001 and 1005.
    - min: 1001
      max: 1005
...
runAsUser:
   # Configure allowed user ID to be between 1001 and 1005
  type: MustRunAsRange
  uidRangeMin: 1001
  uidRangeMax: 1005
...

# Configure the custom SCC

## Set the SCC policy for the CFK Operator pod
oc apply -f resources/scc.yaml

## Associate the SCC policy to the service account that runs CFK Operator
oc adm policy add-scc-to-user <scc_name> -z <serviceaccount_running_CFK> -n <namespace>
### For example:
oc adm policy add-scc-to-user confluent-operator -z confluent-operator -n confluent

## Associate the SCC policy to the service account that runs Confluent Platform components
oc adm policy add-scc-to-user <scc_name> -z <serviceaccount_running_CP> -n <namespace>
### For example:
oc adm policy add-scc-to-user confluent-operator -z default -n confluent

```

