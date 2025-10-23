#!/bin/bash
# Script to install external-dns for quick iteration

# Exit on error
set -e

# shellcheck disable=SC2128
TUTORIAL_HOME=$(dirname "$BASH_SOURCE")
VALUES_FILE="$TUTORIAL_HOME/external-dns-alternative-values.yaml"

# --- Add the correct Helm repository ---
echo "Adding the kubernetes-sigs Helm repository..."
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo update

# --- Create namespaces ---
echo "Ensuring namespaces exist..."
kubectl create ns central --context mrc-central --dry-run=client -o yaml | kubectl apply --context mrc-central -f -
kubectl create ns east --context mrc-east --dry-run=client -o yaml | kubectl apply --context mrc-east -f -
kubectl create ns west --context mrc-west --dry-run=client -o yaml | kubectl apply --context mrc-west -f -

echo "Installing external-dns..."

# --- Install external-dns for each region using the CORRECT chart ---
echo "Installing external-dns for central region..."
helm upgrade --install external-dns external-dns/external-dns \
  -f "$VALUES_FILE" \
  --set txtOwnerId=mrc-central \
  -n central --kube-context mrc-central  --debug

echo "Installing external-dns for east region..."
helm upgrade --install external-dns external-dns/external-dns \
  -f "$VALUES_FILE" \
  --set txtOwnerId=mrc-east \
  -n east --kube-context mrc-east  --debug

echo "Installing external-dns for west region..."
helm upgrade --install external-dns external-dns/external-dns \
  -f "$VALUES_FILE" \
  --set txtOwnerId=mrc-west \
  -n west --kube-context mrc-west  --debug

echo "External-DNS installation completed!"
