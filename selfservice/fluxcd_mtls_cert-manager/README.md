# Simple and versatile CI/CD with FluxCD and Gitops in Confluent for Kubernetes


Confluent for Kubernetes provide custom resource definitions for CRDs for many resources used regularly in Confluent/Kafka deployments such as Topics, Schemas, Connector and RBAC (Role Based Access Control),
however there are still situations where the use of a simple CI/CD system will benefit grately a deployment, for example:

* Resource changes applied using a gitops approach
* Hybrid use of RBAC and/or ACLs in your deployment

In this example, we're going to be building out for the second case, where Kafka ACLs are used.
Showing how the use of a simple CD solution such as Flex might work in your deployment.


To complte this scenario, you will 

* Deploy Confluent for Kubernetes
* Deploy Confluent Platform
* Deploy FlexCD and the Terraform Controller

Requirements

* A separate repository to host the terraform HCL scripts


**Note**, the use of terraform here is as a simple and most probably useful example, however the solution is generalizable to any executor such as JulieOps, Kafka Security Manager, or your own Gitops solution.


## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>
```

## Deploy Confluent for Kubernetes

This workflow scenario assumes you are using the namespace `confluent`, otherwise you can create it by running ``kubectl create namespace confluent``. 

Set up the Helm Chart:

```
helm repo add confluentinc https://packages.confluent.io/helm
```

Install Confluent For Kubernetes using Helm:

```
helm upgrade --install operator confluentinc/confluent-for-kubernetes -n confluent
```
  
Check that the Confluent For Kubernetes pod comes up and is running:

```
kubectl get pods -n confluent
```

## Deploy the Certificate Manager and basic auth secrets

To deploy the certificate manager in self signed mode you should:

```bash
$> kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

```bash
$> kubectl create namespace confluent-certs
...
$> kubectl  -k $TUTORIAL_HOME/cert-manager/self-signed apply
```

After this you should be able to see a few secrets created to be used for the mTLS authentication.

```bash
$ kubectl get secrets
NAME                             TYPE                 DATA   AGE
connect-pkcs12                   Opaque               7      11d
connect-tls                      kubernetes.io/tls    3      11d
controlcenter-pkcs12             Opaque               7      11d
controlcenter-tls                kubernetes.io/tls    3      11d
kafka-pkcs12                     Opaque               7      11d
kafka-tls                        kubernetes.io/tls    3      11d
ksqldb-tls                       kubernetes.io/tls    3      11d
schemaregistry-pkcs12            Opaque               7      11d
schemaregistry-tls               kubernetes.io/tls    3      11d
sh.helm.release.v1.operator.v1   helm.sh/release.v1   1      11d
zookeeper-pkcs12                 Opaque               7      11d
zookeeper-tls                    kubernetes.io/tls    3      11d
```
To deploy the basic auth secrets you should run the following command

```bash
$> kubectl create secret generic basicsecret --from-file=basic.txt=$TUTORIAL_HOME/resources/basic.txt 
```

## Deploy Confluent Platform

Deploy Confluent Platform using the following commands:

```bash 
$> kubectl apply -f $TUTORIAL_HOME/resources/
```

at this point you should be able to observe a number of containers belonging to the Confluent Platform deployment

```bash 
$ kubectl get pods
NAME                                  READY   STATUS    RESTARTS       AGE
confluent-operator-6c8c7cc447-b227l   1/1     Running   0              12d
connect-0                             1/1     Running   2 (5d5h ago)   11d
connect-1                             1/1     Running   2 (5d5h ago)   11d
controlcenter-0                       1/1     Running   0              6d
kafka-0                               1/1     Running   0              5d5h
kafka-1                               1/1     Running   0              5d5h
kafka-2                               1/1     Running   0              5d5h
kafka-3                               1/1     Running   0              5d5h
schemaregistry-0                      1/1     Running   0              11d
zookeeper-0                           1/1     Running   0              11d
zookeeper-1                           1/1     Running   0              11d
zookeeper-2                           1/1     Running   0              11d
```

## Setup FluxCD

### Deploy Flux and the TF controller

To deploy fluxcd you should use the following command

```bash
$> kubectl apply -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
```

for the TF controller:

```bash
$> kubectl apply -f https://raw.githubusercontent.com/weaveworks/tf-controller/main/docs/release.yaml
```

### Configure the Flux actions

To be able to use FluxCD/TF-Controller you will have to make use of a couple of CRDs

Define a GitRepository:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: helloworld
  namespace: flux-system
spec:
  interval: 30s
  url: https://github.com/purbon/tf-controller-example.git
  ref:
    branch: main
```

Example resource definitions are included in this repository under the directory [artefacts/acls](artefacts/acls) in this example.


Make use of the Terraform action:

```yaml
apiVersion: infra.contrib.fluxcd.io/v1alpha2
kind: Terraform
metadata:
  name: helloworld
  namespace: flux-system
spec:
  interval: 1m
  approvePlan: auto
  path: ./
  sourceRef:
    kind: GitRepository
    name: helloworld
    namespace: flux-system
```

For more detailed information on how to use the Flux and the TF-Controller you can always refer to their documentation [here](https://weaveworks.github.io/tf-controller/).


Apply this resources by using this command:

```bash
$>  kubectl apply -f $TUTORIAL_HOME/gitops/flux-source.yaml
```

```bash 
$>  kubectl apply -f $TUTORIAL_HOME/gitops/terraform-action.yaml
```

This commands should setup the necessary Flux containers, you should be able to see this pod running

```bash 
$ kubectl get pods -n flux-system
NAME                                           READY   STATUS    RESTARTS   AGE
helm-controller-f4f58b65-f5llm                 1/1     Running   0          10d
image-automation-controller-79fb785774-8kbr7   1/1     Running   0          10d
image-reflector-controller-755f745d4-kz2xl     1/1     Running   0          10d
kustomize-controller-7796b6649f-8mgv6          1/1     Running   0          10d
notification-controller-7c6b6686fc-2lgml       1/1     Running   0          10d
source-controller-74c44468f8-6dzb2             1/1     Running   0          10d
tf-controller-7975f69b86-fwctf                 1/1     Running   0          10d
tf-controller-7975f69b86-rgh66                 1/1     Running   0          10d
tf-controller-7975f69b86-tlk4z                 1/1     Running   0          10d
```

## How to use it

If we take this example as a baseline, the repository defined previously will be check every minute and if a plan
require execution it will be applied.
However, this is not the only workflow possible for this setup as Flux can be used aswell in a less liberal approach
where
*  Terraform plans require to be aproved by an authorized persion
*  Reconciliations are trigger in a more granual way.

Note, TF-Controller can be integrted with Enterprise solutions and with external hooks, for more information you can check the reference documentation [here](https://weaveworks.github.io/tf-controller/use_tf_controller/).

### TF cli

A very useful tool is the TF cli, available to install using the command

```bash 
$> brew install weaveworks/tap/tfctl
```

TF ctl will provide you with a control plane directly from your CLI enabling direct control over the Flux action/behaviours

```bash
Usage:
  tfctl [command]

Available Commands:
  completion  Generate the autocompletion script for the specified shell
  create      Create a Terraform resource
  delete      Delete a Terraform resource
  get         Get Terraform resources
  help        Help about any command
  install     Install the tf-controller
  plan        Plan a Terraform configuration
  reconcile   Trigger a reconcile of the provided resource
  resume      Resume reconciliation for the provided resource
  suspend     Suspend reconciliation for the provided resource
  uninstall   Uninstall the tf-controller
  version     Prints tf-controller and tfctl version information

Flags:
  -h, --help                help for tfctl
      --kubeconfig string   Path to the kubeconfig file to use for CLI requests.
  -n, --namespace string    The kubernetes namespace to use for CLI requests. (default "flux-system")
      --terraform string    The location of the terraform binary. (default "/usr/bin/terraform")

Use "tfctl [command] --help" for more information about a command.
```

providing a user with a good versatility of options


## Teardown

```bash
kubectl delete -f $TUTORIAL_HOME/gitops
kubectl delete -f $TUTORIAL_HOME/resources
helm delete operator -n confluent
```