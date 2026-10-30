# External Prometheus with mTLS

Control Center, Kafka brokers, and KRaft controllers connect to your external
Prometheus over TLS and authenticate with a client certificate.

Your Prometheus must trust the CA that signed the client certificate. If it has
an extended key usage, the client certificate must include `clientAuth`.

Run the following commands from this directory.

1. Install Confluent for Kubernetes in the `operator` namespace:

   ```bash
   kubectl create namespace operator
   helm repo add confluentinc https://packages.confluent.io/helm
   helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --namespace operator
   ```

2. Create a Secret with the client certificate, its private key, and the CA
   that signed the Prometheus server certificate:

   ```bash
   kubectl -n operator create secret generic prometheus-client-tls \
     --from-file=fullchain.pem=<path-to-client-cert.pem> \
     --from-file=privkey.pem=<path-to-client-key.pem> \
     --from-file=cacerts.pem=<path-to-prometheus-ca.pem>
   ```

3. In [`confluent_platform.yaml`](confluent_platform.yaml), replace
   `https://prometheus.example.com:9090` with the URL of your Prometheus, and
   deploy Confluent Platform:

   ```bash
   kubectl apply -f confluent_platform.yaml
   ```

   The Secret contains PEM files, so the `ControlCenter` CR sets
   `tlsClientAliasName: "1"`.

4. Verify that Control Center reports the external Prometheus as online:

   ```bash
   kubectl -n operator port-forward controlcenter-next-gen-0 9021:9021
   curl -s http://localhost:9021/3.0/services/prometheus/status
   ```

   The response contains `"external":true` and `"componentStatus":"ONLINE"`.
