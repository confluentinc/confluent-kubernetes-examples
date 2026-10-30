# External Prometheus with Basic Authentication over TLS

Control Center, Kafka brokers, and KRaft controllers connect to your external
Prometheus over TLS and authenticate with a user name and password.

Run the following commands from this directory.

1. Install Confluent for Kubernetes in the `operator` namespace:

   ```bash
   kubectl create namespace operator
   helm repo add confluentinc https://packages.confluent.io/helm
   helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --namespace operator
   ```

2. Create a Secret with the CA that signed the Prometheus server certificate:

   ```bash
   kubectl -n operator create secret generic prometheus-client-tls \
     --from-file=ca.crt=<path-to-prometheus-ca.pem>
   ```

3. Replace `<username>` and `<password>` with the Prometheus credentials in
   [`creds/prometheus-client-credentials-secret.txt`](creds/prometheus-client-credentials-secret.txt),
   and create a Secret from it:

   ```bash
   kubectl -n operator create secret generic prometheus-client-creds \
     --from-file=basic.txt=./creds/prometheus-client-credentials-secret.txt
   ```

4. In [`confluent_platform.yaml`](confluent_platform.yaml), replace
   `https://prometheus.example.com:9090` with the URL of your Prometheus, and
   deploy Confluent Platform:

   ```bash
   kubectl apply -f confluent_platform.yaml
   ```

5. Verify that Control Center reports the external Prometheus as online:

   ```bash
   kubectl -n operator port-forward controlcenter-next-gen-0 9021:9021
   curl -s http://localhost:9021/3.0/services/prometheus/status
   ```

   The response contains `"external":true` and `"componentStatus":"ONLINE"`.
