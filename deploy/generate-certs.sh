#!/bin/bash

set -e

NAMESPACE="setmaxproc-webhook"
SERVICE_NAME="setmaxproc-webhook"
SECRET_NAME="setmaxproc-webhook-certs"

# Create temporary directory for certificates
TMPDIR=$(mktemp -d)
cd $TMPDIR

echo "Generating TLS certificates for webhook..."

# Generate CA private key
openssl genrsa -out ca.key 2048

# Generate CA certificate
openssl req -new -x509 -days 365 -key ca.key \
    -subj "/C=US/ST=CA/L=San Francisco/O=Example/OU=IT Department/CN=setmaxproc-webhook-ca" \
    -out ca.crt

# Generate server private key
openssl genrsa -out server.key 2048

# Create certificate signing request config
cat > csr.conf <<EOF
[req]
default_bits = 2048
prompt = no
distinguished_name = dn
req_extensions = v3_req

[dn]
C=US
ST=CA
L=San Francisco
O=Example
OU=IT Department
CN=${SERVICE_NAME}.${NAMESPACE}.svc

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${SERVICE_NAME}
DNS.2 = ${SERVICE_NAME}.${NAMESPACE}
DNS.3 = ${SERVICE_NAME}.${NAMESPACE}.svc
DNS.4 = ${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local
EOF

# Generate certificate signing request
openssl req -new -key server.key -out server.csr -config csr.conf

# Generate server certificate signed by CA
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -days 365 -extensions v3_req -extfile csr.conf

echo "Creating Kubernetes secret with certificates..."

# Create namespace if it doesn't exist
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Create the secret
kubectl create secret tls $SECRET_NAME \
    --cert=server.crt \
    --key=server.key \
    --namespace=$NAMESPACE \
    --dry-run=client -o yaml | kubectl apply -f -

# Get the CA bundle in base64 format
CA_BUNDLE=$(cat ca.crt | base64 | tr -d '\n')

echo "Patching webhook configuration with CA bundle..."

# Update the webhook configuration with the correct CA bundle
kubectl patch mutatingadmissionwebhook setmaxproc-webhook \
    --type='json' \
    -p="[{'op': 'replace', 'path': '/webhooks/0/clientConfig/caBundle', 'value': '$CA_BUNDLE'}]"

echo "Certificate generation and configuration complete!"
echo "CA Bundle: $CA_BUNDLE"

# Cleanup
cd - > /dev/null
rm -rf $TMPDIR

echo "Certificates have been generated and applied to the cluster." 