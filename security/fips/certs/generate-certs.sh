#!/bin/bash
# Exit immediately if any command fails, if any variable is undefined, or on pipeline errors.
set -euo pipefail

# --- Default Variable Declarations ---
CERTS_HOME="${CERTS_HOME:-$(dirname "$(readlink -f "$0")")/generated}"                    # Directory where certificates will be generated
CP_NS="${CP_NS:-confluent}"                                                               # Confluent namespace
PASSWD="${PASSWD:-mystorepassword}"                                                      # Password for keystores, if modified, update the same in the fips-tls K8s secret
LOCAL_DOMAIN="${LOCAL_DOMAIN:-svc.cluster.local}"                                         # Local domain used in server JSON
EXTERNAL_DOMAIN="${EXTERNAL_DOMAIN:-svc.ps.cflt.inc}"                                     # External domain used in server JSON
BC_VERSION="${BC_VERSION:-1.0.2.3}"                                                       # Bouncy Castle version
BC_JAR="bc-fips-${BC_VERSION}.jar"                                                        # Bouncy Castle JAR file name
BC_URL="https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/${BC_VERSION}/${BC_JAR}"  # Download URL for Bouncy Castle
BC_JAR_PATH="${CERTS_HOME}/${BC_JAR}"                                                     # Path where the JAR will be stored

# --- Print Environment Variables ---
echo "--------------------------------------------"
echo "Environment Variables:"
echo "CERTS_HOME set to: ${CERTS_HOME}"
echo "CP_NS set to: ${CP_NS}"
echo "PASSWD set to: ${PASSWD}"
echo "LOCAL_DOMAIN set to: ${LOCAL_DOMAIN}"
echo "EXTERNAL_DOMAIN set to: ${EXTERNAL_DOMAIN}"
echo "BC_VERSION set to: ${BC_VERSION}"
echo "BC_JAR set to: ${BC_JAR}"
echo "BC_URL set to: ${BC_URL}"
echo "BC_JAR_PATH set to: ${BC_JAR_PATH}"
echo "--------------------------------------------\n"

# --- Create CERTS_HOME directory if it doesn't exist ---
if [ ! -d "${CERTS_HOME}" ]; then
  echo "Creating directory ${CERTS_HOME}..."
  mkdir -p "${CERTS_HOME}"
  echo "Directory ${CERTS_HOME} created."
else
  echo "Directory ${CERTS_HOME} already exists."
  rm -rf "${CERTS_HOME}"
  echo "Cleared contents of ${CERTS_HOME}."
  mkdir -p "${CERTS_HOME}"
  echo "Directory ${CERTS_HOME} created."
fi
echo "--------------------------------------------\n"

# --- Check for required commands ---
for cmd in openssl cfssl cfssljson keytool curl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Error: ${cmd} is required but not installed. Aborting."
    exit 1
  fi
done

# =========================
# Generate Certificate Authority
# =========================
echo "Generating Certificate Authority..."
echo "Generating root CA key..."
openssl genrsa -out "${CERTS_HOME}/rootCAkey.pem" 2048
echo "Generating self-signed CA certificate..."
openssl req -x509 -new -nodes \
  -key "${CERTS_HOME}/rootCAkey.pem" \
  -days 3650 \
  -out "${CERTS_HOME}/cacerts.pem" \
  -subj "/C=US/ST=CA/L=Mountain View/O=ConfluentInc/OU=CSG/CN=Confluent-PS-Test-CA"
echo "Displaying CA certificate details..."
openssl x509 -in "${CERTS_HOME}/cacerts.pem" -text -noout
echo "Certificate Authority generation complete."
echo "--------------------------------------------\n"

# =========================
# Generate ca-config.json
# =========================
echo "Generating ca-config.json..."
cat <<EOF > "${CERTS_HOME}/ca-config.json"
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "server": {
        "usages": [
          "signing",
          "key encipherment",
          "server auth",
          "client auth"
        ],
        "expiry": "8760h"
      },
      "client": {
        "usages": [
          "signing",
          "key encipherment",
          "client auth"
        ],
        "expiry": "8760h"
      }
    }
  }
}
EOF

echo "Displaying contents of ca-config.json:"
cat "${CERTS_HOME}/ca-config.json"
echo "ca-config.json generated."
echo "--------------------------------------------\n"

# =========================
# Create common server domain JSON for all components
# =========================
echo "Generating common server domain JSON..."
cat <<EOF > "${CERTS_HOME}/confluent-ps-fips-server-domain.json"
{
  "CN": "confluent-ps-fips",
  "hosts": [
    "localhost",
    "confluent-ps-fips",
    "*.${CP_NS}.${LOCAL_DOMAIN}",
    "*.kraftcontroller.${CP_NS}.${LOCAL_DOMAIN}",
    "*.kafka.${CP_NS}.${LOCAL_DOMAIN}",
    "*.schemaregistry.${CP_NS}.${LOCAL_DOMAIN}",
    "*.connect.${CP_NS}.${LOCAL_DOMAIN}",
    "*.ksqldb.${CP_NS}.${LOCAL_DOMAIN}",
    "*.kafkarestproxy.${CP_NS}.${LOCAL_DOMAIN}",
    "*.controlcenter.${CP_NS}.${LOCAL_DOMAIN}",
    "*.prometheus.${CP_NS}.${LOCAL_DOMAIN}",
    "*.alertmanager.${CP_NS}.${LOCAL_DOMAIN}",
    "*.${EXTERNAL_DOMAIN}",
    "*.${CP_NS}.${EXTERNAL_DOMAIN}",
    "*.kraftcontroller.${CP_NS}.${EXTERNAL_DOMAIN}",
    "*.kafka.${CP_NS}.${EXTERNAL_DOMAIN}",
    "*.schemaregistry.${EXTERNAL_DOMAIN}",
    "*.connect.${CP_NS}.${EXTERNAL_DOMAIN}",
    "*.ksqldb.${EXTERNAL_DOMAIN}",
    "*.kafkarestproxy.${CP_NS}.${EXTERNAL_DOMAIN}",
    "*.controlcenter.${EXTERNAL_DOMAIN}",
    "*.prometheus.${EXTERNAL_DOMAIN}",
    "*.alertmanager.${EXTERNAL_DOMAIN}"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "ST": "CA",
      "L": "Mountain",
      "O": "ConfluentInc",
      "OU": "CSG"
    }
  ]
}
EOF

echo "Displaying contents of confluent-ps-fips-server-domain.json:"
cat "${CERTS_HOME}/confluent-ps-fips-server-domain.json"
echo "Server domain JSON generated."
echo "--------------------------------------------\n"

# =========================
# Generate and Verify Certificate
# =========================
echo "Generating server certificate using cfssl..."
cfssl gencert -ca="${CERTS_HOME}/cacerts.pem" \
  -ca-key="${CERTS_HOME}/rootCAkey.pem" \
  -config="${CERTS_HOME}/ca-config.json" \
  -profile=server \
  "${CERTS_HOME}/confluent-ps-fips-server-domain.json" | cfssljson -bare "${CERTS_HOME}/confluent-ps-fips-server"
echo "Server certificate generated."

echo "Creating full chain certificate..."
cat "${CERTS_HOME}/confluent-ps-fips-server.pem" "${CERTS_HOME}/cacerts.pem" > "${CERTS_HOME}/confluent-ps-fips-fullchain.pem"
echo "Full chain certificate created."

echo "Verifying server certificate (grep DNS entries)..."
openssl x509 -in "${CERTS_HOME}/confluent-ps-fips-server.pem" -text -noout | grep "DNS:"
echo "--------------------------------------------\n"

# =========================
# Create FIPS-compliant Keystores
# =========================
echo "Downloading Bouncy Castle JAR..."
curl -o "${BC_JAR_PATH}" "${BC_URL}"
echo "Downloaded Bouncy Castle JAR:"
ls -l "${BC_JAR_PATH}"
echo "--------------------------------------------\n"

echo "Creating Bouncy Castle truststore (BCFKS format)..."
keytool -noprompt -keystore "${CERTS_HOME}/confluent-ps-fips-truststore.bcfks" \
    -storetype BCFKS \
    -alias CARoot \
    -import -file "${CERTS_HOME}/cacerts.pem" \
    -storepass "${PASSWD}" \
    -keypass "${PASSWD}" \
    -providerclass org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
    -providerpath "${BC_JAR_PATH}"
echo "Truststore created."

echo "Inspecting BCFKS truststore contents..."
keytool -list -keystore "${CERTS_HOME}/confluent-ps-fips-truststore.bcfks" \
    -storepass "${PASSWD}" -v \
    -keypass "${PASSWD}" \
    -storetype BCFKS \
    -providerclass org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
    -providerpath "${BC_JAR_PATH}"
echo "--------------------------------------------\n"

echo "Exporting server full chain and key into a PKCS12 file..."
openssl pkcs12 -export \
    -in "${CERTS_HOME}/confluent-ps-fips-fullchain.pem" \
    -inkey "${CERTS_HOME}/confluent-ps-fips-server-key.pem" \
    -out "${CERTS_HOME}/confluent-ps-fips-fullchain.p12" \
    -name localhost \
    -passout pass:"${PASSWD}"
echo "PKCS12 file created."

echo "Creating Bouncy Castle keystore from PKCS12 file..."
keytool -importkeystore \
    -srckeystore "${CERTS_HOME}/confluent-ps-fips-fullchain.p12" \
    -srcstoretype pkcs12 \
    -srcstorepass "${PASSWD}" \
    -destkeystore "${CERTS_HOME}/confluent-ps-fips-keystore.bcfks" \
    -deststorepass "${PASSWD}" \
    -destkeypass "${PASSWD}" \
    -deststoretype BCFKS \
    -providername BCFIPS \
    -providerclass org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
    -providerpath "${BC_JAR_PATH}"
echo "BCFKS keystore created."

echo "Importing CA certificate into BCFKS keystore..."
keytool -noprompt -keystore "${CERTS_HOME}/confluent-ps-fips-keystore.bcfks" \
    -storetype BCFKS \
    -alias CARoot \
    -import -file "${CERTS_HOME}/cacerts.pem" \
    -storepass "${PASSWD}" \
    -keypass "${PASSWD}" \
    -providerclass org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
    -providerpath "${BC_JAR_PATH}"
echo "CA imported into BCFKS keystore."

echo "Inspecting BCFKS keystore contents..."
keytool -list -keystore "${CERTS_HOME}/confluent-ps-fips-keystore.bcfks" \
    -storepass "${PASSWD}" -v \
    -keypass "${PASSWD}" \
    -storetype BCFKS \
    -providerclass org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
    -providerpath "${BC_JAR_PATH}"
echo "--------------------------------------------\n"

echo "Creating PKCS12 truststore..."
keytool -noprompt -keystore "${CERTS_HOME}/confluent-ps-fips-truststore.jks" \
    -storetype pkcs12 \
    -alias CARoot \
    -import -file "${CERTS_HOME}/cacerts.pem" \
    -storepass "${PASSWD}" \
    -keypass "${PASSWD}"
echo "PKCS12 truststore created."

echo "Inspecting PKCS12 truststore contents..."
keytool -list -keystore "${CERTS_HOME}/confluent-ps-fips-truststore.jks" \
    -storepass "${PASSWD}" \
    -keypass "${PASSWD}" \
    -storetype pkcs12
echo "--------------------------------------------\n"

echo "Creating PKCS12 keystore from PKCS12 file..."
keytool -importkeystore \
    -srckeystore "${CERTS_HOME}/confluent-ps-fips-fullchain.p12" \
    -srcstoretype pkcs12 \
    -srcstorepass "${PASSWD}" \
    -destkeystore "${CERTS_HOME}/confluent-ps-fips-keystore.jks" \
    -deststorepass "${PASSWD}" \
    -destkeypass "${PASSWD}" \
    -deststoretype pkcs12
echo "PKCS12 keystore created."

echo "Importing CA certificate into PKCS12 keystore..."
keytool -noprompt -keystore "${CERTS_HOME}/confluent-ps-fips-keystore.jks" \
    -storetype pkcs12 \
    -alias CARoot \
    -import -file "${CERTS_HOME}/cacerts.pem" \
    -storepass "${PASSWD}" \
    -keypass "${PASSWD}"
echo "CA imported into PKCS12 keystore."

echo "Inspecting PKCS12 keystore contents..."
keytool -list -keystore "${CERTS_HOME}/confluent-ps-fips-keystore.jks" \
    -storepass "${PASSWD}" \
    -keypass "${PASSWD}" \
    -storetype pkcs12
echo "--------------------------------------------\n"

echo "List the files in ${CERTS_HOME}:"
ls -lrt "${CERTS_HOME}"
echo "-----------------------------------------------------------\n"

echo "FIPS-complaint TLS certificates steps completed successfully."
echo "-----------------------------------------------------------\n"
