## Introduction
This playbook deploys keycloak with a client having support for JWT assertion flow.

## Deploy Keycloak with JWT Client Automatically
```bash
chmod +x deploy_keycloak.sh
./deploy_keycloak.sh
```
The deployment process will automatically:
- Create necessary Kubernetes secrets
- Inject the public key into the Keycloak configuration
- Set up the realm with JWT assertion support

## Deploy Keycloak with JWT Client Manually

### Step 1: Generate RSA Key Pair
```bash
# Generate private key
openssl genpkey -algorithm RSA -out private_key.pem

# Generate public key from private key
openssl rsa -in private_key.pem -pubout -out public_key.pem
```

### Step 2: Create JWT Client in Keycloak
Deploy Keycloak and once it is running, create a client that uses private_key_jwt for authentication and add above created public key to it.

## Testing
Generate OAuth token using generate_jwt.py

```bash
python generate_jwt.py
```

Once you have the token, you can use it to validate different CP flows.
