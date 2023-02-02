# Security considerations for Red Hat Openshift

## Pod Security

CFK, by default, configures the Pod Security Context to run as non-root with a UID and GUID `1001`.

In Red Hat OpenShift, by default Security Context Constraint (SCC) does not allow a pod to run with the above security context.

You've got two options to align with the Security Context Constraint (SCC) needs on Red Hat OpenShift:

1) Recommended: Deploy with default SCC policy
2) Advanced: Deploy with a custom SCC policy

Before continuing with the scenario, ensure that you have set up the
[prerequisites](/README.md#prerequisites).

Set the tutorial directory for this tutorial under the directory you downloaded
the tutorial files:

```   
export TUTORIAL_HOME=<Tutorial directory>/security/openshift-security
```

## Recommended: Install Confluent for Kubernetes using default SCC policy

Install Confluent for Kubernetes using the default SCC:

```
# Disable the custom pod security context, use the default context

helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \ 
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
to use that. You'll follow these steps to do this:

1) Define a custom SCC policy
2) Associate the SCC policy to the service accounts used by Confluent for Kubernetes and Confluent Platform
3) Install Confluent for Kubernetes using the custom SCC

### 1) Define a custom SCC policy 

Set a custom SCC in Red Hat OpenShift

```
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
   # Configure allowed user ID to be between 1000 and 1005
  type: MustRunAsRange
  uidRangeMin: 1000
  uidRangeMax: 1005
...

## Set the SCC policy for the CFK Operator pod
oc apply -f $TUTORIAL_HOME/scc.yaml
```

### 2) Associate the SCC policy to the service accounts

Associate the SCC policy to the service account that runs CFK Operator:

```
## This is the format of the command
oc adm policy add-scc-to-user <scc_name> -z <serviceaccount_running_CFK> -n <namespace>
## For example
oc adm policy add-scc-to-user confluent-operator -z confluent-for-kubernetes -n confluent
```

Associate the SCC policy to the service account that runs Confluent Platform components:

```
## This is the format of the command
oc adm policy add-scc-to-user <scc_name> -z <serviceaccount_running_CP> -n <namespace>
## For example
oc adm policy add-scc-to-user confluent-operator -z default -n confluent
```

### 3) Install Confluent for Kubernetes using the custom SCC

Install Confluent for Kubernetes:

```
# In the CFK Operator Helm chart, there is a section in the values.yaml to define pod security:
podSecurity:
  enabled: true
  securityContext:
    fsGroup: 1001
    runAsUser: 1001
    runAsNonRoot: true

# For example, to use the group id `1001` and user id `1001`
helm install confluent-operator confluentinc/confluent-for-kubernetes \ 
--set podSecurity.enabled=true \
--set podSecurity.securityContext.fsGroup=1001 \
--set podSecurity.securityContext.runAsUser=1001 
```

Deploy Confluent Platform CRs with the custom `podSecurityContext` set:

```
oc apply -f $TUTORIAL_HOME/confluent-platform-with-customSCC.yaml

# Here, the `podSecurityContext` is set with the groupid and userid to use
vi $TUTORIAL_HOME/confluent-platform-with-customSCC.yaml
...
spec:
  ...
  podTemplate:
    podSecurityContext:
      fsGroup: 1001
      runAsUser: 1001
      runAsNonRoot: true
```

## Associating with Namespaces

In this scenario, you'll deploy the Confluent for Kubernetes (CFK) Operator in one namespace, 
and have it create & manage Confluent Platform Custom Resources (CRs) in other specified
namespaces.

Create three namespaces; one for the CFK Operator, and two for Confluent Platform CRs:

```
oc create ns confluent-operator
oc create ns confluent
oc create ns confluent-test
```

Deploy the CFK Operator to the `confluent-operator` namespace

```
# Tell the CFK Operator to manage CRs in `confluent` and `confluent-test` namespace
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
--set podSecurity.enabled=false --set namespaceList="{confluent,confluent-test}" \
--namespace confluent-operator
```

Deploy Confluent Platform CRs to the `confluent` namespace

```
oc apply -f $TUTORIAL_HOME/confluent-platform-with-defaultSCC.yaml
```