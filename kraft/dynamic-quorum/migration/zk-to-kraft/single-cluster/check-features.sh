#!/bin/bash
# Script to gather detailed feature and version information
# Uses kafka-features to show all metadata versions and feature levels

NAMESPACE="confluent"

echo "==========================================="
echo "  Kafka Features & Versions Report"
echo "==========================================="
echo ""

# Function to check features from Kafka broker
check_kafka_features() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Kafka Broker Features"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if ! kubectl get pod kafka-0 -n "$NAMESPACE" &>/dev/null; then
        echo "⚠️  kafka-0 not found"
        return 1
    fi

    echo "Running: kafka-features --bootstrap-server localhost:9092 describe"
    echo ""

    kubectl exec kafka-0 -n "$NAMESPACE" -- \
        kafka-features --bootstrap-server localhost:9092 describe

    echo ""
}

# Function to check features from KRaft controller
check_kraft_features() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "KRaft Controller Features"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if ! kubectl get pod kraftcontroller-0 -n "$NAMESPACE" &>/dev/null; then
        echo "⚠️  kraftcontroller-0 not found"
        return 1
    fi

    echo "Running: kafka-features --bootstrap-controller localhost:9074 describe"
    echo ""

    kubectl exec kraftcontroller-0 -n "$NAMESPACE" -- \
        kafka-features --bootstrap-controller localhost:9074 describe

    echo ""
}

# Function to check metadata version from quorum
check_metadata_version() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "KRaft Metadata Version"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if ! kubectl get pod kraftcontroller-0 -n "$NAMESPACE" &>/dev/null; then
        echo "⚠️  kraftcontroller-0 not found"
        return 1
    fi

    echo "Running: kafka-metadata-quorum --bootstrap-controller localhost:9074 describe --status"
    echo ""

    kubectl exec kraftcontroller-0 -n "$NAMESPACE" -- \
        kafka-metadata-quorum --bootstrap-controller localhost:9074 \
        describe --status

    echo ""
}

# Function to check broker configs related to IBP and metadata
check_broker_configs() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Broker Configuration (IBP & Metadata)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if ! kubectl get pod kafka-0 -n "$NAMESPACE" &>/dev/null; then
        echo "⚠️  kafka-0 not found"
        return 1
    fi

    echo "Key configurations:"
    echo ""

    # IBP version
    echo "→ inter.broker.protocol.version:"
    kubectl exec kafka-0 -n "$NAMESPACE" -- \
        kafka-configs --bootstrap-server localhost:9092 \
        --entity-type brokers --entity-default \
        --describe 2>/dev/null | grep inter.broker.protocol.version || echo "  (not set - using default)"

    echo ""

    # Metadata version (if available)
    echo "→ metadata.version:"
    kubectl exec kafka-0 -n "$NAMESPACE" -- \
        kafka-configs --bootstrap-server localhost:9092 \
        --entity-type brokers --entity-default \
        --describe 2>/dev/null | grep metadata.version || echo "  (not set - using default)"

    echo ""
}

# Function to check migration phase
check_migration_phase() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Migration Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local phase=$(kubectl get kraftmigrationjob kraftmigrationjob -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null)
    local subphase=$(kubectl get kraftmigrationjob kraftmigrationjob -n "$NAMESPACE" \
        -o jsonpath='{.status.subPhase}' 2>/dev/null)

    if [ -z "$phase" ]; then
        echo "⚠️  KRaftMigrationJob not found"
        return 1
    fi

    echo "Phase: $phase"
    echo "SubPhase: $subphase"
    echo ""
}

# Main execution
echo "Timestamp: $(date)"
echo ""

check_migration_phase
check_kafka_features
check_kraft_features
check_metadata_version
check_broker_configs

echo "==========================================="
echo "  Report Complete"
echo "==========================================="
echo ""
echo "Key things to look for:"
echo "  1. metadata.version - What version is currently active?"
echo "  2. kraft.version - Is dynamic quorum (version 1) supported?"
echo "  3. Feature levels - What features are finalized vs supported?"
echo "  4. IBP version - Should be 3.9 for CP 7.9.0 with dynamic quorum"
echo ""
echo "For observer promotion during DUAL_WRITE, check if:"
echo "  - Direct-to-controller API is supported at current metadata.version"
echo "  - kraft.version can be set to 1 (dynamic quorum) during migration"
echo ""
