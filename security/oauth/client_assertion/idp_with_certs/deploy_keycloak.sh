#!/bin/bash

set -euo pipefail

KEYCLOAK_NS="operator"
KEYCLOAK_DEPLOY_FILE="keycloak_deploy.yaml"
REALM_TEMPLATE_FILE="realm_template.json"
REALM_FINAL_FILE="realm.json"
PRIVATE_KEY_FILE="private_key.pem"
PUBLIC_KEY_FILE="public_key.pem"
ENCRYPTED_PRIVATE_KEY_FILE="encrypted_private_key.pem"
PASSPHRASE_FILE="private_key_passphrase.yaml"
PRIVATE_KEY_PASSPHRASE="abcde12345"

echo "🔐 Generating RSA key pair..."
openssl genpkey -algorithm RSA -out "$PRIVATE_KEY_FILE"
openssl rsa -in "$PRIVATE_KEY_FILE" -pubout -out "$PUBLIC_KEY_FILE"

# Encrypt the private key into PKCS#8 format
echo "🔐 Encrypting private key into PKCS#8 format..."
openssl pkcs8 -topk8 -in "$PRIVATE_KEY_FILE" -out "$ENCRYPTED_PRIVATE_KEY_FILE" -v1 PBE-SHA1-3DES -passout pass:"$PRIVATE_KEY_PASSPHRASE"
openssl pkcs8 -topk8 -v2 aes-256-cbc -in "$PRIVATE_KEY_FILE" -out "encrypted_private_key_v2.pem" -passout pass:"$PRIVATE_KEY_PASSPHRASE"

# Prepare passphrase YAML
echo "🔑 Preparing passphrase file..."
cat <<EOF > "$PASSPHRASE_FILE"
privateKeyPassphrase: $PRIVATE_KEY_PASSPHRASE
EOF

# Create Kubernetes Secret with both encrypted private key and passphrase
echo "📦 Creating Secret with encrypted private key and passphrase..."
kubectl create secret generic private-key-encrypted \
  --namespace operator \
  --from-file=private-key=encrypted_private_key.pem \
  --from-file=private-key-passphrase=private_key_passphrase.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic private-key-encrypted-v2 \
  --namespace operator \
  --from-file=private-key=encrypted_private_key_v2.pem \
  --from-file=private-key-passphrase=private_key_passphrase.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

echo "📦 Creating Secret with private key..."
kubectl create secret generic private-key \
  --namespace operator \
  --from-file=private-key=private_key.pem \
  --dry-run=client -o yaml | kubectl apply -f -

# Create Kubernetes Secret for public key
echo "📦 Creating Secret for public key..."
kubectl create secret generic keycloak-public-key \
  --namespace "$KEYCLOAK_NS" \
  --from-file=public-key="$PUBLIC_KEY_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

# Escape the public key content for JSON
ESCAPED_PUBKEY=$(awk '{ printf "%s\\\\n", $0 }' "$PUBLIC_KEY_FILE")

# Replace placeholder in realm template
cp "$REALM_TEMPLATE_FILE" "$REALM_FINAL_FILE"
sed -i.bak "s|__JWT_PUBLIC_KEY_PEM__|$ESCAPED_PUBKEY|g" "$REALM_FINAL_FILE"

# Create ConfigMap with the processed realm.json
echo "🔧 Creating ConfigMap with injected public key..."
kubectl create configmap keycloak-configmap \
  --namespace "$KEYCLOAK_NS" \
  --from-file=realm.json="$REALM_FINAL_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy Keycloak
echo "🚀 Deploying Keycloak..."
kubectl apply -f "$KEYCLOAK_DEPLOY_FILE"

echo "✅ Deployment complete. Public key injected successfully."
echo "🔐 Encrypted private key and passphrase are stored in secret: private-key and private-key-encrypted."
