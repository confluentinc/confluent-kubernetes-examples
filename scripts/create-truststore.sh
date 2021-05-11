#!/bin/bash
set -e

pem=$1
jksPassword=$2
[[ $# -ne 2 ]] && {
	echo "Usage: $0 <CA_pem_file_to_add_in_truststore or Fullchain_pem_file> and <jksPassword>";
	echo -e "\tCA_pem_file_to_add_in_truststore: CA certificate";
  echo -e "\tFullchain_pem_file: Includes CA & Certificate of server or client to trust";
  exit 1;
}

if [[ -e ./jks/truststore.jks ]];then
  rm ./jks/truststore.jks
else
  mkdir -p jks
fi

rm -rf /tmp/trustCAs
mkdir /tmp/trustCAs
# shellcheck disable=SC2002
cat "${pem}" | awk 'split_after==1{n++;split_after=0} /-----END CERTIFICATE-----/ {split_after=1} {print > ("/tmp/trustCAs/ca" n ".pem")}'
for file in /tmp/trustCAs/*; do
  fileName="${file##*/}"
  keytool -import \
        -trustcacerts \
        -alias "${fileName}" \
        -file "${file}" \
	-keystore ./jks/truststore.jks \
	-deststorepass "${jksPassword}" \
  -deststoretype pkcs12 \
	-noprompt
done
echo "Validate truststore"
keytool -list -v -keystore ./jks/truststore.jks -storepass "${jksPassword}"
