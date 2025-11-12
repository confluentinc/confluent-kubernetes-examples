#!/bin/bash

# Client Test Script for Gateway Switchover Validation
# This script tests producer and consumer functionality through the Gateway

set -e

# Configuration
GATEWAY_ENDPOINT="${GATEWAY_ENDPOINT:-gateway.example.com:9092}"
TEST_TOPIC="${TEST_TOPIC:-test-migration}"
CLIENT_CONFIG="${CLIENT_CONFIG:-client.properties}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Create client configuration
create_client_config() {
    if [ ! -f "$CLIENT_CONFIG" ]; then
        log_info "Creating client configuration..."
        cat > $CLIENT_CONFIG <<EOF
bootstrap.servers=$GATEWAY_ENDPOINT
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \\
  username="kafka" \\
  password="kafka-secret";
EOF
        log_success "Client configuration created: $CLIENT_CONFIG"
    else
        log_info "Using existing client configuration: $CLIENT_CONFIG"
    fi
}

# Test basic producer
test_producer() {
    log_test "Testing basic producer..."
    
    # Send test messages
    for i in {1..10}; do
        echo "test-message-$i-$(date +%s)" | kafka-console-producer \
            --bootstrap-server $GATEWAY_ENDPOINT \
            --producer.config $CLIENT_CONFIG \
            --topic $TEST_TOPIC 2>/dev/null || {
                log_error "Producer test failed at message $i"
                return 1
            }
    done
    
    log_success "Successfully produced 10 test messages"
}

# Test idempotent producer
test_idempotent_producer() {
    log_test "Testing idempotent producer..."
    
    # Create idempotent producer config
    cat > idempotent-producer.properties <<EOF
$(cat $CLIENT_CONFIG)
enable.idempotence=true
acks=all
retries=3
max.in.flight.requests.per.connection=5
EOF
    
    # Send test messages
    echo "idempotent-test-$(date +%s)" | kafka-console-producer \
        --bootstrap-server $GATEWAY_ENDPOINT \
        --producer.config idempotent-producer.properties \
        --topic $TEST_TOPIC 2>/dev/null || {
            log_error "Idempotent producer test failed"
            return 1
        }
    
    log_success "Idempotent producer test passed"
}

# Test consumer
test_consumer() {
    log_test "Testing consumer..."
    
    # Consume messages with timeout
    MESSAGES=$(timeout 10 kafka-console-consumer \
        --bootstrap-server $GATEWAY_ENDPOINT \
        --consumer.config $CLIENT_CONFIG \
        --topic $TEST_TOPIC \
        --from-beginning \
        --max-messages 5 2>/dev/null | wc -l)
    
    if [ "$MESSAGES" -gt 0 ]; then
        log_success "Successfully consumed $MESSAGES messages"
    else
        log_error "Consumer test failed - no messages consumed"
        return 1
    fi
}

# Test consumer groups
test_consumer_groups() {
    log_test "Testing consumer groups..."
    
    # Create consumer group
    GROUP_ID="test-group-$(date +%s)"
    
    # Consume with consumer group
    timeout 5 kafka-console-consumer \
        --bootstrap-server $GATEWAY_ENDPOINT \
        --consumer.config $CLIENT_CONFIG \
        --topic $TEST_TOPIC \
        --group $GROUP_ID \
        --from-beginning \
        --max-messages 3 >/dev/null 2>&1
    
    # Check consumer group
    kafka-consumer-groups --describe \
        --bootstrap-server $GATEWAY_ENDPOINT \
        --command-config $CLIENT_CONFIG \
        --group $GROUP_ID >/dev/null 2>&1 || {
            log_error "Consumer group test failed"
            return 1
        }
    
    log_success "Consumer group test passed"
}

# Test transactional producer
test_transactional_producer() {
    log_test "Testing transactional producer..."
    
    # Create a simple Java test for transactions (using Kafka CLI tools)
    cat > transaction-test.sh <<'EOF'
#!/bin/bash
kafka-transactions \
  --bootstrap-server $1 \
  --command-config $2 \
  --transaction-id "test-txn-$(date +%s)" \
  --execute "
    begin
    send --topic $3 --key k1 --value v1
    send --topic $3 --key k2 --value v2
    commit
  " 2>/dev/null
EOF
    chmod +x transaction-test.sh
    
    # Run transaction test
    ./transaction-test.sh $GATEWAY_ENDPOINT $CLIENT_CONFIG $TEST_TOPIC || {
        log_error "Transactional producer test failed"
        return 1
    }
    
    log_success "Transactional producer test passed"
}

# Test high throughput
test_high_throughput() {
    log_test "Testing high throughput..."
    
    # Produce 1000 messages
    seq 1 1000 | kafka-console-producer \
        --bootstrap-server $GATEWAY_ENDPOINT \
        --producer.config $CLIENT_CONFIG \
        --topic $TEST_TOPIC \
        --batch-size 100 2>/dev/null || {
            log_error "High throughput test failed"
            return 1
        }
    
    log_success "Successfully produced 1000 messages"
}

# Monitor connection stability
test_connection_stability() {
    log_test "Testing connection stability (30 seconds)..."
    
    SUCCESS_COUNT=0
    FAILURE_COUNT=0
    
    for i in {1..30}; do
        echo "stability-test-$i" | kafka-console-producer \
            --bootstrap-server $GATEWAY_ENDPOINT \
            --producer.config $CLIENT_CONFIG \
            --topic $TEST_TOPIC 2>/dev/null && \
            ((SUCCESS_COUNT++)) || ((FAILURE_COUNT++))
        sleep 1
    done
    
    log_info "Connection stability: Success=$SUCCESS_COUNT, Failures=$FAILURE_COUNT"
    
    if [ "$FAILURE_COUNT" -gt 3 ]; then
        log_error "Connection stability test failed - too many failures"
        return 1
    fi
    
    log_success "Connection stability test passed"
}

# Performance metrics
test_performance() {
    log_test "Testing performance metrics..."
    
    # Measure produce latency
    START_TIME=$(date +%s%N)
    for i in {1..100}; do
        echo "perf-test-$i" | kafka-console-producer \
            --bootstrap-server $GATEWAY_ENDPOINT \
            --producer.config $CLIENT_CONFIG \
            --topic $TEST_TOPIC 2>/dev/null
    done
    END_TIME=$(date +%s%N)
    
    # Calculate average latency
    TOTAL_TIME=$((($END_TIME - $START_TIME) / 1000000))
    AVG_LATENCY=$(($TOTAL_TIME / 100))
    
    log_info "Average produce latency: ${AVG_LATENCY}ms per message"
    
    if [ "$AVG_LATENCY" -gt 100 ]; then
        log_error "Performance test warning - high latency detected"
    else
        log_success "Performance test passed"
    fi
}

# Run comprehensive test suite
run_test_suite() {
    log_info "Starting Gateway Client Test Suite"
    echo "===================================="
    
    # Create topic if it doesn't exist
    kafka-topics --create \
        --bootstrap-server $GATEWAY_ENDPOINT \
        --command-config $CLIENT_CONFIG \
        --topic $TEST_TOPIC \
        --partitions 3 \
        --replication-factor 1 \
        --if-not-exists 2>/dev/null
    
    # Run tests
    TESTS_PASSED=0
    TESTS_FAILED=0
    
    # List of tests to run
    TESTS=(
        "test_producer"
        "test_consumer"
        "test_consumer_groups"
        "test_idempotent_producer"
        "test_high_throughput"
        "test_connection_stability"
        "test_performance"
    )
    
    # Execute each test
    for test in "${TESTS[@]}"; do
        echo ""
        if $test; then
            ((TESTS_PASSED++))
        else
            ((TESTS_FAILED++))
            log_error "Test $test failed"
        fi
    done
    
    # Summary
    echo ""
    echo "===================================="
    log_info "Test Suite Summary"
    log_info "Tests Passed: $TESTS_PASSED"
    log_info "Tests Failed: $TESTS_FAILED"
    
    if [ "$TESTS_FAILED" -eq 0 ]; then
        log_success "All tests passed successfully! ✓"
        exit 0
    else
        log_error "Some tests failed. Please review the errors above."
        exit 1
    fi
}

# Continuous monitoring mode
monitor_mode() {
    log_info "Starting continuous monitoring mode (Ctrl+C to stop)..."
    
    while true; do
        TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
        
        # Test producer
        echo "monitor-$TIMESTAMP" | kafka-console-producer \
            --bootstrap-server $GATEWAY_ENDPOINT \
            --producer.config $CLIENT_CONFIG \
            --topic $TEST_TOPIC 2>/dev/null && \
            echo "[$TIMESTAMP] Producer: ✓" || \
            echo "[$TIMESTAMP] Producer: ✗"
        
        # Test consumer
        timeout 2 kafka-console-consumer \
            --bootstrap-server $GATEWAY_ENDPOINT \
            --consumer.config $CLIENT_CONFIG \
            --topic $TEST_TOPIC \
            --max-messages 1 >/dev/null 2>&1 && \
            echo "[$TIMESTAMP] Consumer: ✓" || \
            echo "[$TIMESTAMP] Consumer: ✗"
        
        sleep 5
    done
}

# Main execution
main() {
    # Parse arguments
    case "${1:-test}" in
        test)
            create_client_config
            run_test_suite
            ;;
        monitor)
            create_client_config
            monitor_mode
            ;;
        *)
            echo "Usage: $0 [test|monitor]"
            echo "  test    - Run comprehensive test suite"
            echo "  monitor - Continuous monitoring mode"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
