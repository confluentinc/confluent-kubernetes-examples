# Gateway TLS Certificate Generation Guide

This guide provides instructions for:
- Generating self-signed TLS certificates for CPC Gateway.
- Creating Kubernetes secret required by Gateway deployment for enabling Client to Gateway TLS.

## Prerequisites

- OpenSSL installed on your system
- `kubectl` configured with access to your Kubernetes cluster
- Target namespace created (default: `confluent`)

## Certificate Generation Steps

### Step 1: Generate Certificate Authority (CA)

- Create a private key for the Certificate Authority:

```
openssl genrsa -out ca-key.pem 2048
```
- Generate the CA certificate:

```
openssl req -x509 -new -nodes \
    -key ca-key.pem \
    -sha256 \
    -days 365 \
    -out cacerts.pem \
    -subj "/C=US/ST=CA/L=Mountain View/O=Confluent/OU=Engineering/CN=Gateway Test CA"
```
### Step 2: Generate Gateway Server Certificate

- Create a private key for the Gateway:

```
openssl genrsa -out privkey.pem 2048
```

- Create a certificate signing request (CSR):

```
openssl req -new \
    -key privkey.pem \
    -out gateway.csr \
    -subj "/C=US/ST=CA/L=Mountain View/O=Confluent/OU=Engineering/CN=gateway.example.com"
```
### Step 3: Sign the Gateway Certificate with SANs

- Sign the certificate with the CA and add Subject Alternative Names (SANs):

```
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
```

- Clean up the CSR file:

```
rm gateway.csr
```

### Step 4: Create Full Certificate Chain

- Concatenate the Gateway certificate with the CA certificate:

```
cat gateway.pem cacerts.pem > fullchain.pem
```

### Step 5: Create Kubernetes Secret

Create a Kubernetes secret containing the certificates:

```
kubectl create secret generic gateway-tls \
    --from-file=fullchain.pem=fullchain.pem \
    --from-file=cacerts.pem=cacerts.pem \
    --from-file=privkey.pem=privkey.pem \
    --namespace confluent
```

## Cleanup

To remove the certificates and secret:

- Remove local certificate files
```
rm -f ca-key.pem cacerts.pem privkey.pem gateway.pem fullchain.pem cacerts.srl
```

- Delete Kubernetes secret
```
kubectl delete secret gateway-tls -n confluent
```

