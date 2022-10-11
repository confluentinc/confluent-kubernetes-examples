#!/bin/bash

#
# Copyright 2022 Confluent Inc.
#
set -uex

NAMESPACE=$1
CERT_DIR=$2

[ $# -ne 2 ] && { echo "Usage: $0 <NAMESPACE> <CERT_DIR>"; exit 1; }

cat > ${CERT_DIR}/ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "43800h"
    },
    "profiles": {
      "server": {
        "expiry": "43800h",
        "usages": [
          "signing",
          "key encipherment",
          "server auth",
          "client auth"
        ]
      },
      "client": {
        "expiry": "43800h",
        "usages": [
          "signing",
          "key encipherment",
          "client auth"
        ]
      }
    }
  }
}
EOF

cat > ${CERT_DIR}/server-csr.json <<EOF
{
  "CN": "",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "CA",
      "O": "Confluent",
      "ST": "Palo Alto"
    }
  ]
}
EOF

# Generate Certficate
cfssl gencert \
  -ca=${CERT_DIR}/cpc-ca.pem \
  -ca-key=${CERT_DIR}/cpc-ca-key.pem \
  -config=${CERT_DIR}/ca-config.json \
  -hostname=cpc-orchestrator.${NAMESPACE}.svc \
  -profile=server \
  ${CERT_DIR}/server-csr.json | cfssljson -bare ${CERT_DIR}/server
