1. Create `prometheus-tls` & `alertmanager-tls` configMap
```bash
kubectl create secret generic prometheus-tls -n operator --from-file=fullchain.pem=./certs/server.pem --from-file=privkey.pem=./certs/server-key.pem --from-file=cacerts.pem=./certs/cacerts.pem
kubectl create secret generic alertmanager-tls -n operator --from-file=fullchain.pem=./certs/server.pem --from-file=privkey.pem=./certs/server-key.pem --from-file=cacerts.pem=./certs/cacerts.pem
```

2. Create client side certs against prometheus & alertmanager
```bash
kubectl create secret generic prometheus-client-tls -n operator --from-file=fullchain.pem=./certs/server.pem --from-file=privkey.pem=./certs/server-key.pem --from-file=cacerts.pem=./certs/cacerts.pem
kubectl create secret generic alertmanager-client-tls -n operator --from-file=fullchain.pem=./certs/server.pem --from-file=privkey.pem=./certs/server-key.pem --from-file=cacerts.pem=./certs/cacerts.pem
```

3- Apply k8 yaml
kubectl apply -f confluent_platform.yaml


