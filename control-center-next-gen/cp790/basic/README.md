Create basic credentials for prometheus & alertmanager server
```
kubectl -n operator create secret generic prometheus-credentials --from-file=basic.txt=./creds/prometheus-credentials-secret.txt
kubectl -n operator create secret generic alertmanager-credentials --from-file=basic.txt=./creds/alertmanager-credentials-secret.txt
```

Create basic credentials for prometheus & alertmanager client
```
kubectl -n operator create secret generic prometheus-client-creds --from-file=basic.txt=./creds/prometheus-client-credentials-secret.txt
kubectl -n operator create secret generic alertmanager-client-creds --from-file=basic.txt=./creds/alertmanager-client-credentials-secret.txt
```

Apply k8 yaml
```
kubectl apply -f confluent_platform.yaml
```
