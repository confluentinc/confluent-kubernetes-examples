#!/bin/bash

# Exit on error
set -e

# Set up environment variables
export TUTORIAL_HOME=$(pwd)

echo "Starting cleanup process..."

echo "Deleting Flink Application..."
kubectl delete -f $TUTORIAL_HOME/manifests/flinkapplication.yaml --ignore-not-found=true

echo "Deleting Flink Environment..."
kubectl delete -f $TUTORIAL_HOME/manifests/flinkenvironment.yaml --ignore-not-found=true

echo "Deleting CMF Rest Class..."
kubectl delete -f $TUTORIAL_HOME/manifests/cmfrestclass.yaml --ignore-not-found=true

echo "Uninstalling CMF Helm release..."
helm uninstall cmf -n operator

echo "Deleting CMF related secrets..."
kubectl delete secret cmf-truststore cmf-keystore cmf-day2-tls -n operator --ignore-not-found=true

echo "Deleting Confluent Platform components..."
kubectl delete -f $TUTORIAL_HOME/manifests/cp_components.yaml --ignore-not-found=true

echo "Deleting C3 Next Gen related secrets..."
kubectl delete secret prometheus-credentials alertmanager-credentials prometheus-client-creds alertmanager-client-creds -n operator --ignore-not-found=true
kubectl delete secret prometheus-tls alertmanager-tls prometheus-client-tls alertmanager-client-tls -n operator --ignore-not-found=true

echo "Deleting OAuth JAAS secrets..."
kubectl delete secret oauth-jaas oauth-jaas-sso -n operator --ignore-not-found=true

echo "Deleting MDS token secret..."
kubectl delete secret mds-token -n operator --ignore-not-found=true

echo "Deleting credential secrets..."
kubectl delete secret credential -n operator --ignore-not-found=true

echo "Deleting CA certificate secret..."
kubectl delete secret ca-pair-sslcerts -n operator --ignore-not-found=true

echo "Deleting Keycloak..."
kubectl delete -f $TUTORIAL_HOME/dependencies/keycloak/keycloak.yaml --ignore-not-found=true

echo "Cleaning up generated certificates and files..."
rm -rf $TUTORIAL_HOME/certs/generated/*
rm -rf $TUTORIAL_HOME/certs/jks/*

echo "Deleting operator namespace..."
kubectl delete namespace operator --ignore-not-found=true

echo "Removing local DNS entries..."
echo "sudo sed -i '' '/confluent-manager-for-apache-flink.operator.svc.cluster.local/d' /etc/hosts"
echo "sudo sed -i '' '/keycloak/d' /etc/hosts"

echo "Cleanup completed successfully!"
