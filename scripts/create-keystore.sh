#!/usr/bin/env bash
set -C -e -o pipefail

server=$1
serverKey=$2
password=$3
[ $# -ne 3 ] && { echo "Usage: $0 <fullchain_pem_file> <private_key> <jks_password>"; exit 1; }

if [ -e ./jks/keystore.jks ];then
  rm  ./jks/keystore.jks
else
  mkdir -p jks
fi
rm -rf /tmp/trustCAs
mkdir /tmp/trustCAs

echo "Check $server certificate"
openssl x509 -in "${server}" -text -noout
openssl pkcs12 -export \
	-in "${server}" \
	-inkey "${serverKey}" \
	-out ./jks/pkcs.p12 \
	-name testService \
	-passout pass:mykeypassword

keytool -importkeystore \
	-deststorepass "${password}" \
	-destkeypass "${password}" \
	-destkeystore ./jks/keystore.jks \
	-deststoretype pkcs12 \
	-srckeystore ./jks/pkcs.p12 \
	-srcstoretype PKCS12 \
	-srcstorepass mykeypassword

echo "Validate Keystore"
keytool -list -v -keystore ./jks/keystore.jks -storepass "${password}"