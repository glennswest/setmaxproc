#!/bin/bash

set -e

PROFILE_NAME="clusteradmin.json"
PROFILE_SOURCE="profiles/${PROFILE_NAME}"
PROFILE_TARGET="/var/lib/kubelet/seccomp/profiles/${PROFILE_NAME}"

echo "Deploying seccomp profile: ${PROFILE_NAME}"

# Check if profile source exists
if [ ! -f "$PROFILE_SOURCE" ]; then
    echo "Error: Seccomp profile not found at $PROFILE_SOURCE"
    exit 1
fi

# Function to check if running on a node or need to deploy via DaemonSet
deploy_via_daemonset() {
    echo "Deploying seccomp profile via DaemonSet..."
    
    # Create a ConfigMap with the seccomp profile
    kubectl create configmap seccomp-profiles \
        --from-file="$PROFILE_SOURCE" \
        --namespace=kube-system \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Create DaemonSet to deploy the profile to all nodes
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: seccomp-profile-installer
  namespace: kube-system
  labels:
    app: seccomp-profile-installer
spec:
  selector:
    matchLabels:
      app: seccomp-profile-installer
  template:
    metadata:
      labels:
        app: seccomp-profile-installer
    spec:
      hostPID: true
      hostNetwork: true
      tolerations:
      - operator: Exists
      containers:
      - name: installer
        image: alpine:latest
        command:
        - /bin/sh
        - -c
        - |
          echo "Installing seccomp profile on node: \$(hostname)"
          mkdir -p /host/var/lib/kubelet/seccomp/profiles
          cp /profiles/${PROFILE_NAME} /host/var/lib/kubelet/seccomp/profiles/
          echo "Seccomp profile installed successfully"
          # Keep container running
          tail -f /dev/null
        volumeMounts:
        - name: host-var-lib-kubelet
          mountPath: /host/var/lib/kubelet
        - name: seccomp-profiles
          mountPath: /profiles
        securityContext:
          privileged: true
      volumes:
      - name: host-var-lib-kubelet
        hostPath:
          path: /var/lib/kubelet
          type: Directory
      - name: seccomp-profiles
        configMap:
          name: seccomp-profiles
      restartPolicy: Always
EOF

    echo "Waiting for DaemonSet to be ready..."
    kubectl rollout status daemonset/seccomp-profile-installer -n kube-system --timeout=300s
    
    echo "Seccomp profile deployed to all nodes!"
    echo ""
    echo "To verify installation, check the DaemonSet logs:"
    echo "kubectl logs -l app=seccomp-profile-installer -n kube-system"
    echo ""
    echo "To clean up the installer DaemonSet after verification:"
    echo "kubectl delete daemonset seccomp-profile-installer -n kube-system"
    echo "kubectl delete configmap seccomp-profiles -n kube-system"
}

# Function to deploy manually (if you have direct node access)
deploy_manual() {
    echo "Manual deployment instructions:"
    echo ""
    echo "1. Copy the profile to each node:"
    echo "   scp $PROFILE_SOURCE user@node:/tmp/"
    echo ""
    echo "2. On each node, run:"
    echo "   sudo mkdir -p /var/lib/kubelet/seccomp/profiles"
    echo "   sudo cp /tmp/${PROFILE_NAME} /var/lib/kubelet/seccomp/profiles/"
    echo "   sudo chmod 644 /var/lib/kubelet/seccomp/profiles/${PROFILE_NAME}"
    echo ""
    echo "3. Verify the profile is in place:"
    echo "   sudo ls -la /var/lib/kubelet/seccomp/profiles/"
}

# Check if kubectl is available and cluster is accessible
if kubectl cluster-info &> /dev/null; then
    echo "Kubernetes cluster detected. Deploying via DaemonSet..."
    deploy_via_daemonset
else
    echo "No Kubernetes cluster access detected."
    deploy_manual
fi

echo ""
echo "Seccomp profile deployment complete!"
echo "You can now deploy your application with the seccomp profile." 