#!/bin/bash

# Client Switchover Migration Script
# This script automates the Blue/Green deployment switchover process

set -e

# Configuration
NAMESPACE="confluent"
SOURCE_CLUSTER="kafka-source:9092"
DESTINATION_CLUSTER="kafka-destination:9092"
CLUSTER_LINK="source-to-destination-link"
TOPICS="orders,payments,inventory,users"
MAX_LAG_THRESHOLD=100

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Pre-flight checks
pre_flight_checks() {
    log_info "Starting pre-flight checks..."
    
    # Check cluster link status
    log_info "Checking cluster link status..."
    kafka-cluster-links --describe \
        --link $CLUSTER_LINK \
        --bootstrap-server $DESTINATION_CLUSTER > /tmp/link-status.txt
    
    # Check replication lag
    LAG=$(grep "LAG" /tmp/link-status.txt | awk '{print $3}' | sort -rn | head -1)
    if [ "$LAG" -gt "$MAX_LAG_THRESHOLD" ]; then
        log_error "Replication lag ($LAG) exceeds threshold ($MAX_LAG_THRESHOLD)"
        exit 1
    fi
    log_info "Replication lag is acceptable: $LAG messages"
    
    # Check consumer group offsets
    log_info "Checking consumer group offsets..."
    kafka-consumer-groups --describe --all-groups \
        --bootstrap-server $SOURCE_CLUSTER > /tmp/offsets-source.txt
    kafka-consumer-groups --describe --all-groups \
        --bootstrap-server $DESTINATION_CLUSTER > /tmp/offsets-destination.txt
    
    # Save current state
    CUTOVER_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    log_info "Cutover initiated at: $CUTOVER_TIME"
    
    kubectl get pods -n $NAMESPACE -o wide > /tmp/pre-cutover-pods-$CUTOVER_TIME.txt
    kubectl get svc -n $NAMESPACE > /tmp/pre-cutover-services-$CUTOVER_TIME.txt
    
    log_info "Pre-flight checks completed successfully"
}

# Update Green Gateway configuration
update_green_gateway() {
    log_info "Updating Green Gateway to point to destination cluster..."
    
    # Update the Green Gateway configuration
    kubectl get gateway confluent-gateway-green -n $NAMESPACE -o yaml > /tmp/green-gateway.yaml
    
    # Replace bootstrap servers
    sed -i "s/$SOURCE_CLUSTER/$DESTINATION_CLUSTER/g" /tmp/green-gateway.yaml
    
    # Apply the updated configuration
    kubectl apply -f /tmp/green-gateway.yaml
    
    # Trigger rollout restart
    log_info "Restarting Green Gateway pods..."
    kubectl rollout restart deployment/confluent-gateway-green -n $NAMESPACE
    
    # Wait for rollout to complete
    kubectl rollout status deployment/confluent-gateway-green -n $NAMESPACE --timeout=5m
    
    # Verify all Green pods are running
    GREEN_PODS=$(kubectl get pods -l app=confluent-gateway,version=green -n $NAMESPACE --no-headers | wc -l)
    GREEN_READY=$(kubectl get pods -l app=confluent-gateway,version=green -n $NAMESPACE --no-headers | grep "Running" | wc -l)
    
    if [ "$GREEN_PODS" -ne "$GREEN_READY" ]; then
        log_error "Not all Green pods are ready"
        exit 1
    fi
    
    log_info "Green Gateway updated successfully"
}

# Promote mirror topics
promote_mirrors() {
    log_info "Promoting mirror topics..."
    
    # Promote each topic
    IFS=',' read -ra TOPIC_ARRAY <<< "$TOPICS"
    for topic in "${TOPIC_ARRAY[@]}"; do
        log_info "Promoting topic: $topic"
        kafka-mirrors --promote \
            --topic $topic \
            --bootstrap-server $DESTINATION_CLUSTER
    done
    
    # Verify promotion
    log_info "Verifying topic promotion..."
    for topic in "${TOPIC_ARRAY[@]}"; do
        echo "test" | kafka-console-producer \
            --bootstrap-server $DESTINATION_CLUSTER \
            --topic $topic 2>&1 | grep -i "error" && {
                log_error "Topic $topic is not writable"
                exit 1
            } || log_info "Topic $topic is writable ✓"
    done
    
    log_info "All topics promoted successfully"
}

# Switch traffic from Blue to Green
switch_traffic() {
    log_info "Switching traffic from Blue to Green..."
    
    # Patch the LoadBalancer service
    kubectl patch service confluent-gateway-lb -n $NAMESPACE -p \
        '{"spec":{"selector":{"version":"green","app":"confluent-gateway"}}}'
    
    # Verify service endpoints
    sleep 5
    ENDPOINTS=$(kubectl get endpoints confluent-gateway-lb -n $NAMESPACE --no-headers | awk '{print $2}')
    
    if [ -z "$ENDPOINTS" ]; then
        log_error "No endpoints found for Green deployment"
        exit 1
    fi
    
    log_info "Traffic switched successfully. Endpoints: $ENDPOINTS"
}

# Monitor the migration
monitor_migration() {
    log_info "Monitoring migration for 60 seconds..."
    
    for i in {1..6}; do
        sleep 10
        
        # Check for producer errors
        PRODUCER_ERRORS=$(kubectl logs deployment/confluent-gateway-green -n $NAMESPACE --tail=100 | \
            grep -E "ProducerFencedException|InvalidProducerEpochException" | wc -l)
        
        # Check consumer lag
        CONSUMER_LAG=$(kafka-consumer-groups --describe --all-groups \
            --bootstrap-server $DESTINATION_CLUSTER | \
            grep "LAG" | awk '{print $5}' | sort -rn | head -1)
        
        log_info "Check $i/6 - Producer errors: $PRODUCER_ERRORS, Max consumer lag: $CONSUMER_LAG"
    done
    
    log_info "Monitoring completed"
}

# Rollback function
rollback() {
    log_warning "Initiating rollback to Blue deployment..."
    
    # Switch traffic back to Blue
    kubectl patch service confluent-gateway-lb -n $NAMESPACE -p \
        '{"spec":{"selector":{"version":"blue","app":"confluent-gateway"}}}'
    
    # Scale up Blue if needed
    kubectl scale deployment/confluent-gateway-blue -n $NAMESPACE --replicas=3
    
    # Verify Blue pods are serving traffic
    ENDPOINTS=$(kubectl get endpoints confluent-gateway-lb -n $NAMESPACE --no-headers | awk '{print $2}')
    
    log_info "Rollback completed. Blue endpoints: $ENDPOINTS"
}

# Main execution
main() {
    log_info "Starting Blue/Green Gateway Client Switchover"
    echo "================================================"
    
    # Run pre-flight checks
    pre_flight_checks
    
    # Ask for confirmation
    echo ""
    read -p "Pre-flight checks passed. Proceed with migration? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
        log_warning "Migration cancelled by user"
        exit 0
    fi
    
    # Execute migration steps
    update_green_gateway
    promote_mirrors
    switch_traffic
    monitor_migration
    
    # Ask if rollback is needed
    echo ""
    read -p "Migration completed. Do you need to rollback? (yes/no): " -r
    if [[ $REPLY =~ ^[Yy]es$ ]]; then
        rollback
    else
        log_info "Migration completed successfully!"
        log_info "Monitor the system for 24-48 hours before scaling down Blue deployment"
    fi
}

# Run main function
main
