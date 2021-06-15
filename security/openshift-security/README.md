# Security considerations for Red Hat Openshift

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:
   
export TUTORIAL_HOME=<Tutorial directory>/openshift-security

## Pod Security

CFK, by default, configures the Pod Security Context to run as non-root with a UID and GUID `1001`.

In Red Hat OpenShift, by default Security Context Constraint (SCC) does not allow a pod to run with the above security context.

You've got two options to align with the Security Context Constraint (SCC) needs on Red Hat OpenShift:

1) Recommended: Deploy with default SCC policy
2) Advanced: Deploy with a custom SCC policy

## Recommended: Install Confluent for Kubernetes using default SCC policy

To install Confluent for Kubernees:

```
# Disable the custom pod security context, use the default context

helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes \ 
--set podSecurity.enabled=false --namespace confluent
```

In every Confluent component CustomResource, add `podSecurityContext`:

```
vi $TUTORIAL_HOME/confluent-platform-with-defaultSCC.yaml
...
spec:
  podTemplate:
    podSecurityContext: {} # Disable the custom pod security context, to use the default
...
```

Deploy Confluent Platform CRs with the `podSecurityContext`:

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform-with-defaultSCC.yaml
```

## Advanced: Install Confluent for Kubernetes with custom SCC policy

In this advanced option, you can define a custom SCC policy and configure Confluent for Kubernetes
to use that.

```
# In the CFK Operator Helm chart, there is a section in the values.yaml to define pod security:
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

# Set a custom SCC in Red Hat OpenShift

## View the custom policy and the ID ranges allowed
vi $TUTORIAL_HOME/scc.yaml
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

## Set the SCC policy for the CFK Operator pod
oc apply -f $TUTORIAL_HOME/scc.yaml

## Associate the SCC policy to the service account that runs CFK Operator
oc adm policy add-scc-to-user <scc_name> -z <serviceaccount_running_CFK> -n <namespace>
### For example:
oc adm policy add-scc-to-user confluent-operator -z confluent-operator -n confluent

## Associate the SCC policy to the service account that runs Confluent Platform components
oc adm policy add-scc-to-user <scc_name> -z <serviceaccount_running_CP> -n <namespace>
### For example:
oc adm policy add-scc-to-user confluent-operator -z default -n confluent

```
