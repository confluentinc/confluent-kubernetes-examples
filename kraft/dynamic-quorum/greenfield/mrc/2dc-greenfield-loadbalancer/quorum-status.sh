#!/bin/bash
# Quick quorum status check — exec into KRaft pod, generate admin config, run replication
REGION1_NS="${REGION1_NS:-central}"
REGION1_CONTEXT="${REGION1_CONTEXT:-<your-region1-k8s-context>}"

kubectl --context "$REGION1_CONTEXT" exec kraftcontroller-0 -n "$REGION1_NS" -- bash -c '
cp /opt/confluentinc/etc/kafka/kafka.properties /tmp/admin.properties
cat >> /tmp/admin.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="kafka" password="kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
ssl.truststore.type=PKCS12
EOF
echo "=== Quorum Replication ==="
kafka-metadata-quorum --bootstrap-controller localhost:9074 --command-config /tmp/admin.properties describe --replication
'
