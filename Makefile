.PHONY: build deploy test clean docker-build docker-push help

# Variables
IMAGE_NAME ?= setmaxproc-webhook
IMAGE_TAG ?= latest
NAMESPACE ?= setmaxproc-webhook

help: ## Show this help message
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the Go binary
	CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o webhook .

test: ## Run tests
	go test ./...

mod-tidy: ## Tidy Go modules
	go mod tidy

docker-build: ## Build Docker image
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

docker-push: docker-build ## Build and push Docker image
	docker push $(IMAGE_NAME):$(IMAGE_TAG)

deploy: ## Deploy the webhook to Kubernetes/OpenShift
	./deploy/deploy.sh

deploy-manifests: ## Apply Kubernetes manifests only
	kubectl apply -f deploy/00-namespace.yaml
	kubectl apply -f deploy/01-rbac.yaml
	kubectl apply -f deploy/02-deployment.yaml
	kubectl apply -f deploy/03-service.yaml
	kubectl apply -f deploy/04-webhook-config.yaml

generate-certs: ## Generate TLS certificates
	./deploy/generate-certs.sh

test-examples: ## Deploy test examples
	kubectl apply -f examples/

logs: ## Show webhook logs
	kubectl logs -f deployment/$(IMAGE_NAME) -n $(NAMESPACE)

status: ## Show webhook status
	kubectl get all -n $(NAMESPACE)
	kubectl get mutatingadmissionwebhook $(IMAGE_NAME)

clean: ## Clean up deployment
	kubectl delete mutatingadmissionwebhook $(IMAGE_NAME) --ignore-not-found
	kubectl delete namespace $(NAMESPACE) --ignore-not-found

clean-examples: ## Clean up test examples
	kubectl delete -f examples/ --ignore-not-found

verify: ## Verify the webhook is working
	@echo "Checking webhook configuration..."
	kubectl get mutatingadmissionwebhook $(IMAGE_NAME) -o jsonpath='{.webhooks[0].clientConfig.service.name}'
	@echo ""
	@echo "Checking webhook pods..."
	kubectl get pods -n $(NAMESPACE) -l app=$(IMAGE_NAME)

dev-setup: mod-tidy build ## Setup for development
	@echo "Development setup complete"

all: mod-tidy test docker-build deploy ## Build, test, and deploy everything 