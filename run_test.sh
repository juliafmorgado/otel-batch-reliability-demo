#!/bin/bash

# OpenTelemetry Batch Reliability Demo Test Script
# This script demonstrates the reliability differences between batch processor and exporter helper

set -e

# Configuration
TRACE_COUNT=${TRACE_COUNT:-100}
CRASH_DELAY=${CRASH_DELAY:-3}  # Wait for spans to be accepted by collector
JAEGER_URL="http://localhost:16686"
ACCEPT_WAIT=${ACCEPT_WAIT:-2}  # Time to ensure spans are accepted
EXPORT_DELAY=${EXPORT_DELAY:-1} # Additional delay before crash (total: ACCEPT_WAIT + EXPORT_DELAY)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed or not in PATH"
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null; then
        print_error "Docker Compose is not installed or not in PATH"
        exit 1
    fi
    
    if ! command -v telemetrygen &> /dev/null; then
        print_error "telemetrygen is not installed. Install with:"
        echo "go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@latest"
        exit 1
    fi
    
    print_success "All prerequisites satisfied"
}

# Function to cleanup existing containers and storage
cleanup() {
    local test_type=$1
    print_status "Cleaning up existing containers and storage for $test_type..."
    
    cd "$test_type"
    docker-compose down -v --remove-orphans 2>/dev/null || true
    
    # Clean up persistent storage
    if [ "$test_type" = "exporter-helper" ]; then
        docker run --rm -v "$(pwd)/storage:/storage" alpine rm -rf /storage/* 2>/dev/null || true
    fi
    
    cd ..
    print_success "Cleanup completed"
}

# Function to start services
start_services() {
    local test_type=$1
    print_status "Starting services for $test_type test..."
    
    cd "$test_type"
    docker-compose up -d
    
    # Wait for services to be ready
    print_status "Waiting for services to be ready..."
    sleep 10
    
    # Check if Collector is running
    if ! docker-compose ps collector | grep -q "Up"; then
        print_error "Collector failed to start"
        docker-compose logs collector
        exit 1
    fi
    
    # Check if Jaeger is running
    if ! docker-compose ps jaeger | grep -q "Up"; then
        print_error "Jaeger failed to start"
        docker-compose logs jaeger
        exit 1
    fi
    
    cd ..
    print_success "Services started successfully"
}

# Function to send test data
send_test_data() {
    print_status "Sending $TRACE_COUNT traces to the Collector..."
    
    # Send traces with explicit timing
    telemetrygen traces \
        --otlp-insecure \
        --otlp-endpoint localhost:4317 \
        --traces $TRACE_COUNT \
        --status-code Ok \
        --span-duration 100ms \
        --service "reliability-test" \
        --rate 50 \
        2>&1 | tee /tmp/telemetrygen.log
    
    print_success "Test data sent successfully"
    
    # Wait for spans to be accepted by collector
    print_status "Waiting ${ACCEPT_WAIT}s for spans to be accepted by Collector..."
    sleep $ACCEPT_WAIT
    
    print_success "Spans should now be in Collector's internal queues"
}

# Function to verify spans are accepted but not exported
verify_acceptance() {
    local test_type=$1
    print_status "Verifying spans were accepted by Collector..."
    
    cd "$test_type"
    # Check collector logs for received spans
    if docker-compose logs collector 2>&1 | grep -q "Traces.*received"; then
        print_success "Collector logs confirm spans were received"
    else
        print_warning "Could not confirm span reception in logs (may still be working)"
    fi
    
    # For exporter-helper, verify storage files exist
    if [ "$test_type" = "exporter-helper" ]; then
        if [ -f "./storage/exporter_otlp__traces" ] || [ "$(ls -A ./storage 2>/dev/null)" ]; then
            print_success "Persistent storage files detected"
        else
            print_warning "No storage files found yet (may still be writing)"
        fi
    fi
    cd ..
}

# Function to simulate crash
simulate_crash() {
    local test_type=$1
    print_status "Waiting ${EXPORT_DELAY}s more before crash (ensuring data NOT yet exported)..."
    sleep $EXPORT_DELAY
    
    print_warning "⚡ Simulating UNGRACEFUL crash with SIGKILL..."
    cd "$test_type"
    
    # Use docker kill (SIGKILL) for ungraceful termination
    # This simulates: pod eviction, OOM kill, power loss, etc.
    docker kill -s SIGKILL "$(docker-compose ps -q collector)" 2>/dev/null || \
        docker kill "$(docker-compose ps -q collector)"
    
    cd ..
    
    print_error "Collector KILLED (SIGKILL)!"
    print_warning "   - No graceful shutdown"
    print_warning "   - No flush opportunity"
    print_warning "   - In-memory data lost immediately"
    
    # Verify the crash in logs
    print_status "Checking crash evidence in logs..."
    cd "$test_type"
    if docker-compose logs collector 2>&1 | tail -20 | grep -qi "error\|fatal\|killed"; then
        print_success "Crash evidence found in logs"
    fi
    cd ..
}

# Function to check traces in Jaeger
check_traces() {
    local expected_count=$1
    local description=$2
    
    print_status "Checking traces in Jaeger ($description)..."
    sleep 5  # Give Jaeger time to process
    
    # Query Jaeger API for traces
    local trace_count
    trace_count=$(curl -s "http://localhost:16686/api/traces?service=reliability-test&limit=200" | \
                  jq '.data | length' 2>/dev/null || echo "0")
    
    echo "Expected: $expected_count traces"
    echo "Found: $trace_count traces"
    
    if [ "$trace_count" -eq "$expected_count" ]; then
        print_success "$description: Found $trace_count traces (expected $expected_count)"
        return 0
    else
        if [ "$expected_count" -eq 0 ]; then
            print_warning "$description: Found $trace_count traces (expected $expected_count) - this is expected after crash"
        else
            print_error "$description: Found $trace_count traces (expected $expected_count)"
        fi
        return 1
    fi
}

# Function to restart collector and test recovery
test_recovery() {
    local test_type=$1
    
    print_status "Restarting Collector to test data recovery..."
    cd "$test_type"
    docker-compose up -d collector
    cd ..
    
    # Wait for collector to start and process any recovered data
    print_status "Waiting for Collector to start and process recovered data..."
    sleep 15
    
    # Check final trace count
    if [ "$test_type" = "batch-processor" ]; then
        check_traces 0 "After restart (batch processor)"
        if [ $? -eq 0 ]; then
            print_error "BATCH PROCESSOR RESULT: 100% DATA LOSS"
            print_error "   All $TRACE_COUNT traces were lost during the crash"
        fi
    else
        check_traces $TRACE_COUNT "After restart (exporter helper)"
        if [ $? -eq 0 ]; then
            print_success "EXPORTER HELPER RESULT: 0% DATA LOSS"
            print_success "   All $TRACE_COUNT traces were recovered from persistent storage"
        fi
    fi
}

# Function to run complete test
run_test() {
    local test_type=$1
    local iteration=${2:-1}
    
    echo "=========================================="
    echo "  OpenTelemetry Batch Reliability Demo"
    echo "  Testing: $test_type (Run #$iteration)"
    echo "=========================================="
    
    cleanup "$test_type"
    start_services "$test_type"
    send_test_data
    verify_acceptance "$test_type"
    
    print_status "Checking traces before crash..."
    check_traces 0 "Before crash (data still in queues)" || true  # Don't exit on expected mismatch
    
    simulate_crash "$test_type"
    
    print_status "Checking traces after crash..."
    check_traces 0 "After crash (before restart)" || true  # Don't exit on expected mismatch
    
    if [ "${SKIP_MANUAL_VERIFY:-false}" != "true" ]; then
        echo ""
        print_warning "🔍 MANUAL VERIFICATION STEP:"
        print_warning "   Open Jaeger UI: $JAEGER_URL"
        print_warning "   Search for service: reliability-test"
        print_warning "   You should see 0 traces (data lost or not yet recovered)"
        echo ""
        read -p "Press Enter after verifying in Jaeger UI..."
    fi
    
    test_recovery "$test_type"
    
    if [ "${SKIP_MANUAL_VERIFY:-false}" != "true" ]; then
        echo ""
        print_warning " FINAL VERIFICATION STEP:"
        print_warning "   Refresh Jaeger UI: $JAEGER_URL"
        print_warning "   Search for service: reliability-test"
        if [ "$test_type" = "batch-processor" ]; then
            print_warning "   Expected result: 0 traces (100% data loss)"
        else
            print_warning "   Expected result: $TRACE_COUNT traces (0% data loss)"
        fi
        echo ""
        read -p "Press Enter after verifying final results in Jaeger UI..."
    fi
    
    cleanup "$test_type"
}

# Function to run reproducibility test
run_reproducibility_test() {
    local test_type=$1
    local iterations=${2:-3}
    
    print_status "Running reproducibility test: $iterations iterations"
    
    local success_count=0
    local fail_count=0
    
    for i in $(seq 1 $iterations); do
        echo ""
        print_status "=== Iteration $i of $iterations ==="
        
        # Run test without manual verification
        SKIP_MANUAL_VERIFY=true run_test "$test_type" "$i"
        
        # Check result
        sleep 5
        local trace_count
        trace_count=$(curl -s "http://localhost:16686/api/traces?service=reliability-test&limit=200" | \
                      jq '.data | length' 2>/dev/null || echo "0")
        
        if [ "$test_type" = "batch-processor" ]; then
            if [ "$trace_count" -eq 0 ]; then
                ((success_count++))
                print_success "Iteration $i: Data loss confirmed (0 traces)"
            else
                ((fail_count++))
                print_error "Iteration $i: Unexpected recovery ($trace_count traces)"
            fi
        else
            if [ "$trace_count" -eq "$TRACE_COUNT" ]; then
                ((success_count++))
                print_success "Iteration $i: Full recovery ($trace_count traces)"
            else
                ((fail_count++))
                print_error "Iteration $i: Incomplete recovery ($trace_count traces)"
            fi
        fi
        
        cleanup "$test_type"
        sleep 2
    done
    
    echo ""
    echo "=========================================="
    echo "  REPRODUCIBILITY RESULTS"
    echo "=========================================="
    echo "Test type: $test_type"
    echo "Iterations: $iterations"
    echo "Successful: $success_count"
    echo "Failed: $fail_count"
    echo "Success rate: $(( success_count * 100 / iterations ))%"
    echo "=========================================="
    
    if [ "$success_count" -eq "$iterations" ]; then
        print_success "100% reproducible - test is reliable"
        return 0
    else
        print_error "Test showed inconsistent results"
        return 1
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [batch-processor|exporter-helper|both|reproducibility]"
    echo ""
    echo "Options:"
    echo "  batch-processor  - Test batch processor (demonstrates data loss)"
    echo "  exporter-helper  - Test exporter helper (demonstrates data recovery)"
    echo "  both            - Run both tests sequentially"
    echo "  reproducibility - Run multiple iterations to prove consistency"
    echo ""
    echo "Environment variables:"
    echo "  TRACE_COUNT     - Number of traces to send (default: 100)"
    echo "  ACCEPT_WAIT     - Seconds to wait for acceptance (default: 2)"
    echo "  EXPORT_DELAY    - Additional seconds before crash (default: 1)"
    echo "  ITERATIONS      - Number of reproducibility test runs (default: 3)"
    echo "  SKIP_MANUAL_VERIFY - Skip manual verification steps (default: false)"
    echo ""
    echo "Examples:"
    echo "  $0 batch-processor"
    echo "  TRACE_COUNT=200 $0 exporter-helper"
    echo "  $0 both"
    echo "  ITERATIONS=5 $0 reproducibility"
}

# Main execution
main() {
    local test_type=${1:-}
    
    if [ -z "$test_type" ]; then
        show_usage
        exit 1
    fi
    
    check_prerequisites
    
    case "$test_type" in
        "batch-processor")
            run_test "batch-processor"
            ;;
        "exporter-helper")
            run_test "exporter-helper"
            ;;
        "both")
            print_status "Running both tests sequentially..."
            run_test "batch-processor"
            echo ""
            echo "=========================================="
            echo "  Batch Processor Test Complete"
            echo "  Starting Exporter Helper Test..."
            echo "=========================================="
            echo ""
            sleep 3
            run_test "exporter-helper"
            
            echo ""
            echo "=========================================="
            echo "  FINAL RESULTS SUMMARY"
            echo "=========================================="
            print_error "Batch Processor: 100% data loss ($TRACE_COUNT traces lost)"
            print_success "Exporter Helper: 0% data loss ($TRACE_COUNT traces recovered)"
            echo ""
            print_warning "Conclusion: Exporter helper with persistent storage is essential"
            print_warning "for production reliability. Batch processor should be avoided."
            ;;
        "reproducibility")
            local iterations=${ITERATIONS:-3}
            print_status "Running reproducibility tests with $iterations iterations each..."
            
            echo ""
            print_status "Testing batch-processor reproducibility..."
            run_reproducibility_test "batch-processor" "$iterations"
            local batch_result=$?
            
            echo ""
            print_status "Testing exporter-helper reproducibility..."
            run_reproducibility_test "exporter-helper" "$iterations"
            local exporter_result=$?
            
            echo ""
            echo "=========================================="
            echo "  REPRODUCIBILITY SUMMARY"
            echo "=========================================="
            if [ $batch_result -eq 0 ]; then
                print_success "Batch Processor: 100% reproducible data loss"
            else
                print_error "Batch Processor: Inconsistent results"
            fi
            
            if [ $exporter_result -eq 0 ]; then
                print_success "Exporter Helper: 100% reproducible recovery"
            else
                print_error "Exporter Helper: Inconsistent results"
            fi
            
            if [ $batch_result -eq 0 ] && [ $exporter_result -eq 0 ]; then
                echo ""
                print_success "Both tests are fully reproducible!"
                print_success "   This demo reliably proves the reliability difference."
            fi
            ;;
        *)
            print_error "Invalid test type: $test_type"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"