# Multi-Tenancy Quickstart

Run two isolated Logical Kafka Clusters (LKCs), `payments` and `analytics`, on one Physical Kafka Cluster (PKC). Then check that each LKC's admin sees only their own LKC.

It takes about 15 minutes, most of it image pulls and brokers starting.

This is a sandbox. It uses demo passwords and certificates that CFK generates from a throwaway CA. For production planning, see [Deploy a Multi-Tenant PKC](https://docs.confluent.io/platform/current/private-cloud/multi-tenancy/deploy-a-multi-tenant-pkc.html).

```
namespace confluent
├── CFK 3.4
├── OpenLDAP                     users for MDS
├── KRaftController
├── Kafka x3                     the PKC (spec.multiTenant.enabled)
├── Control Center 2.7           with Prometheus and Alertmanager
├── LKCs payments, analytics     each with a TenantAdmin
└── kafka-client pod             Kafka CLI and a client config per user
```

## Prerequisites

- A Kubernetes cluster with at least 16 GB of memory. The steps create one with [kind](https://kind.sigs.k8s.io/).
- `kubectl`, `helm`, and `openssl`

No license is needed. Without one, a PKC allows up to three LKCs.

### Other clusters

This example runs on kind, and it should work on any Kubernetes cluster with these changes:

- In Step 1, skip `kind create cluster`.
- In Step 2, don't apply `kind-dns.yaml`, because it replaces the whole CoreDNS config. Add its four `rewrite` rules to your cluster's CoreDNS config instead. For other DNS setups, see [Configure TLS Certificates and DNS for Multi-Tenant PKCs](https://docs.confluent.io/platform/current/private-cloud/multi-tenancy/tls-options.html).
- To clean up, use the steps for other clusters in [Tear down](#tear-down).

On a cloud cluster, the external listener creates four load balancers.

## Users

| User | Password | Role |
|---|---|---|
| `platform-operator` | `platform-operator-secret` | `OrganizationAdmin` on the PKC and every LKC on it |
| `payments-admin` | `payments-admin-secret` | `TenantAdmin` on the `payments` LKC |
| `analytics-admin` | `analytics-admin-secret` | `TenantAdmin` on the `analytics` LKC |

## Set the tutorial home

```bash
export TUTORIAL_HOME=<Tutorial directory>/multi-tenancy/quickstart
```

## Step 1: Create the cluster

```bash
kind create cluster --name cfk-mt
kubectl create namespace confluent
kubectl config set-context --current --namespace=confluent
```

The manifests use the `confluent` namespace in service endpoints, so keep it.

## Step 2: Resolve the LKC hostnames

Clients reach each LKC through its own hostnames, such as `lkc-<id>-kafka.confluent.svc.cluster.local` in the cluster and `lkc-<id>-kafka.kafka.mt.example.com` on the external listener. `kind-dns.yaml` adds rewrite rules to the cluster's CoreDNS that resolve these names to the PKC's Services:

```bash
kubectl replace -f $TUTORIAL_HOME/resources/kind-dns.yaml
kubectl -n kube-system rollout restart deployment coredns
kubectl -n kube-system rollout status deployment coredns
```

## Step 3: Create the CA and the MDS token keys

CFK issues every certificate from this CA. MDS signs its tokens with the key pair.

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=cfk-mt-ca" \
  -keyout /tmp/ca-key.pem -out /tmp/ca.pem
kubectl create secret tls ca-pair-sslcerts --cert=/tmp/ca.pem --key=/tmp/ca-key.pem

openssl genrsa -out /tmp/mds-key.pem 2048
openssl rsa -in /tmp/mds-key.pem -pubout -out /tmp/mds-pub.pem
kubectl create secret generic mds-token \
  --from-file=mdsTokenKeyPair.pem=/tmp/mds-key.pem \
  --from-file=mdsPublicKey.pem=/tmp/mds-pub.pem

rm -f /tmp/ca.pem /tmp/ca-key.pem /tmp/mds-key.pem /tmp/mds-pub.pem
```

## Step 4: Install CFK

```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --namespace confluent \
  --set managedCerts.enabled=true \
  --set managedCerts.caCertificate.secretRef=ca-pair-sslcerts
```

`managedCerts` makes CFK read the `managed-cert-add-sans` annotation in `kafka.yaml`. Its wildcards go on the broker certificate and cover every LKC's external hostnames.

## Step 5: Install OpenLDAP

MDS authenticates every user against LDAP. `ldap-users.yaml` adds the three users above.

```bash
helm upgrade --install test-ldap $TUTORIAL_HOME/../../assets/openldap \
  --namespace confluent \
  -f $TUTORIAL_HOME/../../assets/openldap/ldaps-rbac.yaml \
  -f $TUTORIAL_HOME/ldap-users.yaml
kubectl wait --for=condition=ready pod/ldap-0 --timeout=5m
```

## Step 6: Deploy the PKC and Control Center

`spec.multiTenant.enabled: true` turns the Kafka cluster into a PKC. It needs TLS, RBAC, embedded MDS, and a memory request or limit on the brokers.

```bash
kubectl apply -f $TUTORIAL_HOME/resources/secrets.yaml \
  -f $TUTORIAL_HOME/resources/kraftcontroller.yaml \
  -f $TUTORIAL_HOME/resources/kafka.yaml \
  -f $TUTORIAL_HOME/resources/kafkarestclass.yaml \
  -f $TUTORIAL_HOME/resources/controlcenter.yaml
```

Wait for the brokers. This takes about 5 minutes.

```bash
kubectl wait --for=jsonpath='{.status.phase}'=RUNNING kafka/kafka --timeout=20m
kubectl get kafka kafka
```

`MULTITENANT` shows `true`. The KRaftController also restarts once to pick up the Multi-Tenancy settings.

## Step 7: Create the LKCs

CFK creates LKCs through MDS, and only an `OrganizationAdmin` on the PKC can do that. Super-user status isn't enough. Grant the role to `kafka`, the user CFK calls MDS as:

```bash
kubectl apply -f $TUTORIAL_HOME/resources/cfk-orgadmin.yaml
kubectl wait --for=jsonpath='{.status.state}'=CREATED confluentrolebinding/cfk-orgadmin --timeout=5m
```

Create the LKCs:

```bash
kubectl apply -f $TUTORIAL_HOME/resources/lkcs.yaml
kubectl wait --for=jsonpath='{.status.state}'=CREATED lkc/payments lkc/analytics --timeout=5m
kubectl get lkc
```

Each LKC gets an ID in the form `lkc-<id>` and two bootstrap endpoints:

| Endpoint | Port | Clients authenticate with |
|---|---|---|
| `status.internalBootstrapEndpoint` | 9076, in-cluster | An MDS token (OAUTHBEARER), using their LDAP password |
| `status.bootstrapEndpoint` | 9092, external listener | SASL/PLAIN |

## Step 8: Grant access

Give `platform-operator` the `OrganizationAdmin` role on the PKC, and give each LKC admin the `TenantAdmin` role on their LKC. `TenantAdmin` covers topics, records, and consumer groups, so no ACLs are needed.

```bash
kubectl apply -f $TUTORIAL_HOME/resources/rolebindings.yaml
kubectl wait --for=jsonpath='{.status.state}'=CREATED \
  confluentrolebinding/platform-operator-orgadmin \
  confluentrolebinding/payments-admin \
  confluentrolebinding/analytics-admin --timeout=5m
```

## Step 9: Start a client

Start the client pod. It has the Kafka CLI, the CA certificate, and a client config for each user in `/clients`:

```bash
kubectl apply -f $TUTORIAL_HOME/resources/kafka-client.yaml
kubectl wait --for=condition=ready pod/kafka-client --timeout=5m
```

## Validate

Save each LKC's endpoints:

```bash
PAYMENTS=$(kubectl get lkc payments -o jsonpath='{.status.internalBootstrapEndpoint}')
ANALYTICS=$(kubectl get lkc analytics -o jsonpath='{.status.internalBootstrapEndpoint}')
PAYMENTS_EXT=$(kubectl get lkc payments -o jsonpath='{.status.bootstrapEndpoint}')
```

As `payments-admin`, create a topic in `payments`, then produce and consume:

```bash
kubectl exec kafka-client -- kafka-topics --bootstrap-server $PAYMENTS \
  --command-config /clients/payments-admin.properties \
  --create --topic orders --partitions 3 --replication-factor 3

seq 1 5 | kubectl exec -i kafka-client -- kafka-console-producer --bootstrap-server $PAYMENTS \
  --command-config /clients/payments-admin.properties --topic orders

kubectl exec kafka-client -- kafka-console-consumer --bootstrap-server $PAYMENTS \
  --command-config /clients/payments-admin.properties \
  --topic orders --from-beginning --max-messages 5
```

As `analytics-admin`, create a topic with the same name in `analytics`. It doesn't clash, because each LKC has its own topic namespace:

```bash
kubectl exec kafka-client -- kafka-topics --bootstrap-server $ANALYTICS \
  --command-config /clients/analytics-admin.properties \
  --create --topic orders --partitions 3 --replication-factor 3
```

On the PKC, each LKC's topics carry its ID as a prefix. List them as the `kafka` super user:

```bash
kubectl exec kafka-client -- kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
  --command-config /clients/kafka.properties --list | grep orders
```

You see `lkc-<id>_orders` twice, once for each LKC.

`analytics-admin` can't see anything in `payments`. This lists no topics:

```bash
kubectl exec kafka-client -- kafka-topics --bootstrap-server $PAYMENTS \
  --command-config /clients/analytics-admin.properties --list
```

The external listener routes each client to its LKC by hostname. Read the records again through it:

```bash
kubectl exec kafka-client -- kafka-console-consumer --bootstrap-server $PAYMENTS_EXT \
  --command-config /clients/payments-admin-external.properties \
  --topic orders --from-beginning --max-messages 5
```

### Control Center

```bash
kubectl wait --for=condition=ready pod/controlcenter-0 --timeout=10m
kubectl port-forward controlcenter-0 9021:9021
```

Open https://localhost:9021 and accept the certificate warning.

- Log in as `platform-operator` to see the PKC and both LKCs.
- Log in as `payments-admin` to see only `payments`.

## Tear down

On kind, delete the cluster:

```bash
kind delete cluster --name cfk-mt
```

On other clusters, delete the LKCs first, while the PKC is still running. CFK removes them from MDS before it lets them go.

```bash
kubectl delete -f $TUTORIAL_HOME/resources/kafka-client.yaml \
  -f $TUTORIAL_HOME/resources/rolebindings.yaml \
  -f $TUTORIAL_HOME/resources/lkcs.yaml
kubectl delete -f $TUTORIAL_HOME/resources/cfk-orgadmin.yaml \
  -f $TUTORIAL_HOME/resources/controlcenter.yaml \
  -f $TUTORIAL_HOME/resources/kafkarestclass.yaml \
  -f $TUTORIAL_HOME/resources/kafka.yaml \
  -f $TUTORIAL_HOME/resources/kraftcontroller.yaml
helm uninstall test-ldap confluent-operator --namespace confluent
kubectl delete namespace confluent
```

Then remove the `rewrite` rules you added to CoreDNS.

## Troubleshooting

| Symptom | Fix |
|---|---|
| The API server rejects `kafka.yaml` with a field that's required when `multiTenant.enabled` is `true` | A Multi-Tenancy prerequisite is missing. Keep TLS, RBAC, MDS, and the broker memory. |
| Brokers crash-loop with an error about `confluent.quota.tenant.broker.max.producer.rate` | Broker memory is too low. Keep it at `4Gi`. |
| Pods stay `Pending` with `Insufficient memory` | Give the cluster more memory. On kind, that's the memory you give Docker. |
| An LKC shows `ERROR` with `40301` | `cfk-orgadmin` isn't `CREATED` yet. The LKC recovers on its own. |
| An LKC stays `PROVISIONING` for a few minutes | MDS is still starting. Wait. |
| A fourth LKC shows `ERROR` with a tenant creation limit | Without a license, a PKC allows three LKCs. Delete one, or apply a license to the Kafka, KRaftController, and ControlCenter CRs. |
| The KRaftController shows `FAILED` while `kraftcontroller-0` is running | Known issue. If the pod is ready, carry on. |
| `payments-admin` can't create a topic right after setup | The KRaftController is still restarting. Wait for `kraftcontroller-0` to be ready. |
| An external client fails TLS hostname verification | Check the `managed-cert-add-sans` annotation in `kafka.yaml`, and that CFK was installed with `managedCerts.enabled=true`. |
| A client reports an unknown host for an `lkc-` hostname | CoreDNS hasn't picked up `kind-dns.yaml`. Rerun the commands in Step 2. |
| Control Center returns `400 Invalid SNI` | Open `https://localhost:9021`, not `https://127.0.0.1:9021`. |

To dig further:

```bash
kubectl logs deploy/confluent-operator | grep -iE 'error|logicalkafkacluster' | tail -50
kubectl describe lkc payments
kubectl get events --sort-by=.lastTimestamp | tail -30
```

## Next steps

- [Onboard an LKC](https://docs.confluent.io/platform/current/private-cloud/multi-tenancy/onboard-a-tenant.html)
- [Onboard a Developer to an LKC](https://docs.confluent.io/platform/current/private-cloud/multi-tenancy/onboard-a-developer.html)
- [Monitor and Manage Per-LKC Resource Quotas](https://docs.confluent.io/platform/current/private-cloud/multi-tenancy/manage-tenant-quotas.html)
- [Configure TLS Certificates and DNS for Multi-Tenant PKCs](https://docs.confluent.io/platform/current/private-cloud/multi-tenancy/tls-options.html)
