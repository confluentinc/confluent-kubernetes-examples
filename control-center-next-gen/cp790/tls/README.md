## Create truststore with CA cert
### Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/c3++/cp790/tls
cd $TUTORIAL_HOME
```
```
$TUTORIAL_HOME/../../../../../scripts/create-truststore.sh ./certs/cacerts.pem mystorepassword
kubectl create secret generic mycustomtruststore --from-file=truststore.jks=./jks/truststore.jks -n operator
```

Create `prometheus-tls` & `alertmanager-tls` secrets
```bash
kubectl create secret generic prometheus-tls -n operator --from-file=fullchain.pem=./certs/server.pem --from-file=privkey.pem=./certs/server-key.pem --from-file=cacerts.pem=./certs/cacerts.pem
kubectl create secret generic alertmanager-tls -n operator --from-file=fullchain.pem=./certs/server.pem --from-file=privkey.pem=./certs/server-key.pem --from-file=cacerts.pem=./certs/cacerts.pem
```

Create client side certs against prometheus & alertmanager
```bash
kubectl create secret generic prometheus-client-tls -n operator --from-file=fullchain.pem=./certs/server.pem --from-file=privkey.pem=./certs/server-key.pem --from-file=cacerts.pem=./certs/cacerts.pem
kubectl create secret generic alertmanager-client-tls -n operator --from-file=fullchain.pem=./certs/server.pem --from-file=privkey.pem=./certs/server-key.pem --from-file=cacerts.pem=./certs/cacerts.pem
```

Apply k8 yaml
```
kubectl apply -f confluent_platform.yaml
```