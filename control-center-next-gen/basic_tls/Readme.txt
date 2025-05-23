1. Create basic credentials for prometheus & alertmanager server
kubectl -n operator create secret generic prometheus-credentials --from-file=basic.txt=./creds/prometheus-credentials-secret.txt
kubectl -n operator create secret generic alertmanager-credentials --from-file=basic.txt=./creds/alertmanager-credentials-secret.txt

2. Create basic credentials for prometheus & alertmanager client
kubectl -n operator create secret generic prometheus-client-creds --from-file=basic.txt=./creds/prometheus-client-credentials-secret.txt
kubectl -n operator create secret generic alertmanager-client-creds --from-file=basic.txt=./creds/alertmanager-client-credentials-secret.txt

3. Create `prometheus-tls` & `alertmanager-tls` configMap
```bash
kubectl create secret generic prometheus-tls -n operator --from-file=fullchain.pem=./certs/server.pem --from-file=privkey.pem=./certs/server-key.pem --from-file=cacerts.pem=./certs/cacerts.pem
kubectl create secret generic alertmanager-tls -n operator --from-file=fullchain.pem=./certs/server.pem --from-file=privkey.pem=./certs/server-key.pem --from-file=cacerts.pem=./certs/cacerts.pem
```

4. Create client side certs against prometheus & alertmanager
```bash
kubectl create secret generic prometheus-client-tls -n operator --from-file=fullchain.pem=./certs/server.pem --from-file=privkey.pem=./certs/server-key.pem --from-file=cacerts.pem=./certs/cacerts.pem
kubectl create secret generic alertmanager-client-tls -n operator --from-file=fullchain.pem=./certs/server.pem --from-file=privkey.pem=./certs/server-key.pem --from-file=cacerts.pem=./certs/cacerts.pem
```

3- Apply k8 yaml
kubectl apply -f confluent_platform.yaml


