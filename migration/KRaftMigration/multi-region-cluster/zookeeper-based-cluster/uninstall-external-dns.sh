#!/bin/bash
# Script to uninstall external-dns for quick iteration

# Exit on error
set -e

echo "Uninstalling external-dns..."

# Uninstall external-dns from all regions
echo "Uninstalling external-dns from central region..."
helm uninstall external-dns -n central --kube-context mrc-central 2>/dev/null || echo "External-DNS central not found, skipping..."

echo "Uninstalling external-dns from east region..."
helm uninstall external-dns -n east --kube-context mrc-east 2>/dev/null || echo "External-DNS east not found, skipping..."

echo "Uninstalling external-dns from west region..."
helm uninstall external-dns -n west --kube-context mrc-west 2>/dev/null || echo "External-DNS west not found, skipping..."

echo "External-DNS uninstallation completed!"
