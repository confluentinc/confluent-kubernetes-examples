#!/bin/bash
# Dynamic Quorum Secured Setup with Confluent RBAC + LDAP
# Single namespace deployment with TLS + SASL/PLAIN + LDAP-based RBAC

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

print_cmd() {
    echo -e "  ${BLUE}→${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
}

ask_step() {
    while true; do
        read -p "$1 (y/n): " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

# Resolve the bootstrap-controller endpoint and advertised.listeners for a controller pod.
# Runs on the host (not inside the pod) so kubectl get is available.
#
# Priority order:
#   1. advertised.listeners in kafka.properties (CFK sets this when externalAccess is configured)
#   2. spec.controllerQuorumVoters[nodeId].brokerEndpoint in the KRaftController CR
#      (CFK populates this — correct for both pod FQDN and LoadBalancer DNS)
#   3. Hostname prefix match in controller.quorum.bootstrap.servers in kafka.properties
#      (fallback for single-namespace where no explicit voters are defined)
#
# Outputs two lines (parse with grep/cut — no eval needed):
#   SELF_ENDPOINT=host:port            (for --bootstrap-controller)
#   SELF_ADV_LISTENERS=NAME://host:port (for advertised.listeners in ctrl.properties)
#
# Usage:
#   _OUT=$(compute_controller_endpoints <pod> <namespace>)
#   SELF_ENDPOINT=$(echo "$_OUT"        | grep "^SELF_ENDPOINT="        | cut -d= -f2-)
#   SELF_ADV_LISTENERS=$(echo "$_OUT"   | grep "^SELF_ADV_LISTENERS="   | cut -d= -f2-)
compute_controller_endpoints() {
    local POD=$1 NS=$2
    local FIELDS NODE_ID HOST BS CTRL_NAME ADV ENDPOINT
    # Single exec — grab all fields we need from the pod
    FIELDS=$(kubectl exec "${POD}" -n "${NS}" -- sh -c '
PROPS=/opt/confluentinc/etc/kafka/kafka.properties
echo NODE_ID=$(grep "^node.id" $PROPS | cut -d= -f2)
echo HOSTNAME=$(hostname)
echo BS=$(grep "^controller.quorum.bootstrap.servers" $PROPS | cut -d= -f2)
echo CTRL_NAME=$(grep "^controller.listener.names" $PROPS | cut -d= -f2)
echo ADV=$(grep "^advertised.listeners" $PROPS | cut -d= -f2)
' 2>/dev/null)
    NODE_ID=$(echo "$FIELDS"  | grep "^NODE_ID="   | cut -d= -f2-)
    HOST=$(echo "$FIELDS"     | grep "^HOSTNAME="  | cut -d= -f2-)
    BS=$(echo "$FIELDS"       | grep "^BS="        | cut -d= -f2-)
    CTRL_NAME=$(echo "$FIELDS"| grep "^CTRL_NAME=" | cut -d= -f2-)
    ADV=$(echo "$FIELDS"      | grep "^ADV="       | cut -d= -f2-)
    # Step 1: advertised.listeners already in kafka.properties (strip NAME:// for SELF_ENDPOINT)
    if [ -n "$ADV" ]; then
        ENDPOINT=$(echo "$ADV" | sed 's/^[^:]*:\/\///')
        echo "SELF_ENDPOINT=${ENDPOINT}"
        echo "SELF_ADV_LISTENERS=${ADV}"
        return
    fi
    # Step 2: CR spec.controllerQuorumVoters by node.id (pod FQDN or LB DNS)
    ENDPOINT=$(kubectl get kraftcontroller kraftcontroller -n "${NS}" \
        -o jsonpath="{.spec.controllerQuorumVoters[?(@.nodeId==${NODE_ID})].brokerEndpoint}" \
        2>/dev/null | tr -d '[:space:]')
    if [ -n "$ENDPOINT" ]; then
        echo "SELF_ENDPOINT=${ENDPOINT}"
        echo "SELF_ADV_LISTENERS=${CTRL_NAME}://${ENDPOINT}"
        return
    fi
    # Step 3: hostname prefix match in controller.quorum.bootstrap.servers
    ENDPOINT=$(echo "$BS" | tr ',' '\n' | grep "^${HOST}\." | head -1 | tr -d '[:space:]')
    echo "SELF_ENDPOINT=${ENDPOINT}"
    echo "SELF_ADV_LISTENERS=${CTRL_NAME}://${ENDPOINT}"
}

# Configuration
NAMESPACE="${NAMESPACE:-confluent}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Operator image version
OPERATOR_VERSION="${OPERATOR_VERSION:-latest}"

# Users and passwords (SASL/PLAIN)
KAFKA_USER="kafka"
KAFKA_PASS="kafka-secret"
CLIENT_USER="kafka_client"
CLIENT_PASS="kafka_client-secret"
ADMIN_USER="admin"
ADMIN_PASS="admin-secret"

# LDAP bind user (MDS readonly user for LDAP searches)
LDAP_BIND_USER="cn=mds,dc=test,dc=com"
LDAP_BIND_PASS="Developer!"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Dynamic Quorum Secured Setup (LDAP)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Namespace: $NAMESPACE"
echo "Script dir: $SCRIPT_DIR"
echo ""
echo "This script guides you through each setup step."
echo "You can skip steps that are already completed."
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Create namespace '$NAMESPACE'"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ask_step "Create namespace?"; then
    print_cmd "kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -"
    kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
    echo "✓ Namespace ready"
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Install/upgrade CFK operator"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Operator image: confluent-operator:${OPERATOR_VERSION}"
echo "To change version, update OPERATOR_VERSION in setup.sh"
if ask_step "Install/upgrade operator?"; then
    print_cmd "helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --set image.tag=${OPERATOR_VERSION} -n $NAMESPACE"
    helm upgrade --install confluent-operator \
      confluentinc/confluent-for-kubernetes \
      -f  \
      --set image.tag="${OPERATOR_VERSION}" \
      --namespace=$NAMESPACE
    echo "✓ Operator installed/upgraded at ${OPERATOR_VERSION}"
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Create credential secret"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creates a single secret with both SASL/PLAIN user credentials and the LDAP bind DN/password."
echo "  plain.txt / plain-users.json  → SASL/PLAIN auth for Kafka"
echo "  ldap-server-simple.txt        → MDS LDAP bind: $LDAP_BIND_USER"
if ask_step "Create credential secret?"; then
    PLAIN_TXT="username=${CLIENT_USER}
password=${CLIENT_PASS}"

    PLAIN_USERS_JSON=$(cat <<EOF
{
  "${KAFKA_USER}": "${KAFKA_PASS}",
  "${CLIENT_USER}": "${CLIENT_PASS}",
  "${ADMIN_USER}": "${ADMIN_PASS}"
}
EOF
)

    PLAIN_INTERBROKER_TXT="username=${KAFKA_USER}
password=${KAFKA_PASS}"

    LDAP_BIND_TXT="username=${LDAP_BIND_USER}
password=${LDAP_BIND_PASS}"

    print_cmd "kubectl create secret generic credential --from-literal=plain.txt=... --from-literal=plain-users.json=... --from-literal=plain-interbroker.txt=... --from-literal=ldap-server-simple.txt=..."
    kubectl create secret generic credential \
      --namespace=$NAMESPACE \
      --from-literal=plain.txt="${PLAIN_TXT}" \
      --from-literal=plain-users.json="${PLAIN_USERS_JSON}" \
      --from-literal=plain-interbroker.txt="${PLAIN_INTERBROKER_TXT}" \
      --from-literal=ldap-server-simple.txt="${LDAP_BIND_TXT}" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "✓ Credential secret created"
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4: Create MDS token keypair"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Generates an RSA keypair used by MDS to sign and verify bearer tokens."
if ask_step "Generate MDS token keypair?"; then
    print_cmd "openssl genrsa -out /tmp/mds-tokenkeypair.pem 2048"
    openssl genrsa -out /tmp/mds-tokenkeypair.pem 2048 2>/dev/null
    print_cmd "openssl rsa -in /tmp/mds-tokenkeypair.pem -pubout -out /tmp/mds-public.pem"
    openssl rsa -in /tmp/mds-tokenkeypair.pem -outform PEM -pubout -out /tmp/mds-public.pem 2>/dev/null
    print_cmd "kubectl create secret generic mds-token --from-file=mdsPublicKey.pem=... --from-file=mdsTokenKeyPair.pem=..."
    kubectl create secret generic mds-token \
      --namespace=$NAMESPACE \
      --from-file=mdsPublicKey.pem=/tmp/mds-public.pem \
      --from-file=mdsTokenKeyPair.pem=/tmp/mds-tokenkeypair.pem \
      --dry-run=client -o yaml | kubectl apply -f -
    rm -f /tmp/mds-tokenkeypair.pem /tmp/mds-public.pem
    echo "✓ MDS token keypair created"
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5: Create ERP and REST credential secrets"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "mds-client-erp  → Kafka Embedded REST Proxy credentials (bearer.txt: username/password)"
echo "rest-credential → KafkaRestClass credentials (bearer.txt: username/password)"
if ask_step "Create ERP and REST credential secrets?"; then
    ERP_BEARER_TXT="username=${KAFKA_USER}
password=${KAFKA_PASS}"

    REST_BEARER_TXT="username=${ADMIN_USER}
password=${ADMIN_PASS}"

    print_cmd "kubectl create secret generic mds-client-erp --from-literal=bearer.txt='username=kafka\\npassword=...'"
    kubectl create secret generic mds-client-erp \
      --namespace=$NAMESPACE \
      --from-literal=bearer.txt="${ERP_BEARER_TXT}" \
      --dry-run=client -o yaml | kubectl apply -f -

    print_cmd "kubectl create secret generic rest-credential --from-literal=bearer.txt='username=admin\\npassword=...'"
    kubectl create secret generic rest-credential \
      --namespace=$NAMESPACE \
      --from-literal=bearer.txt="${REST_BEARER_TXT}" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "✓ Credential secrets created"
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 6: Apply Kubernetes RBAC and bootstrap ConfigMap"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "The bootstrap ConfigMap prevents split-brain by tracking whether"
echo "kraftcontroller-0 has already formatted storage with --standalone."
echo "The RBAC gives kraftcontroller-sa permission to update that ConfigMap."
if ask_step "Apply RBAC and ConfigMap?"; then
    print_cmd "kubectl apply -f resources/rbac.yaml"
    kubectl apply -f "$SCRIPT_DIR/resources/rbac.yaml"
    print_cmd "kubectl apply -f resources/bootstrap-configmap.yaml"
    kubectl apply -f "$SCRIPT_DIR/resources/bootstrap-configmap.yaml"
    echo "✓ RBAC and ConfigMap applied"
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 6.5: Create Admin CLI Config"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creates a ConfigMap with security properties for admin CLI tools."
echo "Mounted at /mnt/admin-config on KRaft pods."
if ask_step "Create admin CLI config ConfigMap?"; then
    ADMIN_PROPS=$(mktemp)
    cat > "$ADMIN_PROPS" <<'EOF'
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="kafka" password="kafka-secret";
ssl.truststore.location=/mnt/sslcerts/truststore.p12
ssl.truststore.password=mystorepassword
ssl.truststore.type=PKCS12
EOF
    if ! kubectl get configmap kraft-admin-config -n "$NAMESPACE" &>/dev/null; then
        print_cmd "kubectl create configmap kraft-admin-config --from-file=security.properties=... -n $NAMESPACE"
        kubectl create configmap kraft-admin-config --from-file=security.properties="$ADMIN_PROPS" -n "$NAMESPACE"
    fi
    rm -f "$ADMIN_PROPS"
    echo "✓ Admin CLI config created"
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 7: Deploy OpenLDAP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "LDAP must be running before Kafka starts — MDS connects to LDAP during Kafka startup."
echo "Users loaded: admin (LDAP_ADMIN_PASSWORD), kafka, kafka_client (LDIF), mds (readonly bind)"
if ask_step "Deploy OpenLDAP?"; then
    print_cmd "kubectl apply -f resources/openldap.yaml"
    kubectl apply -f "$SCRIPT_DIR/resources/openldap.yaml"

    echo "Waiting for LDAP pod to be ready..."
    print_cmd "kubectl wait --for=condition=ready --timeout=120s pod/ldap-0 -n $NAMESPACE"
    kubectl wait --for=condition=ready --timeout=120s pod/ldap-0 -n $NAMESPACE || {
        print_warning "LDAP pod not ready yet - Kafka MDS may fail to start until LDAP is available"
    }

    echo "Verifying LDAP users (ldapsearch for organizationalRole entries)..."
    print_cmd "kubectl exec ldap-0 -n $NAMESPACE -- ldapsearch -x -H ldap://localhost:389 -b dc=test,dc=com -D 'cn=mds,dc=test,dc=com' -w Developer! '(objectClass=organizationalRole)' cn"
    LDAP_USERS=$(kubectl exec ldap-0 -n $NAMESPACE -- ldapsearch \
        -x -H ldap://localhost:389 \
        -b dc=test,dc=com \
        -D 'cn=mds,dc=test,dc=com' -w Developer! \
        '(objectClass=organizationalRole)' cn 2>&1)

    for user in kafka kafka_client admin mds; do
        if echo "$LDAP_USERS" | grep -q "cn: ${user}$"; then
            echo "  ✓ cn=${user}"
        else
            echo "  ✗ cn=${user} MISSING"
            print_warning "User '${user}' not found in LDAP — Confluent RBAC resolution will fail for this user"
        fi
    done
    echo "✓ OpenLDAP deployed"
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 8: Deploy KRaftController (dynamic quorum)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "kraftcontroller-0 formats with --standalone (initial voter)."
echo "kraftcontroller-1 and -2 format with --no-initial-controllers (join as observers)."
echo "CP 8.2+: observers auto-promote. CP < 8.2: run add-controller manually."
if ask_step "Deploy KRaftController?"; then
    print_cmd "kubectl apply -f resources/kraftcontroller.yaml"
    kubectl apply -f "$SCRIPT_DIR/resources/kraftcontroller.yaml"

    echo "Waiting for KRaftController pods to be ready..."
    print_cmd "kubectl wait --for=condition=ready --timeout=300s pod -l app=kraftcontroller -n $NAMESPACE"
    kubectl wait --for=condition=ready --timeout=300s pod -l app=kraftcontroller -n $NAMESPACE || {
        print_warning "KRaft pods not ready yet, continuing..."
    }
    echo "✓ KRaftController deployed"
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 9: Verify KRaft quorum replication"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Builds a client properties file from CFK-mounted paths and server config, then"
echo "checks quorum replication status before deploying Kafka."
echo "Expects all 3 controllers to appear (1 leader + 2 observers/voters)."
if ask_step "Verify quorum replication status?"; then
    echo "Resolving kraftcontroller-0 endpoint and advertised.listeners..."
    _OUT=$(compute_controller_endpoints kraftcontroller-0 $NAMESPACE)
    SELF_ENDPOINT_0=$(echo "$_OUT"      | grep "^SELF_ENDPOINT="      | cut -d= -f2-)
    SELF_ADV_LISTENERS_0=$(echo "$_OUT" | grep "^SELF_ADV_LISTENERS=" | cut -d= -f2-)
    echo "  → endpoint:             ${SELF_ENDPOINT_0:-<not found>}"
    echo "  → advertised.listeners: ${SELF_ADV_LISTENERS_0:-<not found>}"
    print_cmd "kubectl exec kraftcontroller-0 -n $NAMESPACE -- sh -c '... kafka-metadata-quorum describe --replication'"
    kubectl exec kraftcontroller-0 -n $NAMESPACE -- \
        env SELF_ENDPOINT="${SELF_ENDPOINT_0}" SELF_ADV_LISTENERS="${SELF_ADV_LISTENERS_0}" sh -c '
USERNAME=$(grep "^username" /mnt/secrets/kraftcontroller-controller-listener-apikeys/plain.txt | cut -d= -f2)
PASSWORD=$(grep "^password" /mnt/secrets/kraftcontroller-controller-listener-apikeys/plain.txt | cut -d= -f2)
JKS_PASS=$(grep jksPassword /mnt/sslcerts/jksPassword.txt | cut -d= -f2)
PROCESS_ROLES=$(grep "^process.roles" /opt/confluentinc/etc/kafka/kafka.properties | cut -d= -f2)
NODE_ID=$(grep "^node.id" /opt/confluentinc/etc/kafka/kafka.properties | cut -d= -f2)
LOG_DIRS=$(grep "^log.dirs" /opt/confluentinc/etc/kafka/kafka.properties | cut -d= -f2)
CTRL_LISTENER_NAMES=$(grep "^controller.listener.names" /opt/confluentinc/etc/kafka/kafka.properties | cut -d= -f2)
LISTENER_PROTO_MAP=$(grep "^listener.security.protocol.map" /opt/confluentinc/etc/kafka/kafka.properties | cut -d= -f2)
LISTENERS=$(grep "^listeners" /opt/confluentinc/etc/kafka/kafka.properties | cut -d= -f2)
echo "security.protocol=SASL_SSL" > /tmp/ctrl.properties
echo "sasl.mechanism=PLAIN" >> /tmp/ctrl.properties
echo "sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"${USERNAME}\" password=\"${PASSWORD}\";" >> /tmp/ctrl.properties
echo "process.roles=${PROCESS_ROLES}" >> /tmp/ctrl.properties
echo "log.dirs=${LOG_DIRS}" >> /tmp/ctrl.properties
echo "controller.listener.names=${CTRL_LISTENER_NAMES}" >> /tmp/ctrl.properties
echo "listener.security.protocol.map=${LISTENER_PROTO_MAP}" >> /tmp/ctrl.properties
echo "listeners=${LISTENERS}" >> /tmp/ctrl.properties
echo "ssl.truststore.location=/mnt/sslcerts/truststore.jks" >> /tmp/ctrl.properties
echo "ssl.truststore.password=${JKS_PASS}" >> /tmp/ctrl.properties
echo "advertised.listeners=${SELF_ADV_LISTENERS}" >> /tmp/ctrl.properties
echo "node.id=${NODE_ID}" >> /tmp/ctrl.properties
echo "=== /tmp/ctrl.properties ==="
cat /tmp/ctrl.properties
echo "==========================="
KAFKA_HEAP_OPTS="-Xmx512m" kafka-metadata-quorum --bootstrap-controller ${SELF_ENDPOINT} \
  --command-config /tmp/ctrl.properties \
  describe --replication
' || print_warning "Quorum check failed — controllers may still be forming quorum. Check logs with: kubectl logs kraftcontroller-0 -n $NAMESPACE"
    echo "✓ Quorum check complete"
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 9.5: Promote observers to voters (CP < 8.2 only)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CP 8.2+: observers auto-promote, skip this step."
echo "CP < 8.2: kraftcontroller-1 and kraftcontroller-2 start as observers."
echo "          This step promotes them to voters via add-controller."
if ask_step "Promote observers to voters?"; then
    echo "Resolving kraftcontroller-0 endpoint (bootstrap-controller for promotion)..."
    _OUT_0=$(compute_controller_endpoints kraftcontroller-0 $NAMESPACE)
    BOOTSTRAP_CTRL=$(echo "$_OUT_0" | grep "^SELF_ENDPOINT=" | cut -d= -f2-)
    echo "  → bootstrap-controller: ${BOOTSTRAP_CTRL:-<not found>}"
    for POD in kraftcontroller-1 kraftcontroller-2; do
        echo "Resolving ${POD} advertised.listeners..."
        _OUT=$(compute_controller_endpoints "${POD}" $NAMESPACE)
        SELF_ADV_LISTENERS=$(echo "$_OUT" | grep "^SELF_ADV_LISTENERS=" | cut -d= -f2-)
        echo "  → advertised.listeners: ${SELF_ADV_LISTENERS:-<not found>}"
        echo "Promoting ${POD}..."
        kubectl exec "${POD}" -n $NAMESPACE -- \
            env SELF_ADV_LISTENERS="${SELF_ADV_LISTENERS}" BOOTSTRAP_CTRL="${BOOTSTRAP_CTRL}" sh -c '
USERNAME=$(grep "^username" /mnt/secrets/kraftcontroller-controller-listener-apikeys/plain.txt | cut -d= -f2)
PASSWORD=$(grep "^password" /mnt/secrets/kraftcontroller-controller-listener-apikeys/plain.txt | cut -d= -f2)
JKS_PASS=$(grep jksPassword /mnt/sslcerts/jksPassword.txt | cut -d= -f2)
PROCESS_ROLES=$(grep "^process.roles" /opt/confluentinc/etc/kafka/kafka.properties | cut -d= -f2)
NODE_ID=$(grep "^node.id" /opt/confluentinc/etc/kafka/kafka.properties | cut -d= -f2)
LOG_DIRS=$(grep "^log.dirs" /opt/confluentinc/etc/kafka/kafka.properties | cut -d= -f2)
CTRL_LISTENER_NAMES=$(grep "^controller.listener.names" /opt/confluentinc/etc/kafka/kafka.properties | cut -d= -f2)
LISTENER_PROTO_MAP=$(grep "^listener.security.protocol.map" /opt/confluentinc/etc/kafka/kafka.properties | cut -d= -f2)
LISTENERS=$(grep "^listeners" /opt/confluentinc/etc/kafka/kafka.properties | cut -d= -f2)
echo "security.protocol=SASL_SSL" > /tmp/ctrl.properties
echo "sasl.mechanism=PLAIN" >> /tmp/ctrl.properties
echo "sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"${USERNAME}\" password=\"${PASSWORD}\";" >> /tmp/ctrl.properties
echo "process.roles=${PROCESS_ROLES}" >> /tmp/ctrl.properties
echo "log.dirs=${LOG_DIRS}" >> /tmp/ctrl.properties
echo "controller.listener.names=${CTRL_LISTENER_NAMES}" >> /tmp/ctrl.properties
echo "listener.security.protocol.map=${LISTENER_PROTO_MAP}" >> /tmp/ctrl.properties
echo "listeners=${LISTENERS}" >> /tmp/ctrl.properties
echo "ssl.truststore.location=/mnt/sslcerts/truststore.jks" >> /tmp/ctrl.properties
echo "ssl.truststore.password=${JKS_PASS}" >> /tmp/ctrl.properties
echo "advertised.listeners=${SELF_ADV_LISTENERS}" >> /tmp/ctrl.properties
echo "node.id=${NODE_ID}" >> /tmp/ctrl.properties
echo "=== /tmp/ctrl.properties for add-controller ==="
cat /tmp/ctrl.properties
echo "================================================"
KAFKA_HEAP_OPTS="-Xmx512m" kafka-metadata-quorum \
  --bootstrap-controller "${BOOTSTRAP_CTRL}" \
  --command-config /tmp/ctrl.properties \
  add-controller
' && echo "✓ ${POD} promoted" || print_warning "${POD} promotion failed — may already be a voter or quorum not ready"
    done
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 10: Deploy Kafka"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ask_step "Deploy Kafka?"; then
    print_cmd "kubectl apply -f resources/kafka.yaml"
    kubectl apply -f "$SCRIPT_DIR/resources/kafka.yaml"

    echo "Waiting for Kafka pods to be ready..."
    print_cmd "kubectl wait --for=condition=ready --timeout=300s pod -l app=kafka -n $NAMESPACE"
    kubectl wait --for=condition=ready --timeout=300s pod -l app=kafka -n $NAMESPACE || {
        print_warning "Kafka pods not ready yet, continuing..."
    }
    echo "✓ Kafka deployed"
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 11: Deploy KafkaRestClass and Confluent Rolebindings"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "KafkaRestClass lets the CFK operator perform Day-2 operations (topics, schemas, etc.)"
echo "Rolebindings: admin→SystemAdmin, kafka→SystemAdmin, kafka_client→DeveloperWrite"
if ask_step "Deploy KafkaRestClass and Rolebindings?"; then
    print_cmd "kubectl apply -f resources/kafkarestclass.yaml"
    kubectl apply -f "$SCRIPT_DIR/resources/kafkarestclass.yaml"
    print_cmd "kubectl apply -f resources/rolebindings.yaml"
    kubectl apply -f "$SCRIPT_DIR/resources/rolebindings.yaml"

    echo "Waiting for rolebindings to reconcile..."
    sleep 10
    print_cmd "kubectl wait --for=condition=BOUND --timeout=120s confluentrolebinding --all -n $NAMESPACE"
    kubectl wait --for=condition=BOUND --timeout=120s confluentrolebinding --all -n $NAMESPACE || {
        print_warning "Rolebindings not bound yet — check with: kubectl get confluentrolebinding -n $NAMESPACE"
    }
    echo "✓ KafkaRestClass and Rolebindings deployed"
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 12: Kafka Health Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creates a test topic, produces a message, reads it back, then offers to delete."
if ask_step "Run Kafka health check?"; then
    TEST_TOPIC="health-check-$(date +%s)"
    BOOTSTRAP="kafka.${NAMESPACE}.svc.cluster.local:9071"

    echo "Creating client config inside kafka-0..."
    kubectl exec kafka-0 -n $NAMESPACE -- sh -c "
JKS_PASS=\$(grep jksPassword /mnt/sslcerts/jksPassword.txt | cut -d= -f2)
cat > /tmp/client.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"${KAFKA_USER}\" password=\"${KAFKA_PASS}\";
ssl.truststore.location=/mnt/sslcerts/truststore.jks
ssl.truststore.password=\${JKS_PASS}
EOF
echo '✓ client.properties written'
"

    echo "Creating topic '${TEST_TOPIC}'..."
    print_cmd "kafka-topics --create --topic ${TEST_TOPIC}"
    kubectl exec kafka-0 -n $NAMESPACE -- sh -c "
kafka-topics --bootstrap-server ${BOOTSTRAP} \
  --command-config /tmp/client.properties \
  --create --topic ${TEST_TOPIC} --partitions 1 --replication-factor 1
" && echo "✓ Topic created" || print_warning "Topic creation failed"

    echo "Producing test message..."
    print_cmd "echo 'hello-from-health-check' | kafka-console-producer --topic ${TEST_TOPIC}"
    kubectl exec kafka-0 -n $NAMESPACE -- sh -c "
echo 'hello-from-health-check' | kafka-console-producer \
  --bootstrap-server ${BOOTSTRAP} \
  --producer.config /tmp/client.properties \
  --topic ${TEST_TOPIC}
" && echo "✓ Message produced" || print_warning "Produce failed"

    echo "Consuming test message (waiting up to 15s)..."
    print_cmd "kafka-console-consumer --topic ${TEST_TOPIC} --from-beginning --max-messages 1"
    kubectl exec kafka-0 -n $NAMESPACE -- sh -c "
kafka-console-consumer \
  --bootstrap-server ${BOOTSTRAP} \
  --consumer.config /tmp/client.properties \
  --topic ${TEST_TOPIC} \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 15000
" && echo "✓ Message consumed" || print_warning "Consume failed or timed out"

    echo ""
    if ask_step "Delete test topic '${TEST_TOPIC}'?"; then
        kubectl exec kafka-0 -n $NAMESPACE -- sh -c "
kafka-topics --bootstrap-server ${BOOTSTRAP} \
  --command-config /tmp/client.properties \
  --delete --topic ${TEST_TOPIC}
"
        echo "✓ Topic '${TEST_TOPIC}' deleted"
    else
        echo "⊘ Topic '${TEST_TOPIC}' kept"
    fi
    echo "✓ Health check complete"
else
    echo "⊘ Skipped"
fi
echo ""

# ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Setup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Deployed:"
echo "  - OpenLDAP (ldap.confluent.svc.cluster.local:389)"
echo "  - KRaftController (3 replicas, dynamic quorum enabled)"
echo "  - Kafka (3 brokers, LDAP RBAC)"
echo "  - KafkaRestClass"
echo "  - ConfluentRolebindings"
echo ""
echo "Users (SASL/PLAIN ←→ LDAP):"
echo "  kafka/${KAFKA_PASS}          → SystemAdmin"
echo "  admin/${ADMIN_PASS}          → SystemAdmin"
echo "  kafka_client/${CLIENT_PASS}  → DeveloperWrite"
echo "  mds/${LDAP_BIND_PASS}      → LDAP bind only (not for Kafka auth)"
echo ""
echo "Verify LDAP users:"
echo "  kubectl exec ldap-0 -n $NAMESPACE -- ldapsearch -x -H ldap://localhost:389 \\"
echo "    -b dc=test,dc=com -D 'cn=mds,dc=test,dc=com' -w Developer! \\"
echo "    '(objectClass=organizationalRole)' cn"
echo ""
echo "Check dynamic quorum status:"
echo "  kubectl exec kraftcontroller-0 -n $NAMESPACE -- sh -c '"
echo "    JKS_PASS=\$(grep jksPassword /mnt/sslcerts/jksPassword.txt | cut -d= -f2)"
echo "    USERNAME=\$(grep \"^username\" /mnt/secrets/kraftcontroller-controller-listener-apikeys/plain.txt | cut -d= -f2)"
echo "    PASSWORD=\$(grep \"^password\" /mnt/secrets/kraftcontroller-controller-listener-apikeys/plain.txt | cut -d= -f2)"
echo "    cat > /tmp/ctrl.properties <<EOF"
echo "    security.protocol=SASL_SSL"
echo "    sasl.mechanism=PLAIN"
echo "    sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"\${USERNAME}\" password=\"\${PASSWORD}\";"
echo "    ssl.truststore.location=/mnt/sslcerts/truststore.jks"
echo "    ssl.truststore.password=\${JKS_PASS}"
echo "    EOF"
echo "    kafka-metadata-quorum --bootstrap-controller localhost:9074 \\"
echo "      --command-config /tmp/ctrl.properties describe --status"
echo "  '"
echo ""
echo "Check kraft.version (should be 1 = dynamic quorum active):"
echo "  kubectl exec kraftcontroller-0 -n $NAMESPACE -- kafka-features \\"
echo "    --bootstrap-controller localhost:9074 describe | grep kraft.version"
echo ""
