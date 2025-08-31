#!/bin/bash

# Stress test script for P2P Network
# Tests network resilience, performance, and scalability

set -e

NAMESPACE="net-test"
TEST_DURATION=300  # 5 minutes default
CONCURRENT_TASKS=10
MESSAGE_SIZE=1024  # 1KB default
SCALE_UP_WORKERS=5

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ️  INFO:${NC} $1"
}

log_success() {
    echo -e "${GREEN}✅ SUCCESS:${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠️  WARNING:${NC} $1"
}

log_error() {
    echo -e "${RED}❌ ERROR:${NC} $1"
}

log_test() {
    echo -e "${PURPLE}🧪 TEST:${NC} $1"
}

log_metric() {
    echo -e "${CYAN}📊 METRIC:${NC} $1"
}

# Helper functions
get_pods_by_role() {
    local role=$1
    kubectl get pods -n "${NAMESPACE}" -l role="${role}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' || echo ""
}

get_random_pod() {
    local role=$1
    local pods=($(get_pods_by_role "$role"))
    if [ ${#pods[@]} -eq 0 ]; then
        echo ""
        return 1
    fi
    echo "${pods[$((RANDOM % ${#pods[@]}))]}"
}

wait_for_pods_ready() {
    local timeout=300
    local start_time=$(date +%s)
    
    log_info "Waiting for all pods to be ready..."
    
    while true; do
        local current_time=$(date +%s)
        if [ $((current_time - start_time)) -gt $timeout ]; then
            log_error "Timeout waiting for pods to be ready"
            return 1
        fi
        
        local ready_pods=$(kubectl get pods -n "${NAMESPACE}" --no-headers | grep -c "1/1.*Running" || echo "0")
        local total_pods=$(kubectl get pods -n "${NAMESPACE}" --no-headers | wc -l)
        
        if [ "$ready_pods" -eq "$total_pods" ] && [ "$total_pods" -gt 0 ]; then
            log_success "All $total_pods pods are ready"
            break
        fi
        
        log_info "Ready: $ready_pods/$total_pods pods..."
        sleep 5
    done
}

# Performance test functions
test_network_latency() {
    log_test "Testing network latency between pods"
    
    local worker_pods=($(get_pods_by_role "worker"))
    local bootstrap_pod=$(get_random_pod "bootstrap")
    
    if [ ${#worker_pods[@]} -lt 2 ] || [ -z "$bootstrap_pod" ]; then
        log_warning "Insufficient pods for latency test"
        return 1
    fi
    
    local total_latency=0
    local test_count=0
    
    for worker in "${worker_pods[@]}"; do
        log_info "Testing latency from $worker to bootstrap service..."
        
        # Use ping to test network latency
        local latency=$(kubectl exec -n "${NAMESPACE}" "$worker" -- \
            ping -c 3 p2p-bootstrap.net-test.svc.cluster.local 2>/dev/null | \
            grep "avg" | awk -F'/' '{print $5}' || echo "0")
        
        if [ "$latency" != "0" ] && [ ! -z "$latency" ]; then
            total_latency=$(echo "$total_latency + $latency" | bc -l 2>/dev/null || echo "$total_latency")
            test_count=$((test_count + 1))
            log_metric "Latency from $worker: ${latency}ms"
        fi
    done
    
    if [ $test_count -gt 0 ]; then
        local avg_latency=$(echo "scale=2; $total_latency / $test_count" | bc -l 2>/dev/null || echo "N/A")
        log_metric "Average network latency: ${avg_latency}ms"
    fi
}

test_concurrent_connections() {
    log_test "Testing concurrent peer connections"
    
    local worker_pods=($(get_pods_by_role "worker"))
    local test_duration=60
    
    log_info "Starting concurrent connection test for ${test_duration}s..."
    
    # Start multiple peer discovery processes
    local pids=()
    for worker in "${worker_pods[@]}"; do
        (
            for i in $(seq 1 10); do
                kubectl exec -n "${NAMESPACE}" "$worker" -- timeout 5s sh -c 'echo "peers" | ./p2p-node --config /app/config.yaml' >/dev/null 2>&1 || true
                sleep 1
            done
        ) &
        pids+=($!)
    done
    
    # Wait for test completion
    sleep $test_duration
    
    # Clean up background processes
    for pid in "${pids[@]}"; do
        kill $pid 2>/dev/null || true
    done
    
    log_success "Concurrent connection test completed"
}

test_message_throughput() {
    log_test "Testing message throughput under load"
    
    local worker_pods=($(get_pods_by_role "worker"))
    local message_count=100
    local test_duration=120
    
    if [ ${#worker_pods[@]} -eq 0 ]; then
        log_warning "No worker pods available for throughput test"
        return 1
    fi
    
    log_info "Sending $message_count messages from each worker pod..."
    
    local start_time=$(date +%s)
    local total_messages=0
    local pids=()
    
    # Start message sending from each worker
    for worker in "${worker_pods[@]}"; do
        (
            local sent=0
            for i in $(seq 1 $message_count); do
                local payload=$(head -c $MESSAGE_SIZE /dev/urandom | base64 | tr -d '\n' | head -c $MESSAGE_SIZE)
                kubectl exec -n "${NAMESPACE}" "$worker" -- timeout 3s sh -c "echo 'task throughput_test $payload' | ./p2p-node --config /app/config.yaml" >/dev/null 2>&1 || true
                sent=$((sent + 1))
                
                # Brief pause to avoid overwhelming
                sleep 0.1
            done
            echo $sent
        ) &
        pids+=($!)
    done
    
    # Wait for completion or timeout
    sleep $test_duration
    
    # Collect results
    for pid in "${pids[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            kill $pid 2>/dev/null || true
        fi
        wait $pid 2>/dev/null && total_messages=$((total_messages + $(jobs -p | wc -l))) || true
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local throughput=$(echo "scale=2; $total_messages / $duration" | bc -l 2>/dev/null || echo "N/A")
    
    log_metric "Total messages sent: $total_messages"
    log_metric "Test duration: ${duration}s"
    log_metric "Average throughput: ${throughput} messages/second"
}

test_pod_failure_resilience() {
    log_test "Testing network resilience to pod failures"
    
    local initial_pods=$(kubectl get pods -n "${NAMESPACE}" --no-headers | wc -l)
    log_info "Initial pod count: $initial_pods"
    
    # Kill a random worker pod
    local worker_to_kill=$(get_random_pod "worker")
    if [ ! -z "$worker_to_kill" ]; then
        log_info "Killing pod: $worker_to_kill"
        kubectl delete pod -n "${NAMESPACE}" "$worker_to_kill" --force --grace-period=0
        
        # Wait for replacement pod
        log_info "Waiting for pod replacement..."
        sleep 30
        
        # Check if network is still functional
        wait_for_pods_ready
        
        local final_pods=$(kubectl get pods -n "${NAMESPACE}" --no-headers | wc -l)
        if [ "$final_pods" -eq "$initial_pods" ]; then
            log_success "Pod failure resilience test passed"
        else
            log_warning "Pod count changed after failure: $initial_pods -> $final_pods"
        fi
    fi
}

test_network_partition() {
    log_test "Testing network partition tolerance"
    
    log_info "Simulating network partition by blocking traffic to bootstrap node..."
    
    # Create a network policy to isolate bootstrap
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-bootstrap
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      role: bootstrap
  policyTypes:
  - Ingress
  - Egress
  ingress: []
  egress: []
EOF

    # Wait and observe
    log_info "Network partition active for 60 seconds..."
    sleep 60
    
    # Check if other nodes can still communicate
    local worker_pods=($(get_pods_by_role "worker"))
    local relay_pod=$(get_random_pod "relay")
    
    if [ ${#worker_pods[@]} -gt 0 ] && [ ! -z "$relay_pod" ]; then
        local test_worker="${worker_pods[0]}"
        log_info "Testing worker->relay connectivity during partition..."
        
        kubectl exec -n "${NAMESPACE}" "$test_worker" -- nc -zv p2p-relay.net-test.svc.cluster.local 4001 2>/dev/null && \
            log_success "Relay communication maintained during partition" || \
            log_warning "Relay communication affected by partition"
    fi
    
    # Remove network policy
    kubectl delete networkpolicy isolate-bootstrap -n "${NAMESPACE}" 2>/dev/null || true
    log_info "Network partition removed"
    
    # Wait for recovery
    sleep 30
    log_success "Network partition test completed"
}

test_resource_consumption() {
    log_test "Testing resource consumption under load"
    
    log_info "Collecting resource metrics..."
    
    # Get resource usage for all pods
    kubectl top pods -n "${NAMESPACE}" --no-headers 2>/dev/null | while read pod cpu memory; do
        log_metric "Pod $pod: CPU=${cpu}, Memory=${memory}"
    done || log_warning "kubectl top not available (metrics server required)"
    
    # Check for OOMKilled or resource-related restarts
    local oom_count=$(kubectl get pods -n "${NAMESPACE}" -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' | tr ' ' '\n' | awk '{sum+=$1} END {print sum+0}')
    log_metric "Total pod restarts: $oom_count"
    
    # Check resource limits vs requests
    kubectl describe pods -n "${NAMESPACE}" | grep -E "(Requests|Limits):" | while read line; do
        log_metric "Resource: $line"
    done
}

test_scaling_behavior() {
    log_test "Testing horizontal scaling behavior"
    
    local initial_workers=$(get_pods_by_role "worker" | wc -l)
    log_info "Initial worker count: $initial_workers"
    
    # Scale up workers
    log_info "Scaling up workers to $SCALE_UP_WORKERS..."
    kubectl scale deployment p2p-worker -n "${NAMESPACE}" --replicas=$SCALE_UP_WORKERS
    
    # Wait for scale up
    log_info "Waiting for scale up to complete..."
    kubectl wait --for=condition=available --timeout=300s deployment/p2p-worker -n "${NAMESPACE}"
    
    wait_for_pods_ready
    
    local scaled_workers=$(get_pods_by_role "worker" | wc -l)
    log_metric "Scaled worker count: $scaled_workers"
    
    # Test network with more workers
    sleep 30
    test_concurrent_connections
    
    # Scale back down
    log_info "Scaling back down to original size..."
    kubectl scale deployment p2p-worker -n "${NAMESPACE}" --replicas=$initial_workers
    
    kubectl wait --for=condition=available --timeout=300s deployment/p2p-worker -n "${NAMESPACE}"
    wait_for_pods_ready
    
    log_success "Scaling test completed"
}

test_long_running_stability() {
    log_test "Testing long-running stability"
    
    log_info "Starting ${TEST_DURATION}s stability test..."
    
    local start_time=$(date +%s)
    local end_time=$((start_time + TEST_DURATION))
    local check_interval=30
    local error_count=0
    
    while [ $(date +%s) -lt $end_time ]; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        local remaining=$((end_time - current_time))
        
        log_info "Stability test: ${elapsed}s elapsed, ${remaining}s remaining"
        
        # Check pod health
        local unhealthy=$(kubectl get pods -n "${NAMESPACE}" --no-headers | grep -v "1/1.*Running" | wc -l)
        if [ $unhealthy -gt 0 ]; then
            error_count=$((error_count + 1))
            log_warning "Found $unhealthy unhealthy pods"
        fi
        
        # Test basic connectivity
        local worker=$(get_random_pod "worker")
        if [ ! -z "$worker" ]; then
            kubectl exec -n "${NAMESPACE}" "$worker" -- nc -zv p2p-bootstrap.net-test.svc.cluster.local 4001 >/dev/null 2>&1 || {
                error_count=$((error_count + 1))
                log_warning "Connectivity check failed"
            }
        fi
        
        sleep $check_interval
    done
    
    log_metric "Stability test completed with $error_count errors"
    if [ $error_count -eq 0 ]; then
        log_success "System remained stable throughout the test"
    else
        log_warning "System experienced $error_count stability issues"
    fi
}

generate_stress_report() {
    log_info "Generating stress test report..."
    
    echo ""
    echo "========================================"
    echo "         P2P NETWORK STRESS REPORT"
    echo "========================================"
    echo "Test Duration: ${TEST_DURATION}s"
    echo "Message Size: ${MESSAGE_SIZE} bytes"
    echo "Concurrent Tasks: ${CONCURRENT_TASKS}"
    echo "Scale Target: ${SCALE_UP_WORKERS} workers"
    echo ""
    
    echo "Current Cluster State:"
    echo "----------------------"
    kubectl get pods -n "${NAMESPACE}" -o wide
    echo ""
    
    echo "Resource Usage:"
    echo "---------------"
    kubectl top pods -n "${NAMESPACE}" 2>/dev/null || echo "Metrics server not available"
    echo ""
    
    echo "Recent Events:"
    echo "--------------"
    kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -10
    echo ""
    
    echo "Network Policies:"
    echo "-----------------"
    kubectl get networkpolicies -n "${NAMESPACE}" 2>/dev/null || echo "No network policies found"
    echo ""
}

cleanup_test_artifacts() {
    log_info "Cleaning up test artifacts..."
    
    # Remove any test network policies
    kubectl delete networkpolicy isolate-bootstrap -n "${NAMESPACE}" 2>/dev/null || true
    
    # Reset worker replicas to original count
    kubectl scale deployment p2p-worker -n "${NAMESPACE}" --replicas=2 2>/dev/null || true
    
    log_success "Cleanup completed"
}

# Main stress test execution
main() {
    echo ""
    echo "🚀 P2P Network Stress Test Suite"
    echo "================================="
    echo "Namespace: ${NAMESPACE}"
    echo "Duration: ${TEST_DURATION}s"
    echo "Message Size: ${MESSAGE_SIZE} bytes"
    echo "Concurrent Tasks: ${CONCURRENT_TASKS}"
    echo ""
    
    # Ensure cleanup on exit
    trap cleanup_test_artifacts EXIT
    
    # Wait for initial readiness
    wait_for_pods_ready || {
        log_error "Pods not ready, aborting stress test"
        exit 1
    }
    
    # Run stress tests
    test_network_latency
    echo ""
    
    test_concurrent_connections
    echo ""
    
    test_message_throughput
    echo ""
    
    test_resource_consumption
    echo ""
    
    test_scaling_behavior
    echo ""
    
    test_pod_failure_resilience
    echo ""
    
    test_network_partition
    echo ""
    
    test_long_running_stability
    echo ""
    
    generate_stress_report
    
    log_success "🎉 Stress test suite completed!"
}

# Command line argument parsing
case "${1:-stress}" in
    "stress"|"all")
        main
        ;;
    "latency")
        wait_for_pods_ready && test_network_latency
        ;;
    "throughput")
        wait_for_pods_ready && test_message_throughput
        ;;
    "resilience")
        wait_for_pods_ready && test_pod_failure_resilience
        ;;
    "partition")
        wait_for_pods_ready && test_network_partition
        ;;
    "scaling")
        wait_for_pods_ready && test_scaling_behavior
        ;;
    "stability")
        wait_for_pods_ready && test_long_running_stability
        ;;
    "resources")
        wait_for_pods_ready && test_resource_consumption
        ;;
    "report")
        generate_stress_report
        ;;
    "cleanup")
        cleanup_test_artifacts
        ;;
    "help")
        echo "Usage: $0 [stress|latency|throughput|resilience|partition|scaling|stability|resources|report|cleanup|help]"
        echo ""
        echo "Commands:"
        echo "  stress      - Run full stress test suite (default)"
        echo "  latency     - Test network latency"
        echo "  throughput  - Test message throughput"
        echo "  resilience  - Test pod failure resilience"
        echo "  partition   - Test network partition tolerance"
        echo "  scaling     - Test horizontal scaling"
        echo "  stability   - Test long-running stability"
        echo "  resources   - Check resource consumption"
        echo "  report      - Generate current status report"
        echo "  cleanup     - Clean up test artifacts"
        echo "  help        - Show this help"
        echo ""
        echo "Environment variables:"
        echo "  TEST_DURATION     - Test duration in seconds (default: 300)"
        echo "  CONCURRENT_TASKS  - Number of concurrent tasks (default: 10)"
        echo "  MESSAGE_SIZE      - Message size in bytes (default: 1024)"
        echo "  SCALE_UP_WORKERS  - Target worker count for scaling test (default: 5)"
        echo "  NAMESPACE         - Kubernetes namespace (default: net-test)"
        ;;
    *)
        log_error "Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac
