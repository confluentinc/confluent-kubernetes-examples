#!/bin/bash
# Check and fix DNS records for ALL LoadBalancer endpoints (True Multi-Cluster, Secured)
# Covers: KRaft controllers, Kafka external, Kafka replication, Keycloak
# Modes:
#   fix   - Interactive: check DNS, prompt to fix mismatches via gcloud (default)
#   watch - Status only: show DNS table (no fixes)

# Configuration
REGION1_NS="${REGION1_NS:-central}"
REGION2_NS="${REGION2_NS:-east}"
REGION1_CONTEXT="${REGION1_CONTEXT:-<your-region1-k8s-context>}"
REGION2_CONTEXT="${REGION2_CONTEXT:-<your-region2-k8s-context>}"
DNS_ZONE="${DNS_ZONE:-my-dns-zone}"
DOMAIN="my-domain.example.com"

# Helpers
kube1() { kubectl --context "$REGION1_CONTEXT" "$@"; }
kube2() { kubectl --context "$REGION2_CONTEXT" "$@"; }

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
MODE="${1:-fix}"
MISMATCHES=0
FIXES=0

usage() {
    echo "Usage: $0 [mode]"
    echo ""
    echo "Modes:"
    echo "  fix    - Interactive: check DNS and prompt to fix mismatches (default)"
    echo "  watch  - Status only: show DNS status table (no fixes)"
    echo ""
    echo "Checks ALL LoadBalancer endpoints:"
    echo "  - KRaft controllers (6 endpoints: 3 central + 3 east)"
    echo "  - Kafka external listener (4 endpoints: 2 central + 2 east)"
    echo "  - Kafka replication listener (4 endpoints: 2 central + 2 east)"
    echo "  - Kafka MDS endpoint (2 endpoints: 1 central + 1 east)"
    echo "  - Keycloak (1 endpoint: central only)"
    echo ""
    echo "Environment variables:"
    echo "  REGION1_NS       Namespace for region 1 (default: central)"
    echo "  REGION2_NS       Namespace for region 2 (default: east)"
    echo "  REGION1_CONTEXT  kubectl context for region 1 cluster"
    echo "  REGION2_CONTEXT  kubectl context for region 2 cluster"
    echo "  DNS_ZONE         DNS zone name (default: my-dns-zone)"
    exit 0
}

if [ "$MODE" = "-h" ] || [ "$MODE" = "--help" ]; then
    usage
fi

if [ "$MODE" != "fix" ] && [ "$MODE" != "watch" ]; then
    echo "Invalid mode: $MODE"
    echo ""
    usage
fi

# kube function for a given namespace
kube_for_ns() {
    if [ "$1" = "$REGION1_NS" ]; then echo "kube1"; else echo "kube2"; fi
}

# Generic check: service name → DNS name
# Args: label, svc_name, namespace, dns_prefix, interactive
check_endpoint() {
    local label="$1"
    local svc_name="$2"
    local namespace="$3"
    local dns_name="$4"
    local interactive="$5"
    local kube=$(kube_for_ns "$namespace")

    local fqdn="${dns_name}.${DOMAIN}"
    local lb_ip=$($kube get svc "$svc_name" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    local dns_ip=$(timeout 3 dig +short "$fqdn" @8.8.8.8 2>/dev/null | tail -1 || echo "")

    if [ "$interactive" = true ]; then
        echo -e "${BLUE}${fqdn}${NC} (svc: ${svc_name}, ns: ${namespace})"

        if [ -z "$lb_ip" ]; then
            echo -e "  ${YELLOW}LoadBalancer IP pending — service may not be type LoadBalancer${NC}"
            echo ""
            return 1
        fi

        echo "  LoadBalancer IP: $lb_ip"
        echo "  DNS resolves to: ${dns_ip:-N/A}"

        if [ -z "$dns_ip" ]; then
            echo -e "  ${YELLOW}WARNING: DNS record not found${NC}"
            echo -e "  ${YELLOW}Create with:${NC}"
            echo "    gcloud dns record-sets create ${fqdn}. --type=A --zone=$DNS_ZONE --rrdatas=$lb_ip --ttl=300"
            echo ""
            read -p "  Create now? (y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                gcloud dns record-sets create "${fqdn}." --type=A --zone=$DNS_ZONE --rrdatas=$lb_ip --ttl=300 2>&1 && {
                    echo -e "  ${GREEN}DNS record created!${NC}"
                    FIXES=$((FIXES + 1))
                } || {
                    echo -e "  ${RED}Failed to create DNS record${NC}"
                }
            fi
            MISMATCHES=$((MISMATCHES + 1))
            echo ""
        elif [ "$lb_ip" != "$dns_ip" ]; then
            echo -e "  ${RED}MISMATCH! DNS=$dns_ip, LB=$lb_ip${NC}"
            echo -e "  ${YELLOW}Fix with:${NC}"
            echo "    gcloud dns record-sets update ${fqdn}. --type=A --zone=$DNS_ZONE --rrdatas=$lb_ip --ttl=300"
            echo ""
            read -p "  Fix now? (y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                gcloud dns record-sets update "${fqdn}." --type=A --zone=$DNS_ZONE --rrdatas=$lb_ip --ttl=300 2>&1 && {
                    echo -e "  ${GREEN}DNS updated!${NC}"
                    FIXES=$((FIXES + 1))
                } || {
                    echo -e "  ${RED}Failed to update DNS${NC}"
                }
            fi
            MISMATCHES=$((MISMATCHES + 1))
            echo ""
        else
            echo -e "  ${GREEN}DNS matches LoadBalancer${NC}"
            echo ""
        fi
    else
        # Watch mode — compact table output
        if [ -z "$lb_ip" ]; then
            printf "  %-45s LB: %-16s DNS: %-16s %b\n" "$label" "PENDING" "${dns_ip:-N/A}" "${YELLOW}[NO LB]${NC}"
        elif [ "$lb_ip" = "$dns_ip" ]; then
            printf "  %-45s LB: %-16s DNS: %-16s %b\n" "$label" "$lb_ip" "$dns_ip" "${GREEN}[OK]${NC}"
        else
            printf "  %-45s LB: %-16s DNS: %-16s %b\n" "$label" "$lb_ip" "${dns_ip:-N/A}" "${RED}[MISMATCH]${NC}"
            MISMATCHES=$((MISMATCHES + 1))
        fi
    fi
}

run_checks() {
    local interactive="$1"

    # === KRaft Controllers ===
    if [ "$interactive" = true ]; then
        echo "=== KRaft Controllers ==="
        echo ""
    else
        echo -e "${BLUE}KRaft Controllers:${NC}"
    fi
    check_endpoint "kraft-central0" "kraftcontroller-listener-controller-0-lb" "$REGION1_NS" "kraft-central0" "$interactive"
    check_endpoint "kraft-central1" "kraftcontroller-listener-controller-1-lb" "$REGION1_NS" "kraft-central1" "$interactive"
    check_endpoint "kraft-central2" "kraftcontroller-listener-controller-2-lb" "$REGION1_NS" "kraft-central2" "$interactive"
    check_endpoint "kraft-east0" "kraftcontroller-listener-controller-0-lb" "$REGION2_NS" "kraft-east0" "$interactive"
    check_endpoint "kraft-east1" "kraftcontroller-listener-controller-1-lb" "$REGION2_NS" "kraft-east1" "$interactive"
    check_endpoint "kraft-east2" "kraftcontroller-listener-controller-2-lb" "$REGION2_NS" "kraft-east2" "$interactive"

    echo ""

    # === Kafka External Listener ===
    if [ "$interactive" = true ]; then
        echo "=== Kafka External Listener ==="
        echo ""
    else
        echo -e "${BLUE}Kafka External Listener:${NC}"
    fi
    check_endpoint "kafka-central-ext0" "kafka-0-lb" "$REGION1_NS" "kafka-central-ext0" "$interactive"
    check_endpoint "kafka-central-ext1" "kafka-1-lb" "$REGION1_NS" "kafka-central-ext1" "$interactive"
    check_endpoint "kafka-east-ext0" "kafka-0-lb" "$REGION2_NS" "kafka-east-ext0" "$interactive"
    check_endpoint "kafka-east-ext1" "kafka-1-lb" "$REGION2_NS" "kafka-east-ext1" "$interactive"

    echo ""

    # === Kafka Replication Listener ===
    if [ "$interactive" = true ]; then
        echo "=== Kafka Replication Listener ==="
        echo ""
    else
        echo -e "${BLUE}Kafka Replication Listener:${NC}"
    fi
    check_endpoint "kafka-central-rep0" "kafka-listener-replication-0-lb" "$REGION1_NS" "kafka-central-rep0" "$interactive"
    check_endpoint "kafka-central-rep1" "kafka-listener-replication-1-lb" "$REGION1_NS" "kafka-central-rep1" "$interactive"
    check_endpoint "kafka-east-rep0" "kafka-listener-replication-0-lb" "$REGION2_NS" "kafka-east-rep0" "$interactive"
    check_endpoint "kafka-east-rep1" "kafka-listener-replication-1-lb" "$REGION2_NS" "kafka-east-rep1" "$interactive"

    echo ""

    # === Kafka MDS Endpoint ===
    if [ "$interactive" = true ]; then
        echo "=== Kafka MDS Endpoint ==="
        echo ""
    else
        echo -e "${BLUE}Kafka MDS Endpoint:${NC}"
    fi
    check_endpoint "kafka-central-mds (bootstrap)" "kafka-mds-bootstrap-lb" "$REGION1_NS" "kafka-central-mds" "$interactive"
    check_endpoint "kafka-central-mds0 (broker 0)" "kafka-mds-0-lb" "$REGION1_NS" "kafka-central-mds0" "$interactive"
    check_endpoint "kafka-central-mds1 (broker 1)" "kafka-mds-1-lb" "$REGION1_NS" "kafka-central-mds1" "$interactive"
    check_endpoint "kafka-east-mds (bootstrap)" "kafka-mds-bootstrap-lb" "$REGION2_NS" "kafka-east-mds" "$interactive"
    check_endpoint "kafka-east-mds0 (broker 0)" "kafka-mds-0-lb" "$REGION2_NS" "kafka-east-mds0" "$interactive"
    check_endpoint "kafka-east-mds1 (broker 1)" "kafka-mds-1-lb" "$REGION2_NS" "kafka-east-mds1" "$interactive"

    echo ""

    # === Keycloak (Central Identity Provider) ===
    if [ "$interactive" = true ]; then
        echo "=== Keycloak (Central Identity Provider) ==="
        echo ""
    else
        echo -e "${BLUE}Keycloak (Central IdP):${NC}"
    fi
    check_endpoint "keycloak" "keycloak" "$REGION1_NS" "keycloak" "$interactive"
}

# === Main ===
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  DNS Sync Check (True Multi-Cluster)${NC}"
echo -e "${BLUE}  Mode: $(echo $MODE | tr '[:lower:]' '[:upper:]')${NC}"
echo -e "${BLUE}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Region 1: $REGION1_NS ($(echo $REGION1_CONTEXT | awk -F_ '{print $NF}'))"
echo "Region 2: $REGION2_NS ($(echo $REGION2_CONTEXT | awk -F_ '{print $NF}'))"
echo ""

if [ "$MODE" = "fix" ]; then
    run_checks true
else
    run_checks false
fi

echo ""
if [ "$MISMATCHES" -gt 0 ]; then
    if [ "$MODE" = "fix" ]; then
        echo -e "${YELLOW}$MISMATCHES mismatch(es) found. $FIXES fixed.${NC}"
    else
        echo -e "${RED}$MISMATCHES DNS mismatch(es) found. Run '$0 fix' to repair.${NC}"
    fi
else
    echo -e "${GREEN}All DNS records match LoadBalancer IPs.${NC}"
fi
echo ""
