#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_NAME="setmaxproc-webhook"
IMAGE_TAG="${IMAGE_TAG:-latest}"
NAMESPACE="setmaxproc-webhook"

echo "Deploying GOMAXPROCS mutating webhook..."

# Function to check if running on OpenShift
is_openshift() {
    kubectl api-resources | grep -q "routes" && return 0 || return 1
}

# Build Docker image
echo "Building Docker image..."
cd "$PROJECT_DIR"
docker build -t "$IMAGE_NAME:$IMAGE_TAG" .

# If running on OpenShift, we need to tag and push to internal registry
if is_openshift; then
    echo "Detected OpenShift cluster"
    
    # Get the internal registry URL
    REGISTRY=$(oc get route docker-registry -n default -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -n "$REGISTRY" ]; then
        echo "Tagging image for OpenShift internal registry..."
        docker tag "$IMAGE_NAME:$IMAGE_TAG" "$REGISTRY/$NAMESPACE/$IMAGE_NAME:$IMAGE_TAG"
        
        echo "Logging into OpenShift registry..."
        docker login -u $(oc whoami) -p $(oc whoami -t) $REGISTRY
        
        echo "Pushing image to OpenShift registry..."
        docker push "$REGISTRY/$NAMESPACE/$IMAGE_NAME:$IMAGE_TAG"
        
        # Update deployment to use the registry image
        sed -i.bak "s|image: $IMAGE_NAME:latest|image: $REGISTRY/$NAMESPACE/$IMAGE_NAME:$IMAGE_TAG|g" "$SCRIPT_DIR/02-deployment.yaml"
    else
        echo "Warning: Could not find OpenShift internal registry. Using local image."
    fi
else
    echo "Detected standard Kubernetes cluster"
    
    # For standard Kubernetes, you might want to push to a registry
    # Uncomment and modify these lines if you have a registry
    # REGISTRY="your-registry.com"
    # docker tag "$IMAGE_NAME:$IMAGE_TAG" "$REGISTRY/$IMAGE_NAME:$IMAGE_TAG"
    # docker push "$REGISTRY/$IMAGE_NAME:$IMAGE_TAG"
    # sed -i.bak "s|image: $IMAGE_NAME:latest|image: $REGISTRY/$IMAGE_NAME:$IMAGE_TAG|g" "$SCRIPT_DIR/02-deployment.yaml"
fi

# Apply Kubernetes manifests
echo "Applying Kubernetes manifests..."
cd "$SCRIPT_DIR"

kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-rbac.yaml
kubectl apply -f 02-deployment.yaml
kubectl apply -f 03-service.yaml
kubectl apply -f 04-webhook-config.yaml

# Generate TLS certificates
echo "Generating TLS certificates..."
./generate-certs.sh

# Wait for deployment to be ready
echo "Waiting for webhook deployment to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/setmaxproc-webhook -n $NAMESPACE

echo "Webhook deployment completed successfully!"
echo ""
echo "To test the webhook, create a pod with a Go application:"
echo "kubectl run test-go-app --image=golang:1.21 --command -- sleep infinity"
echo ""
echo "To skip the webhook for specific pods, add this annotation:"
echo "setmaxproc.webhook/skip: \"true\""
echo ""
echo "To check webhook logs:"
echo "kubectl logs -l app=setmaxproc-webhook -n $NAMESPACE" 