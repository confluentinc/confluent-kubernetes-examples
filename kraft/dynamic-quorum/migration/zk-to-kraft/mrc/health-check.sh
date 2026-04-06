#!/bin/bash
# Health check: create topic, produce 1-10, consume and verify
# Uses SASL/PLAIN + TLS on external listener (public DNS)

REGION1_CONTEXT="${REGION1_CONTEXT:-<your-region1-k8s-context>}"
REGION1_NS="${REGION1_NS:-central}"
DOMAIN="my-domain.example.com"
BOOTSTRAP="kafka-central-ext.${DOMAIN}:9092"
TOPIC="health-check-$(date +%s)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

OUTPUT=$(kubectl --context "$REGION1_CONTEXT" exec kafka-0 -n "$REGION1_NS" -- bash -c "
cat > /tmp/client.properties <<'EOF'
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"kafka\" password=\"kafka-secret\";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
ssl.truststore.type=PKCS12
EOF

kafka-topics --bootstrap-server ${BOOTSTRAP} --command-config /tmp/client.properties \
  --create --topic ${TOPIC} --partitions 3 --replication-factor 2 >/dev/null 2>&1

echo '=== Produced ==='
for i in \$(seq 1 10); do echo \$i; done | \
  kafka-console-producer --bootstrap-server ${BOOTSTRAP} \
  --producer.config /tmp/client.properties --topic ${TOPIC} 2>/dev/null
for i in \$(seq 1 10); do echo \"  \$i\"; done

echo '=== Consumed ==='
timeout 15 kafka-console-consumer --bootstrap-server ${BOOTSTRAP} \
  --consumer.config /tmp/client.properties --topic ${TOPIC} \
  --from-beginning --max-messages 10 2>/dev/null | while read line; do echo \"  \$line\"; done
" 2>&1)

echo "$OUTPUT"

PRODUCED=$(echo "$OUTPUT" | sed -n '/=== Produced ===/,/=== Consumed ===/p' | grep -c '^ ')
CONSUMED=$(echo "$OUTPUT" | sed -n '/=== Consumed ===/,$p' | grep -c '^ ')

echo ""
if [ "$PRODUCED" -eq 10 ] && [ "$CONSUMED" -eq 10 ]; then
    echo -e "${GREEN}Health check passed (produced=$PRODUCED, consumed=$CONSUMED)${NC}"
else
    echo -e "${RED}Health check failed (produced=$PRODUCED, consumed=$CONSUMED)${NC}"
fi
