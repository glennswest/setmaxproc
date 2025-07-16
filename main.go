package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	"k8s.io/klog/v2"
)

const (
	webhookPort = 8443
	certPath    = "/etc/certs/tls.crt"
	keyPath     = "/etc/certs/tls.key"
)

var (
	scheme = k8sruntime.NewScheme()
	codecs = serializer.NewCodecFactory(scheme)
)

type WebhookServer struct {
	server *http.Server
}

// patchOperation represents a JSON patch operation
type patchOperation struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

func main() {
	klog.InitFlags(nil)
	klog.Info("Starting GOMAXPROCS mutating webhook server...")

	certPath := envString("TLS_CERT_FILE", certPath)
	keyPath := envString("TLS_PRIVATE_KEY_FILE", keyPath)
	port := envInt("WEBHOOK_PORT", webhookPort)

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		klog.Fatalf("Failed to load key pair: %v", err)
	}

	webhookServer := &WebhookServer{
		server: &http.Server{
			Addr:      fmt.Sprintf(":%d", port),
			TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}},
		},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", webhookServer.mutate)
	mux.HandleFunc("/health", webhookServer.health)
	webhookServer.server.Handler = mux

	klog.Infof("Webhook server listening on port %d", port)
	if err := webhookServer.server.ListenAndServeTLS("", ""); err != nil {
		klog.Fatalf("Failed to start webhook server: %v", err)
	}
}

func (ws *WebhookServer) health(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

func (ws *WebhookServer) mutate(w http.ResponseWriter, r *http.Request) {
	klog.Info("Handling mutate request")

	body, err := io.ReadAll(r.Body)
	if err != nil {
		klog.Errorf("Failed to read request body: %v", err)
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	var review admissionv1.AdmissionReview
	if err := json.Unmarshal(body, &review); err != nil {
		klog.Errorf("Failed to unmarshal admission review: %v", err)
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	req := review.Request
	var pod corev1.Pod
	if err := json.Unmarshal(req.Object.Raw, &pod); err != nil {
		klog.Errorf("Failed to unmarshal pod object: %v", err)
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	klog.Infof("Processing pod: %s/%s", pod.Namespace, pod.Name)

	// Generate patches
	patches := mutateGOMAXPROCS(&pod)

	// Create admission response
	admissionResponse := &admissionv1.AdmissionResponse{
		UID:     req.UID,
		Allowed: true,
	}

	if len(patches) > 0 {
		patchBytes, err := json.Marshal(patches)
		if err != nil {
			klog.Errorf("Failed to marshal patches: %v", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		patchType := admissionv1.PatchTypeJSONPatch
		admissionResponse.Patch = patchBytes
		admissionResponse.PatchType = &patchType
		klog.Infof("Applied %d patches to pod %s/%s", len(patches), pod.Namespace, pod.Name)
	}

	review.Response = admissionResponse
	review.Request = nil

	respBytes, err := json.Marshal(review)
	if err != nil {
		klog.Errorf("Failed to marshal admission review response: %v", err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write(respBytes)
}

func mutateGOMAXPROCS(pod *corev1.Pod) []patchOperation {
	var patches []patchOperation

	// Skip if pod already has annotation to disable mutation
	if pod.Annotations != nil {
		if skip, exists := pod.Annotations["setmaxproc.webhook/skip"]; exists && skip == "true" {
			klog.Infof("Skipping pod %s/%s due to skip annotation", pod.Namespace, pod.Name)
			return patches
		}
	}

	for i, container := range pod.Spec.Containers {
		// Check if container is a Go application
		if !isGoContainer(container) {
			continue
		}

		// Check if GOMAXPROCS is already set
		if hasGOMAXPROCS(container) {
			klog.Infof("Container %s already has GOMAXPROCS set, skipping", container.Name)
			continue
		}

		// Calculate GOMAXPROCS value based on resource limits
		gomaxprocs := calculateGOMAXPROCS(container, pod)
		
		klog.Infof("Adding GOMAXPROCS=%s to container %s", gomaxprocs, container.Name)

		// Create patch to add GOMAXPROCS environment variable
		envPath := fmt.Sprintf("/spec/containers/%d/env", i)
		
		if container.Env == nil {
			// If no env vars exist, create the env array
			patches = append(patches, patchOperation{
				Op:   "add",
				Path: envPath,
				Value: []corev1.EnvVar{
					{
						Name:  "GOMAXPROCS",
						Value: gomaxprocs,
					},
				},
			})
		} else {
			// If env vars exist, append to the array
			patches = append(patches, patchOperation{
				Op:   "add",
				Path: fmt.Sprintf("%s/-", envPath),
				Value: corev1.EnvVar{
					Name:  "GOMAXPROCS",
					Value: gomaxprocs,
				},
			})
		}
	}

	return patches
}

func isGoContainer(container corev1.Container) bool {
	// Check if image suggests it's a Go application
	image := strings.ToLower(container.Image)
	
	// Common Go image patterns
	goPatterns := []string{
		"golang",
		"go:",
		"/go:",
		"scratch", // Many Go apps use scratch base image
	}
	
	for _, pattern := range goPatterns {
		if strings.Contains(image, pattern) {
			return true
		}
	}
	
	// Check if any environment variables suggest Go application
	for _, env := range container.Env {
		if strings.HasPrefix(env.Name, "GO") {
			return true
		}
	}
	
	// You can extend this logic based on your specific needs
	// For example, check for specific labels, annotations, or command patterns
	
	return false
}

func hasGOMAXPROCS(container corev1.Container) bool {
	for _, env := range container.Env {
		if env.Name == "GOMAXPROCS" {
			return true
		}
	}
	return false
}

func calculateGOMAXPROCS(container corev1.Container, pod *corev1.Pod) string {
	// Check for CPU limits
	if container.Resources.Limits != nil {
		if cpuLimit, exists := container.Resources.Limits[corev1.ResourceCPU]; exists {
			// Convert CPU limit to number of cores
			cpuValue := cpuLimit.AsApproximateFloat64()
			
			// Round up to nearest integer, but at least 1
			maxprocs := int(cpuValue)
			if cpuValue > float64(maxprocs) {
				maxprocs++
			}
			if maxprocs < 1 {
				maxprocs = 1
			}
			
			klog.Infof("Calculated GOMAXPROCS=%d based on CPU limit %.2f", maxprocs, cpuValue)
			return strconv.Itoa(maxprocs)
		}
	}
	
	// Check for CPU requests if no limits
	if container.Resources.Requests != nil {
		if cpuRequest, exists := container.Resources.Requests[corev1.ResourceCPU]; exists {
			cpuValue := cpuRequest.AsApproximateFloat64()
			
			maxprocs := int(cpuValue)
			if cpuValue > float64(maxprocs) {
				maxprocs++
			}
			if maxprocs < 1 {
				maxprocs = 1
			}
			
			klog.Infof("Calculated GOMAXPROCS=%d based on CPU request %.2f", maxprocs, cpuValue)
			return strconv.Itoa(maxprocs)
		}
	}
	
	// Calculate default value: maxsystemcpu / maxcontainers or 2, whichever is higher
	maxSystemCPU := runtime.NumCPU()
	maxContainers := len(pod.Spec.Containers)
	
	// Calculate maxsystemcpu / maxcontainers
	calculatedDefault := maxSystemCPU / maxContainers
	if calculatedDefault < 1 {
		calculatedDefault = 1
	}
	
	// Use the higher of calculatedDefault or 2
	defaultValue := calculatedDefault
	if defaultValue < 2 {
		defaultValue = 2
	}
	
	klog.Infof("No CPU limits/requests found, calculated default GOMAXPROCS=%d (system CPUs: %d, containers: %d)", 
		defaultValue, maxSystemCPU, maxContainers)
	return strconv.Itoa(defaultValue)
}

func envString(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func envInt(key string, defaultValue int) int {
	if value := os.Getenv(key); value != "" {
		if intValue, err := strconv.Atoi(value); err == nil {
			return intValue
		}
	}
	return defaultValue
} 