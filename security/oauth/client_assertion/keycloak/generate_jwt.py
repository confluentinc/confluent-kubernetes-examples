import jwt
import time
import uuid
import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend

def load_private_key(path):
    with open(path, "rb") as f:
        key_data = f.read()
        print("🔍 Key starts with:", key_data[:30])
        return serialization.load_pem_private_key(
            key_data, password=None, backend=default_backend()
        )

def create_jwt(private_key, client_id, token_endpoint):
    now = int(time.time())
    claims = {
        "iss": client_id,
        "sub": client_id,
        "aud": token_endpoint,
        "jti": str(uuid.uuid4()),
        "iat": now,
        "exp": now + 864000
    }

    pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    )

    token = jwt.encode(claims, pem, algorithm="RS256")
    print("\n🧾 Client Assertion JWT:\n", token)
    return token

def get_access_token(jwt_token, token_endpoint, client_id):
    """Get OAuth2 access token using JWT client assertion"""
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    data = {
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": jwt_token
    }

    response = requests.post(token_endpoint, data=data, headers=headers)

    if response.status_code != 200:
        print("❌ Failed to get access token")
        print(f"Status code: {response.status_code}")
        print(f"Response: {response.text}")
        response.raise_for_status()

    return response.json()


def main():
    client_id = "private-key-client"
    realm = "sso_test"
    keycloak_url = "http://keycloak.operator.svc.cluster.local:8080"
    token_endpoint = f"{keycloak_url}/realms/{realm}/protocol/openid-connect/token"
    private_key_path = "private_key.pem"

    private_key = load_private_key(private_key_path)
    jwt_token = create_jwt(private_key, client_id, token_endpoint)

    # Use client assertion to get OAuth2 access token
    access_token_response = get_access_token(jwt_token, token_endpoint, client_id)

    print("\n🔑 OAuth Access Token Response:")
    print(access_token_response)

if __name__ == "__main__":
    main()
