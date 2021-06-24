# Monitoring

All Confluent Platform (CP) components deployed through Confluent for
Kubernetes expose metrics that can be scraped by Prometheus. This folder
contains an example Grafana metrics dashboard for all components included with
Confluent for Kubernetes. For production environments, you may need to modify
the example dashboard to meet your needs. Follow best practices for managing
your Prometheus and Grafana deployments. Completing the following instructions
will help you understand what the example dashboard can display for you.

Before continuing with these instructions, you will need to install Confluent
for Kubernetes. You may wish to start with the
[Quickstart Scenario](/quickstart-deploy/README.rst).

These instructions were last verified with:

* Helm v3.3.0+
* Prometheus Helm chart 13.8.0+ (app version 2.26.0+)
* Grafana Helm chart 6.7.4 (app version 7.5.3+)

## Install Prometheus
    helm repo add stable https://charts.helm.sh/stable
    helm repo add grafana https://grafana.github.io/helm-charts
    
    helm repo update

    helm upgrade --install demo-test stable/prometheus \
     --set alertmanager.persistentVolume.enabled=false \
     --set server.persistentVolume.enabled=false \
     --namespace default

## Install Grafana

    helm upgrade --install grafana grafana/grafana --namespace default

## Open Grafana in your Browser

Start port-forwarding, so you can access Grafana in your browser with a `localhost` address:

     kubectl port-forward \
      $(kubectl get pods -n default -l app.kubernetes.io/name=grafana,app.kubernetes.io/instance=grafana -o name) \
      3000 --namespace default

Get your 'admin' user password:

    kubectl get secret --namespace default grafana -o jsonpath="{.data.admin-password}" | base64 --decode

Visit http://localhost:3000 in your browser, and login as the `admin` user with the decoded password.

## Configure Grafana with a Prometheus Data Source

Follow the in-browser instructions to configure a Prometheus data source for Grafana, or consult the
[online documentation](https://prometheus.io/docs/visualization/grafana/#creating-a-prometheus-data-source). You will be asked
to provide a URL. Enter the URL as shown below:

    http://demo-test-prometheus-server.default.svc.cluster.local

Click "Save & Test". You should see a green alert at the bottom of the page saying "Data source
is working".

## Import Grafana Dashboard Configuration

Follow the in-browser instructions to import a dashboard JSON configuration, or consult the
[online documentation](https://grafana.com/docs/grafana/latest/reference/export_import/#importing-a-dashboard). 
- Select the `confluent-platform.json` file located in this folder to load dashboard for Confluent Platform, and then select the previously-configured Prometheus data source.
- Select the `confluent-operator.json` file located in this folder to load dashboard for Confluent Operator, and then select the previously-configured Prometheus data source.


