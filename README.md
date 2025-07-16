# GOMAXPROCS Mutating Webhook for Kubernetes/OpenShift

A Kubernetes mutating admission webhook that automatically sets the `GOMAXPROCS` environment variable for Go applications based on their CPU resource limits or requests.

## Overview

This webhook helps optimize Go applications running in containers by automatically setting appropriate `GOMAXPROCS` values. It prevents Go applications from creating too many OS threads when they don't have access to all the host's CPUs, which can lead to poor performance and increased context switching.

## Features

- **Automatic Detection**: Identifies Go applications based on container images and environment variables
- **Smart Calculation**: Sets `GOMAXPROCS` based on CPU limits/requests
- **Configurable**: Skip webhook for specific pods using annotations
- **Secure**: Uses TLS certificates for secure communication
- **OpenShift Compatible**: Works with both Kubernetes and OpenShift clusters

## How It Works

1. The webhook intercepts pod creation/update requests
2. Identifies containers that appear to be Go applications
3. Calculates appropriate `GOMAXPROCS` value based on CPU resources:
   - Uses CPU limits if available
   - Falls back to CPU requests if no limits are set
   - For containers without resource constraints: uses `max(system_cpus / max_pods, 2)` where max_pods = 250
   - Rounds fractional CPU values up to the nearest integer
   - Minimum value is 1
4. Adds the `GOMAXPROCS` environment variable to the container

### Go Application Detection

The webhook identifies Go applications by checking:
- Container image name contains: `golang`, `go:`, `/go:`, or `scratch`
- Existing environment variables starting with `GO`

### GOMAXPROCS Calculation

| CPU Resource | GOMAXPROCS Value |
|-------------|------------------|
| 0.5 CPU     | 1               |
| 1.0 CPU     | 1               |
| 1.5 CPU     | 2               |
| 2.0 CPU     | 2               |
| 2.5 CPU     | 3               |
| No limits (512 CPU node) | 2 (512/250 = 2.048, rounded down) |
| No limits (1000 CPU node) | 4 (1000/250 = 4) |
| No limits (500 CPU node) | 2 (500/250 = 2) |
| No limits (100 CPU node) | 2 (100/250 = 0.4, minimum is 2) |

### Default Calculation Logic

For containers without CPU limits or requests, the webhook uses an intelligent default:

```
GOMAXPROCS = max(system_cpu_count / max_pods_per_node, 2)
```

Where `max_pods_per_node = 250` (typical Kubernetes node limit).

This approach:
- **Conservative resource allocation**: Assumes maximum pod density to prevent over-allocation
- **Ensures minimum performance**: Guarantees at least 2 processes for reasonable concurrency
- **Node-aware scaling**: Considers the realistic maximum workload per node
- **Prevents resource exhaustion**: Avoids setting excessively high GOMAXPROCS on large systems

## Installation

### Prerequisites

- Kubernetes 1.16+ or OpenShift 4.x
- Docker
- kubectl or oc CLI
- openssl (for certificate generation)

### Quick Deployment

1. **Clone the repository:**
   ```bash
   git clone <repository-url>
   cd setmaxproc
   ```

2. **Build and deploy:**
   ```bash
   ./deploy/deploy.sh
   ```

This script will:
- Build the Docker image
- Deploy all Kubernetes manifests
- Generate TLS certificates
- Configure the mutating webhook

### Manual Deployment

1. **Build the Docker image:**
   ```bash
   docker build -t setmaxproc-webhook:latest .
   ```

2. **Apply Kubernetes manifests:**
   ```bash
   kubectl apply -f deploy/00-namespace.yaml
   kubectl apply -f deploy/01-rbac.yaml
   kubectl apply -f deploy/02-deployment.yaml
   kubectl apply -f deploy/03-service.yaml
   kubectl apply -f deploy/04-webhook-config.yaml
   ```

3. **Generate certificates:**
   ```bash
   ./deploy/generate-certs.sh
   ```

## Usage

### Basic Usage

Once deployed, the webhook will automatically process new pods. No additional configuration is required.

### Skip Webhook for Specific Pods

Add this annotation to skip the webhook:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
  annotations:
    setmaxproc.webhook/skip: "true"
spec:
  # ... pod spec
```

### Example Manifests

See the `examples/` directory for sample pod manifests:

- `go-app-with-limits.yaml` - Go app with CPU limits
- `go-app-high-cpu.yaml` - Go app with higher CPU allocation
- `go-app-no-limits.yaml` - Go app without resource constraints (demonstrates default calculation)
- `go-app-multi-container.yaml` - Multi-container pod (shows consistent GOMAXPROCS across containers)
- `go-app-skip-webhook.yaml` - Go app that skips webhook processing

### Testing

1. **Deploy a test Go application:**
   ```bash
   kubectl apply -f examples/go-app-with-limits.yaml
   ```

2. **Check the injected environment variable:**
   ```bash
   kubectl get pod go-app-with-limits -o jsonpath='{.spec.containers[0].env[?(@.name=="GOMAXPROCS")].value}'
   ```

3. **View webhook logs:**
   ```bash
   kubectl logs -l app=setmaxproc-webhook -n setmaxproc-webhook
   ```

## Configuration

### Environment Variables

The webhook supports these environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `TLS_CERT_FILE` | `/etc/certs/tls.crt` | Path to TLS certificate |
| `TLS_PRIVATE_KEY_FILE` | `/etc/certs/tls.key` | Path to TLS private key |
| `WEBHOOK_PORT` | `8443` | Port for webhook server |

### Webhook Configuration

The webhook is configured to:
- Process pods in all namespaces except `kube-system`, `kube-public`, and `setmaxproc-webhook`
- Only process pods without the `setmaxproc.webhook/skip` annotation
- Fail if the webhook is unavailable (failurePolicy: Fail)

## Monitoring

### Health Check

The webhook provides a health endpoint at `/health` for liveness and readiness probes.

### Logs

Check webhook logs for processing information:
```bash
kubectl logs -f deployment/setmaxproc-webhook -n setmaxproc-webhook
```

### Metrics

The webhook logs information about:
- Pods processed
- GOMAXPROCS values calculated
- Containers skipped
- Errors encountered

## Security

### TLS Configuration

- Uses TLS 1.2+ for all communications
- Certificates are automatically generated with proper SANs
- Private keys are stored in Kubernetes secrets

### RBAC

The webhook uses minimal RBAC permissions:
- Read access to pods
- Manage mutating admission webhooks

### Pod Security

The webhook pod runs with:
- Non-root user (UID 1000)
- Read-only root filesystem
- Dropped capabilities
- No privilege escalation

## Troubleshooting

### Common Issues

1. **Webhook not processing pods:**
   - Check webhook configuration: `kubectl get mutatingadmissionwebhook setmaxproc-webhook`
   - Verify CA bundle is correct
   - Check webhook pod logs

2. **Certificate errors:**
   - Regenerate certificates: `./deploy/generate-certs.sh`
   - Verify secret exists: `kubectl get secret setmaxproc-webhook-certs -n setmaxproc-webhook`

3. **GOMAXPROCS not set:**
   - Verify the container image matches Go detection patterns
   - Check if pod has skip annotation
   - Verify CPU resources are defined

### Debugging

1. **Enable verbose logging:**
   ```bash
   kubectl set env deployment/setmaxproc-webhook -n setmaxproc-webhook KLOG_V=2
   ```

2. **Test webhook directly:**
   ```bash
   kubectl port-forward -n setmaxproc-webhook svc/setmaxproc-webhook 8443:443
   curl -k https://localhost:8443/health
   ```

## Uninstallation

```bash
kubectl delete mutatingadmissionwebhook setmaxproc-webhook
kubectl delete namespace setmaxproc-webhook
```

## Development

### Building

```bash
go mod tidy
go build -o webhook .
```

### Testing

```bash
go test ./...
```

### Local Development

For local development, you can run the webhook outside the cluster:

1. Generate certificates for localhost
2. Update webhook configuration to point to your local endpoint
3. Run: `./webhook`

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## References

- [Kubernetes Admission Controllers](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
- [Go GOMAXPROCS Documentation](https://pkg.go.dev/runtime#GOMAXPROCS)
- [OpenShift Admission Webhooks](https://docs.openshift.com/container-platform/latest/architecture/admission-plug-ins.html) 