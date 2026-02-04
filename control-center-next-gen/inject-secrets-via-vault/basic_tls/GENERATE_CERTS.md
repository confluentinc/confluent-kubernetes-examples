# Certificate Generation for Example 3: Combined Basic Auth + TLS

This document provides step-by-step instructions to generate self-signed TLS certificates for the Combined Basic Auth + TLS example.

## Prerequisites

- OpenSSL installed on your local machine
- Access to create files in the current directory

## Step 1: Create Certificates Directory

```bash
mkdir -p certs
cd certs
```

## Step 2: Generate CA Certificate

```bash
# Generate CA private key
openssl genrsa -out ca.key 4096

# Generate CA certificate
openssl req -x509 -new -nodes -key ca.key -sha256 -days 365 \
  -out ca.crt \
  -subj "/CN=Confluent-CA/O=Confluent/C=US"
```

## Step 3: Generate Prometheus Server Certificate

### Create CSR Configuration

```bash
cat > prometheus-csr.conf << 'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = controlcenter-next-gen.vault-example-3.svc.cluster.local
O = Confluent
C = US

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = controlcenter-next-gen
DNS.2 = controlcenter-next-gen.vault-example-3
DNS.3 = controlcenter-next-gen.vault-example-3.svc
DNS.4 = controlcenter-next-gen.vault-example-3.svc.cluster.local
DNS.5 = *.controlcenter-next-gen.vault-example-3.svc.cluster.local
DNS.6 = localhost
IP.1 = 127.0.0.1
EOF
```

### Generate Certificate

```bash
# Generate private key
openssl genrsa -out prometheus-tls.key 2048

# Generate CSR
openssl req -new -key prometheus-tls.key \
  -out prometheus-tls.csr \
  -config prometheus-csr.conf

# Sign certificate with CA
openssl x509 -req -in prometheus-tls.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out prometheus-tls.crt -days 365 -sha256 \
  -extensions req_ext -extfile prometheus-csr.conf
```

## Step 4: Generate AlertManager Server Certificate

### Create CSR Configuration

```bash
cat > alertmanager-csr.conf << 'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = controlcenter-next-gen.vault-example-3.svc.cluster.local
O = Confluent
C = US

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = controlcenter-next-gen
DNS.2 = controlcenter-next-gen.vault-example-3
DNS.3 = controlcenter-next-gen.vault-example-3.svc
DNS.4 = controlcenter-next-gen.vault-example-3.svc.cluster.local
DNS.5 = *.controlcenter-next-gen.vault-example-3.svc.cluster.local
DNS.6 = localhost
IP.1 = 127.0.0.1
EOF
```

### Generate Certificate

```bash
# Generate private key
openssl genrsa -out alertmanager-tls.key 2048

# Generate CSR
openssl req -new -key alertmanager-tls.key \
  -out alertmanager-tls.csr \
  -config alertmanager-csr.conf

# Sign certificate with CA
openssl x509 -req -in alertmanager-tls.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out alertmanager-tls.crt -days 365 -sha256 \
  -extensions req_ext -extfile alertmanager-csr.conf
```

## Step 5: Create Fullchain Certificates

CFK expects fullchain certificates (server cert + CA chain):

```bash
# Create Prometheus fullchain
cat prometheus-tls.crt ca.crt > prometheus-fullchain.pem

# Create AlertManager fullchain
cat alertmanager-tls.crt ca.crt > alertmanager-fullchain.pem

# Copy keys with .pem extension
cp prometheus-tls.key prometheus-privkey.pem
cp alertmanager-tls.key alertmanager-privkey.pem
```

## Step 6: Cleanup Temporary Files

```bash
rm -f *.csr *.conf *.srl
cd ..
```

## Step 7: Verify Certificates

```bash
# Verify Prometheus certificate
openssl x509 -in certs/prometheus-tls.crt -noout -text | grep -A1 "Subject Alternative Name"

# Verify AlertManager certificate
openssl x509 -in certs/alertmanager-tls.crt -noout -text | grep -A1 "Subject Alternative Name"

# Verify CA
openssl x509 -in certs/ca.crt -noout -subject -dates
```

## Expected Files

After completing these steps, you should have:

```
certs/
├── ca.crt                      # CA certificate
├── ca.key                      # CA private key
├── prometheus-tls.crt          # Prometheus server certificate
├── prometheus-tls.key          # Prometheus server private key
├── prometheus-fullchain.pem    # Prometheus cert + CA chain
├── prometheus-privkey.pem      # Prometheus private key (copy)
├── alertmanager-tls.crt        # AlertManager server certificate
├── alertmanager-tls.key        # AlertManager server private key
├── alertmanager-fullchain.pem  # AlertManager cert + CA chain
└── alertmanager-privkey.pem    # AlertManager private key (copy)
```

## Files Used by Vault

The following files will be stored in Vault:

| File | Vault Path | Key |
|------|------------|-----|
| `prometheus-fullchain.pem` | `secret/confluent/prometheus-tls` | `fullchain.pem` |
| `prometheus-privkey.pem` | `secret/confluent/prometheus-tls` | `privkey.pem` |
| `alertmanager-fullchain.pem` | `secret/confluent/alertmanager-tls` | `fullchain.pem` |
| `alertmanager-privkey.pem` | `secret/confluent/alertmanager-tls` | `privkey.pem` |
| `ca.crt` | `secret/confluent/ca` | `ca.crt` |

## Next Steps

After generating certificates, follow [VAULT_SETUP.md](VAULT_SETUP.md) to store them in Vault.
