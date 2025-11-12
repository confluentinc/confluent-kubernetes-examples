# Gateway TLS Certificate Generation Guide

This guide provides instructions for:
- Generating self-signed TLS certificates for CPC Gateway.
- Creating Kubernetes secret required by Gateway deployment for enabling Client to Gateway TLS.
- Creating client truststore for TLS connections.
- Creating client certificates and keystores for mutual TLS (mTLS) authentication.

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

- Create a Kubernetes secret containing the certificates:

```
kubectl create secret generic gateway-tls \
    --from-file=fullchain.pem=fullchain.pem \
    --from-file=cacerts.pem=cacerts.pem \
    --from-file=privkey.pem=privkey.pem \
    --namespace confluent
```

## Client TLS Configuration

If you want clients to connect to the Gateway over TLS, clients need a truststore to verify the Gateway's certificate.

### Step 6: Create Client Truststore

- Create a JKS truststore containing the CA certificate:

```
keytool -keystore client-truststore.jks \
    -alias CARoot \
    -import \
    -file cacerts.pem \
    -storepass clienttrustpass \
    -noprompt
```

- Verify the truststore:

```
keytool -list -keystore client-truststore.jks -storepass clienttrustpass
```

**Note:** Update the truststore path to match where you store your truststore file.

## Client mTLS Configuration (Optional - for Mutual Authentication)

If you want to enable mutual TLS (mTLS) authentication where the Gateway also verifies the client's identity via certificate, follow these additional steps.

### Step 7: Generate Client Certificate

- Create a private key for the client:

```
openssl genrsa -out client-key.pem 2048
```

- Create a certificate signing request (CSR) for the client:

**Note:** The CN (Common Name) should match the username you want to use for authentication. For example, if your auth swap maps `alice` to `bob`, use `CN=alice`.

```
openssl req -new \
    -key client-key.pem \
    -out client.csr \
    -subj "/C=US/ST=CA/L=Mountain View/O=Confluent/OU=Engineering/CN=alice"
```

- Sign the client certificate with the same CA:

```
openssl x509 -req \
    -in client.csr \
    -CA cacerts.pem \
    -CAkey ca-key.pem \
    -CAcreateserial \
    -out client-cert.pem \
    -days 365 \
    -sha256
```

- Clean up the CSR file:

```
rm client.csr
```

### Step 8: Create Client Keystore

The client needs a keystore containing its certificate and private key for mTLS authentication.

- Convert client certificate and key to PKCS12 format:

```
openssl pkcs12 -export \
    -in client-cert.pem \
    -inkey client-key.pem \
    -out client-keystore.p12 \
    -name client \
    -passout pass:clientkeypass
```

- Create JKS keystore from PKCS12:

```
keytool -importkeystore \
    -srckeystore client-keystore.p12 \
    -srcstoretype PKCS12 \
    -srcstorepass clientkeypass \
    -destkeystore client-keystore.jks \
    -deststoretype JKS \
    -deststorepass clientkeypass \
    -noprompt
```

- Verify the keystore:

```
keytool -list -keystore client-keystore.jks -storepass clientkeypass
```

**Note:** Update the paths to match where you store your keystore and truststore files.

## Certificate Verification

To verify your certificates:

### Verify Gateway Certificate

```bash
# Check certificate subject and SANs
openssl x509 -in gateway.pem -noout -subject -ext subjectAltName

# Check certificate validity dates
openssl x509 -in gateway.pem -noout -dates

# Verify certificate chain
openssl verify -CAfile cacerts.pem gateway.pem
```

### Verify Client Certificate (if using mTLS)

```bash
# Check certificate subject (CN should match your username)
openssl x509 -in client-cert.pem -noout -subject

# Check certificate validity dates
openssl x509 -in client-cert.pem -noout -dates

# Verify certificate is signed by the correct CA
openssl verify -CAfile cacerts.pem client-cert.pem
```

## Cleanup

To remove all certificates and secrets:

### Remove Gateway Certificates

```
rm -f ca-key.pem cacerts.pem privkey.pem gateway.pem fullchain.pem cacerts.srl
```

### Remove Client Certificates (if created)

```
rm -f client-key.pem client-cert.pem client-keystore.p12 client-keystore.jks client-truststore.jks
rm -f client-tls.properties client-mtls.properties
```

### Delete Kubernetes Secret

```
kubectl delete secret gateway-tls -n confluent
```

