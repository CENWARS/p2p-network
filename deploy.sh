#!/bin/bash

# Deployment script for P2P Network on Kubernetes

set -e

NAMESPACE="net-test"
IMAGE_NAME="p2p-network:latest"

echo "🚀 Deploying P2P Network to Kubernetes cluster..."
echo "Namespace: ${NAMESPACE}"
echo "Image: ${IMAGE_NAME}"

# Function to check if namespace exists
check_namespace() {
    if ! kubectl get namespace "${NAMESPACE}" > /dev/null 2>&1; then
        echo "❌ Namespace '${NAMESPACE}' does not exist!"
        echo "Please create it first: kubectl create namespace ${NAMESPACE}"
        exit 1
    fi
    echo "✅ Namespace '${NAMESPACE}' exists"
}

# Function to build Docker image
build_image() {
    echo "📦 Building Docker image..."
    ./build.sh latest
    echo "✅ Docker image built successfully"
}

# Function to load image to kind/minikube if needed
load_image_to_cluster() {
    # Detect cluster type and load image if needed
    if command -v kind >/dev/null 2>&1; then
        KIND_CLUSTERS=$(kind get clusters 2>/dev/null || echo "")
        if [ ! -z "$KIND_CLUSTERS" ]; then
            echo "🔄 Loading image to kind cluster..."
            kind load docker-image "${IMAGE_NAME}"
            echo "✅ Image loaded to kind cluster"
            return
        fi
    fi
    
    if command -v minikube >/dev/null 2>&1; then
        if minikube status >/dev/null 2>&1; then
            echo "🔄 Loading image to minikube..."
            minikube image load "${IMAGE_NAME}"
            echo "✅ Image loaded to minikube"
            return
        fi
    fi
    
    echo "ℹ️  Using local Docker image (assuming Docker Desktop with Kubernetes)"
}

# Function to deploy to Kubernetes
deploy_to_k8s() {
    echo "🚀 Deploying to Kubernetes..."
    kubectl apply -f k8s-manifests.yaml
    echo "✅ Manifests applied successfully"
}

# Function to wait for deployments
wait_for_deployments() {
    echo "⏳ Waiting for deployments to be ready..."
    
    echo "Waiting for bootstrap deployment..."
    kubectl wait --for=condition=available --timeout=300s deployment/p2p-bootstrap -n "${NAMESPACE}"
    
    echo "Waiting for relay deployment..."
    kubectl wait --for=condition=available --timeout=300s deployment/p2p-relay -n "${NAMESPACE}"
    
    echo "Waiting for worker deployment..."
    kubectl wait --for=condition=available --timeout=300s deployment/p2p-worker -n "${NAMESPACE}"
    
    echo "✅ All deployments are ready!"
}

# Function to show status
show_status() {
    echo ""
    echo "📊 Cluster Status:"
    echo "=================="
    kubectl get pods -n "${NAMESPACE}" -o wide
    echo ""
    kubectl get services -n "${NAMESPACE}"
    echo ""
    echo "📝 Pod logs preview:"
    echo "==================="
    kubectl logs -n "${NAMESPACE}" -l role=bootstrap --tail=10 --prefix=true || echo "No bootstrap logs yet"
}

# Function to show connection info
show_connection_info() {
    echo ""
    echo "🔗 Connection Information:"
    echo "=========================="
    echo "To check logs:"
    echo "  kubectl logs -n ${NAMESPACE} -l role=bootstrap -f"
    echo "  kubectl logs -n ${NAMESPACE} -l role=relay -f"
    echo "  kubectl logs -n ${NAMESPACE} -l role=worker -f"
    echo ""
    echo "To exec into a pod:"
    echo "  kubectl exec -n ${NAMESPACE} -it \$(kubectl get pods -n ${NAMESPACE} -l role=worker -o jsonpath='{.items[0].metadata.name}') -- /bin/bash"
    echo ""
    echo "To port-forward for testing:"
    echo "  kubectl port-forward -n ${NAMESPACE} svc/p2p-bootstrap 4001:4001"
}

# Main execution
main() {
    echo "🏁 Starting P2P Network deployment..."
    
    check_namespace
    build_image
    load_image_to_cluster
    deploy_to_k8s
    wait_for_deployments
    show_status
    show_connection_info
    
    echo ""
    echo "🎉 Deployment completed successfully!"
    echo "The P2P network is now running in the '${NAMESPACE}' namespace."
}

# Handle command line arguments
case "${1:-deploy}" in
    "deploy")
        main
        ;;
    "status")
        show_status
        ;;
    "logs")
        kubectl logs -n "${NAMESPACE}" -l app=p2p-network -f --max-log-requests=10
        ;;
    "clean")
        echo "🧹 Cleaning up deployment..."
        kubectl delete -f k8s-manifests.yaml || echo "Some resources may not exist"
        echo "✅ Cleanup completed"
        ;;
    "help")
        echo "Usage: $0 [deploy|status|logs|clean|help]"
        echo "  deploy  - Build and deploy the P2P network (default)"
        echo "  status  - Show current deployment status"
        echo "  logs    - Stream logs from all pods"
        echo "  clean   - Remove the deployment"
        echo "  help    - Show this help message"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac
