#!/bin/bash

# Test script for P2P Network functionality

set -e

NAMESPACE="net-test"

echo "🧪 Testing P2P Network functionality..."

# Function to get pod name by role
get_pod_by_role() {
    local role=$1
    kubectl get pods -n "${NAMESPACE}" -l role="${role}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

# Function to test peer connectivity
test_peer_connectivity() {
    echo "🔗 Testing peer connectivity..."
    
    local worker_pod=$(get_pod_by_role "worker")
    if [ -z "$worker_pod" ]; then
        echo "❌ No worker pod found"
        return 1
    fi
    
    echo "Using worker pod: $worker_pod"
    
    # Test the 'peers' command
    echo "Checking connected peers..."
    kubectl exec -n "${NAMESPACE}" "$worker_pod" -- timeout 10s sh -c 'echo "peers" | ./p2p-node --config /app/config.yaml' || echo "Command timed out (expected for interactive mode)"
}

# Function to test network discovery
test_network_discovery() {
    echo "🔍 Testing network discovery..."
    
    # Check if pods can see each other via DNS
    local bootstrap_pod=$(get_pod_by_role "bootstrap")
    local relay_pod=$(get_pod_by_role "relay")
    local worker_pod=$(get_pod_by_role "worker")
    
    if [ ! -z "$worker_pod" ] && [ ! -z "$bootstrap_pod" ]; then
        echo "Testing DNS resolution from worker to bootstrap..."
        kubectl exec -n "${NAMESPACE}" "$worker_pod" -- nslookup p2p-bootstrap.net-test.svc.cluster.local || echo "DNS resolution test failed"
    fi
}

# Function to check logs for peer connections
test_peer_connections_in_logs() {
    echo "📋 Checking logs for peer connections..."
    
    echo "Bootstrap node logs (last 20 lines):"
    kubectl logs -n "${NAMESPACE}" -l role=bootstrap --tail=20 | grep -E "(Connection established|Listening on|Local peer id)" || echo "No connection info found in bootstrap logs"
    
    echo ""
    echo "Worker node logs (last 20 lines):"
    kubectl logs -n "${NAMESPACE}" -l role=worker --tail=20 | grep -E "(Connection established|Listening on|Local peer id)" || echo "No connection info found in worker logs"
}

# Function to test port connectivity
test_port_connectivity() {
    echo "🔌 Testing port connectivity..."
    
    local worker_pod=$(get_pod_by_role "worker")
    if [ ! -z "$worker_pod" ]; then
        echo "Testing if worker pod can reach bootstrap service..."
        kubectl exec -n "${NAMESPACE}" "$worker_pod" -- nc -zv p2p-bootstrap.net-test.svc.cluster.local 4001 || echo "Port test failed"
        
        echo "Testing if worker pod can reach relay service..."
        kubectl exec -n "${NAMESPACE}" "$worker_pod" -- nc -zv p2p-relay.net-test.svc.cluster.local 4001 || echo "Port test failed"
    fi
}

# Function to simulate P2P task submission
test_task_submission() {
    echo "🎯 Testing task submission..."
    
    local worker_pod=$(get_pod_by_role "worker")
    if [ ! -z "$worker_pod" ]; then
        echo "Submitting a test task..."
        kubectl exec -n "${NAMESPACE}" "$worker_pod" -- timeout 5s sh -c 'echo "task compute test_payload" | ./p2p-node --config /app/config.yaml' || echo "Task submission test completed (timeout expected)"
    fi
}

# Function to show network topology
show_network_topology() {
    echo "🌐 Network Topology:"
    echo "==================="
    
    echo "Pods:"
    kubectl get pods -n "${NAMESPACE}" -o wide
    
    echo ""
    echo "Services:"
    kubectl get services -n "${NAMESPACE}"
    
    echo ""
    echo "Endpoints:"
    kubectl get endpoints -n "${NAMESPACE}"
}

# Function to show peer IDs from logs
show_peer_ids() {
    echo "🆔 Peer IDs:"
    echo "============"
    
    echo "Bootstrap peer ID:"
    kubectl logs -n "${NAMESPACE}" -l role=bootstrap | grep "Local peer id" | tail -1 || echo "No peer ID found"
    
    echo "Relay peer ID:"
    kubectl logs -n "${NAMESPACE}" -l role=relay | grep "Local peer id" | tail -1 || echo "No peer ID found"
    
    echo "Worker peer IDs:"
    kubectl logs -n "${NAMESPACE}" -l role=worker | grep "Local peer id" || echo "No peer IDs found"
}

# Function to monitor network activity
monitor_network() {
    echo "📡 Monitoring network activity (30 seconds)..."
    echo "Press Ctrl+C to stop monitoring"
    
    timeout 30s kubectl logs -n "${NAMESPACE}" -l app=p2p-network -f --max-log-requests=10 | grep -E "(Connection|Discovered|Bootstrap|Message)" || echo "Monitoring completed"
}

# Main test execution
main() {
    echo "🏁 Starting P2P Network tests..."
    echo "Namespace: ${NAMESPACE}"
    echo ""
    
    # Wait a bit for pods to be fully ready
    echo "⏳ Waiting for pods to be ready..."
    sleep 10
    
    show_network_topology
    echo ""
    
    show_peer_ids
    echo ""
    
    test_port_connectivity
    echo ""
    
    test_network_discovery
    echo ""
    
    test_peer_connections_in_logs
    echo ""
    
    test_peer_connectivity
    echo ""
    
    test_task_submission
    echo ""
    
    echo "🎉 Test suite completed!"
    echo ""
    echo "For continuous monitoring, run:"
    echo "$0 monitor"
}

# Handle command line arguments
case "${1:-test}" in
    "test")
        main
        ;;
    "topology")
        show_network_topology
        ;;
    "peers")
        show_peer_ids
        ;;
    "monitor")
        monitor_network
        ;;
    "connectivity")
        test_port_connectivity
        test_network_discovery
        ;;
    "help")
        echo "Usage: $0 [test|topology|peers|monitor|connectivity|help]"
        echo "  test         - Run full test suite (default)"
        echo "  topology     - Show network topology"
        echo "  peers        - Show peer IDs"
        echo "  monitor      - Monitor network activity"
        echo "  connectivity - Test basic connectivity"
        echo "  help         - Show this help message"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac
