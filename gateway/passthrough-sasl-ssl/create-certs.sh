#!/bin/bash

# Certificate generation script for Gateway with TLS (PEM format)
# This script creates self-signed certificates for testing purposes

set -e

# "Generating TLS Certificates for Gateway"

# Generate CA private key
openssl genrsa -out ca-key.pem 2048

# Generate CA certificate
openssl req -x509 -new -nodes \
    -key ca-key.pem \
    -sha256 \
    -days 365 \
    -out cacerts.pem \
    -subj "/C=US/ST=CA/L=Mountain View/O=Confluent/OU=Engineering/CN=Gateway Test CA"


# Generate Gateway server certificate with multiple SANs for host-based routing
# DNS:gateway.example.com,DNS:*.gateway.example.com,DNS:broker0.gateway.example.com,DNS:broker1.gateway.example.com,DNS:broker2.gateway.example.com,DNS:localhost,IP:127.0.0.1"

# Create private key
openssl genrsa -out privkey.pem 2048

# Create certificate request
openssl req -new \
    -key privkey.pem \
    -out gateway.csr \
    -subj "/C=US/ST=CA/L=Mountain View/O=Confluent/OU=Engineering/CN=gateway.example.com"

# Sign certificate with CA using inline extensions
openssl x509 -req \
    -in gateway.csr \
    -CA cacerts.pem \
    -CAkey ca-key.pem \
    -CAcreateserial \
    -out gateway.pem \
    -days 365 \
    -sha256 \
    -extensions v3_req \
    -extfile <(
        printf "[v3_req]\n"
        printf "authorityKeyIdentifier=keyid,issuer\n"
        printf "basicConstraints=CA:FALSE\n"
        printf "keyUsage=digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment\n"
        printf "subjectAltName=DNS:gateway.example.com,DNS:*.gateway.example.com,DNS:broker0.gateway.example.com,DNS:broker1.gateway.example.com,DNS:broker2.gateway.example.com,DNS:localhost,IP:127.0.0.1\n"
    )

# Clean up
rm gateway.csr

# Create fullchain.pem
cat gateway.pem cacerts.pem > fullchain.pem


# Create Gateway TLS secret with PEM files
echo "Creating gateway-tls secret..."
kubectl create secret generic gateway-tls \
    --from-file=fullchain.pem=fullchain.pem \
    --from-file=cacerts.pem=cacerts.pem \
    --from-file=privkey.pem=privkey.pem \
    --namespace confluent \
    --dry-run=client -o yaml | kubectl apply -f -
