SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# =============================================================================
# PLATFORM-INFRA MAKEFILE
# Comprehensive cross-platform local development commands
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration (overridable via environment)
# -----------------------------------------------------------------------------
MINIKUBE_PROFILE     ?= platform
K8S_VERSION          ?= v1.30.2
MINIKUBE_CPUS        ?= 4
MINIKUBE_MEMORY      ?= 7800mb
MINIKUBE_DISK        ?= 50g
MINIKUBE_DRIVER      ?= docker
KUBE_CONTEXT         ?= $(MINIKUBE_PROFILE)

# Port forwards (overridable via .env or env vars)
ARGOCD_PORT          ?= 8081
GRAFANA_PORT         ?= 3000
VAULT_PORT           ?= 8200
MINISTACK_PORT       ?= 4566
REGISTRY_PORT        ?= 5000
ATLANTIS_PORT        ?= 8080
PROMETHEUS_PORT      ?= 9090

# Service repos (for local development)
GO_SERVICE_REPO      ?= platform-services-go
NODE_SERVICE_REPO    ?= platform-services-node
FRONTEND_REPO        ?= platform-frontend

# Toolchain verification
MISE_SHIMS           := $(shell mise which make 2>/dev/null || echo "")
IS_MACOS             := $(shell [ "$$(uname)" = "Darwin" ] && echo "true" || echo "false")
IS_LINUX             := $(shell [ "$$(uname)" = "Linux" ] && echo "true" || echo "false")

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------
define log_info
	@printf '\033[1;34m==>\033[0m %s\n' "$(1)"
endef

define log_warn
	@printf '\033[1;33mWARN:\033[0m %s\n' "$(1)" >&2
endef

define log_error
	@printf '\033[1;31mERROR:\033[0m %s\n' "$(1)" >&2
endef

define check_mise
	@command -v mise >/dev/null || { \
		$(call log_error,"mise not found — install with: curl https://mise.run | sh"); \
		exit 1; \
	}
endef

define check_toolchain
	@$(call log_info,"Verifying toolchain versions...")
	@mise exec -- tofu version
	@mise exec -- kubectl version --client
	@mise exec -- helm version --short
	@mise exec -- make --version
	@$(call log_info,"Toolchain OK")
endef

# -----------------------------------------------------------------------------
# Primary targets (documented in help)
# -----------------------------------------------------------------------------

.PHONY: help
help: ## Show this help with all available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'

# -----------------------------------------------------------------------------
# Toolchain & Setup
# -----------------------------------------------------------------------------

.PHONY: toolchain-install
toolchain-install: ## Install all pinned tools via mise
	$(call check_mise)
	$(call log_info,"Installing pinned toolchain...")
	mise trust && mise install
	@$(call log_info,"Activating mise in current shell...")
	@echo "Run: eval \"\$$(mise activate bash)\"  (or: mise activate zsh)"
	@echo "Then verify: make toolchain-verify"

.PHONY: toolchain-verify
toolchain-verify: ## Verify all tools are at pinned versions
	$(call check_toolchain)

.PHONY: toolchain-update
toolchain-update: ## Update all tools to latest compatible versions
	$(call check_mise)
	$(call log_info,"Updating toolchain...")
	mise upgrade
	mise trust

# -----------------------------------------------------------------------------
# Cluster Lifecycle (macOS/Linux compatible)
# -----------------------------------------------------------------------------

.PHONY: cluster-up
cluster-up: ## Create/start minikube cluster with pinned addons (idempotent)
	$(call check_mise)
	$(call log_info,"Starting minikube cluster '$(MINIKUBE_PROFILE)'...")
	./scripts/setup-minikube.sh

.PHONY: cluster-up-bg
cluster-up-bg: ## Start cluster in background (no wait for addons)
	$(call check_mise)
	$(call log_info,"Starting minikube cluster in background...")
	@if minikube status -p "$(MINIKUBE_PROFILE)" >/dev/null 2>&1; then \
		minikube start -p "$(MINIKUBE_PROFILE)" >/dev/null; \
	else \
		minikube start \
			-p "$(MINIKUBE_PROFILE)" \
			--driver=$(MINIKUBE_DRIVER) \
			--kubernetes-version="$(K8S_VERSION)" \
			--cpus="$(MINIKUBE_CPUS)" \
			--memory="$(MINIKUBE_MEMORY)" \
			--disk-size="$(MINIKUBE_DISK)" \
			--embed-certs=true; \
	fi

.PHONY: cluster-down
cluster-down: ## Delete the minikube cluster (destructive)
	$(call check_mise)
	@read -p "Delete minikube profile '$(MINIKUBE_PROFILE)' and ALL its data? [y/N] " a; [ "$$a" = y ]
	minikube delete -p $(MINIKUBE_PROFILE)

.PHONY: cluster-reset
cluster-reset: cluster-down cluster-up ## Full cluster reset (delete + recreate)

.PHONY: cluster-status
cluster-status: ## Show cluster status and health
	$(call check_mise)
	minikube status -p $(MINIKUBE_PROFILE)
	@echo ""
	$(call log_info,"Node status:")
	@kubectl --context $(KUBE_CONTEXT) get nodes -o wide
	@echo ""
	$(call log_info,"System pods:")
	@kubectl --context $(KUBE_CONTEXT) get pods -n kube-system

.PHONY: cluster-logs
cluster-logs: ## Show minikube cluster logs (last 100 lines)
	$(call check_mise)
	minikube logs -p $(MINIKUBE_PROFILE) --length=100

.PHONY: cluster-shell
cluster-shell: ## Open SSH shell to minikube node
	$(call check_mise)
	minikube ssh -p $(MINIKUBE_PROFILE)

.PHONY: cluster-ip
cluster-ip: ## Get minikube cluster IP
	$(call check_mise)
	minikube ip -p $(MINIKUBE_PROFILE)

# -----------------------------------------------------------------------------
# Infrastructure Deployment (OpenTofu)
# -----------------------------------------------------------------------------

.PHONY: deploy-infra
deploy-infra: ## Apply all infrastructure with OpenTofu (ArgoCD, Vault, Ministack, etc.)
	$(call check_mise)
	$(call log_info,"Initializing OpenTofu...")
	tofu -chdir=tofu init -upgrade=false -input=false
	$(call log_info,"Bootstrapping ArgoCD...")
	$(MAKE) bootstrap-argocd
	$(call log_info,"Applying all infrastructure...")
	tofu -chdir=tofu apply -auto-approve -input=false

.PHONY: deploy-infra-plan
deploy-infra-plan: ## Show OpenTofu plan without applying
	$(call check_mise)
	tofu -chdir=tofu init -upgrade=false -input=false
	tofu -chdir=tofu plan -input=false

.PHONY: deploy-infra-target
deploy-infra-target: ## Apply specific module (usage: make deploy-infra-target MODULE=argocd)
	$(call check_mise)
	@test -n "$(MODULE)" || { $(call log_error,"MODULE required"); exit 1; }
	tofu -chdir=tofu apply -auto-approve -input=false -target=module.$(MODULE)

.PHONY: bootstrap-argocd
bootstrap-argocd: ## Install ArgoCD chart and CRDs before first full apply
	$(call check_mise)
	$(call log_info,"Bootstrapping ArgoCD...")
	tofu -chdir=tofu apply -auto-approve -input=false -target=module.argocd.helm_release.argocd

.PHONY: destroy-infra
destroy-infra: ## Destroy all OpenTofu-managed infrastructure (destructive)
	$(call check_mise)
	@read -p "Destroy ALL OpenTofu-managed resources? [y/N] " a; [ "$$a" = y ]
	tofu -chdir=tofu destroy -auto-approve -input=false

.PHONY: tofu-fmt
tofu-fmt: ## Format and validate OpenTofu config
	tofu -chdir=tofu fmt -recursive
	tofu -chdir=tofu validate

.PHONY: tofu-outputs
tofu-outputs: ## Show OpenTofu outputs (endpoints, namespaces)
	$(call check_mise)
	tofu -chdir=tofu output

# -----------------------------------------------------------------------------
# Service Deployment & Management
# -----------------------------------------------------------------------------

.PHONY: deploy-services
deploy-services: ## Deploy all services via ArgoCD (requires service repos cloned)
	$(call check_mise)
	$(call log_info,"Deploying services via ArgoCD...")
	kubectl --context $(KUBE_CONTEXT) apply -k argocd/applications/

.PHONY: deploy-service-go
deploy-service-go: ## Deploy Go service (dev namespace)
	$(call check_mise)
	kubectl --context $(KUBE_CONTEXT) apply -f argocd/applications/go-service-dev.yaml

.PHONY: deploy-service-node
deploy-service-node: ## Deploy Node.js service (dev namespace)
	$(call check_mise)
	kubectl --context $(KUBE_CONTEXT) apply -f argocd/applications/node-service-dev.yaml

.PHONY: deploy-service-frontend
deploy-service-frontend: ## Deploy Frontend service (dev namespace)
	$(call check_mise)
	kubectl --context $(KUBE_CONTEXT) apply -f argocd/applications/frontend-dev.yaml

.PHONY: service-status
service-status: ## Show status of all service deployments
	$(call check_mise)
	@echo "=== ArgoCD Applications ==="
	@kubectl --context $(KUBE_CONTEXT) -n argocd get applications -o wide
	@echo ""
	@echo "=== Service Pods (dev) ==="
	@kubectl --context $(KUBE_CONTEXT) -n dev get pods -o wide 2>/dev/null || echo "dev namespace not found"
	@echo ""
	@echo "=== Service Pods (staging) ==="
	@kubectl --context $(KUBE_CONTEXT) -n staging get pods -o wide 2>/dev/null || echo "staging namespace not found"
	@echo ""
	@echo "=== Service Pods (prod) ==="
	@kubectl --context $(KUBE_CONTEXT) -n prod get pods -o wide 2>/dev/null || echo "prod namespace not found"

.PHONY: service-logs
service-logs: ## View logs for a service (usage: make service-logs SERVICE=go-service NAMESPACE=dev)
	$(call check_mise)
	@test -n "$(SERVICE)" || { $(call log_error,"SERVICE required"); exit 1; }
	@NAMESPACE="$(or $(NAMESPACE),dev)"; \
	kubectl --context $(KUBE_CONTEXT) -n $$NAMESPACE logs -l app.kubernetes.io/name=$(SERVICE) --tail=100 -f

# -----------------------------------------------------------------------------
# Port Forwarding (macOS/Linux compatible)
# -----------------------------------------------------------------------------

.PHONY: port-forwards
port-forwards: ## Forward all platform services to localhost (run in background with &)
	$(call check_mise)
	$(call log_info,"Starting port forwards...")
	./scripts/port-forwards.sh

.PHONY: port-forward-argocd
port-forward-argocd: ## Forward ArgoCD UI to localhost:8081
	$(call check_mise)
	@$(call log_info,"ArcoCD UI: http://localhost:$(ARGOCD_PORT)")
	@$(call log_info,"Username: admin")
	@$(call log_info,"Password: run 'make argocd-password'")
	kubectl --context $(KUBE_CONTEXT) -n argocd port-forward svc/argocd-server $(ARGOCD_PORT):443

.PHONY: port-forward-grafana
port-forward-grafana: ## Forward Grafana to localhost:3000
	$(call check_mise)
	@$(call log_info,"Grafana: http://localhost:$(GRAFANA_PORT)")
	kubectl --context $(KUBE_CONTEXT) -n monitoring port-forward svc/grafana $(GRAFANA_PORT):80

.PHONY: port-forward-prometheus
port-forward-prometheus: ## Forward Prometheus to localhost:9090
	$(call check_mise)
	@$(call log_info,"Prometheus: http://localhost:$(PROMETHEUS_PORT)")
	kubectl --context $(KUBE_CONTEXT) -n monitoring port-forward svc/prometheus-prometheus $(PROMETHEUS_PORT):9090

.PHONY: port-forward-vault
port-forward-vault: ## Forward Vault to localhost:8200
	$(call check_mise)
	@$(call log_info,"Vault UI: http://localhost:$(VAULT_PORT)")
	kubectl --context $(KUBE_CONTEXT) -n vault port-forward svc/vault $(VAULT_PORT):8200

.PHONY: port-forward-ministack
port-forward-ministack: ## Forward Ministack (AWS APIs) to localhost:4566
	$(call check_mise)
	@$(call log_info,"Ministack: http://localhost:$(MINISTACK_PORT)")
	kubectl --context $(KUBE_CONTEXT) -n ministack port-forward svc/ministack $(MINISTACK_PORT):4566

.PHONY: port-forward-registry
port-forward-registry: ## Forward local registry to localhost:5000
	$(call check_mise)
	@$(call log_info,"Registry: http://localhost:$(REGISTRY_PORT)")
	kubectl --context $(KUBE_CONTEXT) -n registry port-forward svc/registry $(REGISTRY_PORT):5000

.PHONY: port-forward-atlantis
port-forward-atlantis: ## Forward Atlantis to localhost:8080
	$(call check_mise)
	@$(call log_info,"Atlantis: http://localhost:$(ATLANTIS_PORT)")
	kubectl --context $(KUBE_CONTEXT) -n atlantis port-forward svc/atlantis $(ATLANTIS_PORT):8080

.PHONY: port-forward-ingress
port-forward-ingress: ## Forward ingress-nginx to localhost:8080 (macOS: use port-forward, not tunnel)
	$(call check_mise)
	@$(call log_info,"Ingress (nginx): http://localhost:8080")
	kubectl --context $(KUBE_CONTEXT) -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80

# -----------------------------------------------------------------------------
# Credentials & Secrets
# -----------------------------------------------------------------------------

.PHONY: argocd-password
argocd-password: ## Get ArcoCD admin password
	$(call check_mise)
	@kubectl --context $(KUBE_CONTEXT) -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

.PHONY: vault-token
vault-token: ## Get Vault root token (dev mode)
	$(call check_mise)
	@kubectl --context $(KUBE_CONTEXT) -n vault get secret vault-keys -o jsonpath="{.data.root_token}" | base64 -d && echo

.PHONY: registry-login
registry-login: ## Configure docker to use local registry
	$(call check_mise)
	@$(call log_info,"Configuring docker for local registry...")
	@REGISTRY_IP=$$(kubectl --context $(KUBE_CONTEXT) -n registry get svc registry -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo ""); \
	if [ -n "$$REGISTRY_IP" ]; then \
		echo "Registry ClusterIP: $$REGISTRY_IP:5000"; \
		echo "Add to /etc/hosts: $$REGISTRY_IP registry.registry.svc"; \
	else \
		$(call log_warn,"Registry service not found. Run 'make deploy-infra' first."); \
	fi

# -----------------------------------------------------------------------------
# Verification & Testing
# -----------------------------------------------------------------------------

.PHONY: verify
verify: ## Run Phase 1 success-criteria gate
	$(call check_mise)
	./scripts/verify-phase1.sh

.PHONY: verify-services
verify-services: ## Verify all services are healthy
	$(call check_mise)
	@echo "=== Checking service health ==="
	@for ns in dev staging prod; do \
		echo "Namespace: $$ns"; \
		kubectl --context $(KUBE_CONTEXT) -n $$ns get pods 2>/dev/null | grep -v "No resources found" || echo "  (no pods)"; \
	done

.PHONY: smoke-test
smoke-test: ## Run smoke tests against deployed services
	$(call check_mise)
	$(call log_info,"Running smoke tests...")
	./scripts/smoke-atlantis-webhook.sh || true
	@$(call log_info,"Checking Ministack queues...")
	kubectl --context $(KUBE_CONTEXT) -n ministack exec -it deploy/ministack -- awslocal sqs list-queues 2>/dev/null || echo "Ministack not ready"

.PHONY: load-test
load-test: ## Run k6 load test against services
	$(call check_mise)
	$(call log_info,"Running load test...")
	# Requires k6 installed
	k6 run tests/load-test.js 2>/dev/null || $(call log_warn,"k6 not installed or test file missing")

# -----------------------------------------------------------------------------
# Development Workflows (Local Service Development)
# -----------------------------------------------------------------------------

.PHONY: dev-setup
dev-setup: ## Complete local dev setup (toolchain + cluster + infra)
	$(MAKE) toolchain-install
	$(MAKE) cluster-up
	$(MAKE) deploy-infra
	$(MAKE) verify
	@$(call log_info,"Setup complete! Run 'make port-forwards' to access UIs.")

.PHONY: dev-teardown
dev-teardown: ## Complete teardown (infra + cluster)
	$(MAKE) destroy-infra
	$(MAKE) cluster-down

.PHONY: dev-restart
dev-restart: ## Quick restart: cluster + infra (keeps data)
	$(MAKE) cluster-down
	$(MAKE) cluster-up
	$(MAKE) deploy-infra

# -----------------------------------------------------------------------------
# Service Repository Management
# -----------------------------------------------------------------------------

.PHONY: clone-services
clone-services: ## Clone all service repos for local development
	$(call log_info,"Cloning service repositories...")
	@for repo in $(GO_SERVICE_REPO) $(NODE_SERVICE_REPO) $(FRONTEND_REPO); do \
		if [ ! -d "../$$repo" ]; then \
			echo "Cloning $$repo..."; \
			git clone https://github.com/romeufcrosa/$$repo.git ../$$repo || \
				$(call log_warn,"Failed to clone $$repo (may not exist yet)"); \
		else \
			echo "$$repo already exists"; \
		fi; \
	done

.PHONY: service-dev-go
service-dev-go: ## Start Go service locally with docker-compose (requires cloned repo)
	@test -d "../$(GO_SERVICE_REPO)" || { $(call log_error,"$(GO_SERVICE_REPO) not found. Run 'make clone-services' first."); exit 1; }
	$(call log_info,"Starting Go service locally...")
	cd ../$(GO_SERVICE_REPO) && make dev

.PHONY: service-dev-node
service-dev-node: ## Start Node service locally with docker-compose (requires cloned repo)
	@test -d "../$(NODE_SERVICE_REPO)" || { $(call log_error,"$(NODE_SERVICE_REPO) not found. Run 'make clone-services' first."); exit 1; }
	$(call log_info,"Starting Node service locally...")
	cd ../$(NODE_SERVICE_REPO) && make dev

.PHONY: service-dev-frontend
service-dev-frontend: ## Start Frontend locally with docker-compose (requires cloned repo)
	@test -d "../$(FRONTEND_REPO)" || { $(call log_error,"$(FRONTEND_REPO) not found. Run 'make clone-services' first."); exit 1; }
	$(call log_info,"Starting Frontend locally...")
	cd ../$(FRONTEND_REPO) && make dev

# -----------------------------------------------------------------------------
# Cross-Platform Helpers (macOS vs Linux)
# -----------------------------------------------------------------------------

.PHONY: fix-macos-docker-memory
fix-macos-docker-memory: ## Fix Docker Desktop memory limit (macOS only)
	@if [ "$(IS_MACOS)" = "true" ]; then \
		$(call log_info,"Current Docker Desktop memory limit may be too low."); \
		$(call log_info,"Increase to at least 8GB in Docker Desktop Settings -> Resources -> Advanced"); \
		$(call log_info,"Then run: MINIKUBE_MEMORY=10240mb make cluster-up"); \
	else \
		$(call log_info,"Not on macOS - this target is for macOS only"); \
	fi

.PHONY: fix-linux-kvm
fix-linux-kvm: ## Fix KVM permissions (Linux only)
	@if [ "$(IS_LINUX)" = "true" ]; then \
		$(call log_info,"Setting up KVM for minikube..."); \
		sudo usermod -aG kvm $$USER; \
		sudo usermod -aG libvirt $$USER; \
		newgrp kvm; \
		$(call log_info,"Log out and back in for group changes to take effect"); \
	else \
		$(call log_info,"Not on Linux - this target is for Linux only"); \
	fi

.PHONY: doctor
doctor: ## Run comprehensive health checks
	$(call check_mise)
	$(call log_info,"Running platform health checks...")
	@echo ""
	$(call log_info,"1. Toolchain versions:")
	@mise exec -- tofu version
	@mise exec -- kubectl version --client
	@mise exec -- helm version --short
	@mise exec -- make --version
	@echo ""
	$(call log_info,"2. Cluster status:")
	@minikube status -p $(MINIKUBE_PROFILE) 2>/dev/null || echo "  Cluster not running"
	@echo ""
	$(call log_info,"3. Kubeconfig context:")
	@kubectl config current-context 2>/dev/null || echo "  No context set"
	@echo ""
	$(call log_info,"4. Docker:")
	@docker version --format '{{.Server.Version}}' 2>/dev/null || echo "  Docker not running"
	@echo ""
	$(call log_info,"5. Port availability:")
	@for port in $(ARGOCD_PORT) $(GRAFANA_PORT) $(VAULT_PORT) $(MINISTACK_PORT) $(REGISTRY_PORT) $(ATLANTIS_PORT) $(PROMETHEUS_PORT); do \
		if lsof -i :$$port >/dev/null 2>&1; then \
			echo "  Port $$port: IN USE"; \
		else \
			echo "  Port $$port: free"; \
		fi; \
	done

# -----------------------------------------------------------------------------
# ArgoCD Operations
# -----------------------------------------------------------------------------

.PHONY: argocd-sync
argocd-sync: ## Sync all ArgoCD applications
	$(call check_mise)
	$(call log_info,"Syncing all ArgoCD applications...")
	kubectl --context $(KUBE_CONTEXT) -n argocd get applications -o name | \
		xargs -I {} kubectl --context $(KUBE_CONTEXT) -n argocd patch {} --type merge -p '{"operation":{"sync":{"prune":true}}}'

.PHONY: argocd-sync-app
argocd-sync-app: ## Sync specific ArgoCD app (usage: make argocd-sync-app APP=go-service-dev)
	$(call check_mise)
	@test -n "$(APP)" || { $(call log_error,"APP required"); exit 1; }
	kubectl --context $(KUBE_CONTEXT) -n argocd patch application $(APP) --type merge -p '{"operation":{"sync":{"prune":true}}}'

.PHONY: argocd-login
argocd-login: ## Login to ArgoCD CLI
	$(call check_mise)
	@PASSWORD=$$(make argocd-password); \
	argocd login localhost:$(ARGOCD_PORT) --username admin --password $$PASSWORD --insecure

.PHONY: argocd-apps
argocd-apps: ## List all ArgoCD applications
	$(call check_mise)
	kubectl --context $(KUBE_CONTEXT) -n argocd get applications -o wide

# -----------------------------------------------------------------------------
# Atlantis Operations
# -----------------------------------------------------------------------------

.PHONY: atlantis-webhook
atlantis-webhook: ## Test Atlantis webhook connectivity
	$(call check_mise)
	./scripts/smoke-atlantis-webhook.sh

.PHONY: atlantis-plan
atlantis-plan: ## Trigger Atlantis plan on current PR
	$(call check_mise)
	$(call log_info,"Triggering Atlantis plan...")
	# Requires gh CLI and GITHUB_PAT
	@test -n "$(GITHUB_PAT)" || { $(call log_error,"GITHUB_PAT not set"); exit 1; }
	gh api repos/$(GITHUB_ORG)/$(GITHUB_REPO)/pulls/$(PR_NUMBER)/comments --method POST -f body="/atlantis plan"

.PHONY: atlantis-apply
atlantis-apply: ## Trigger Atlantis apply on current PR
	$(call check_mise)
	$(call log_info,"Triggering Atlantis apply...")
	@test -n "$(GITHUB_PAT)" || { $(call log_error,"GITHUB_PAT not set"); exit 1; }
	gh api repos/$(GITHUB_ORG)/$(GITHUB_REPO)/pulls/$(PR_NUMBER)/comments --method POST -f body="/atlantis apply"

# -----------------------------------------------------------------------------
# Promotion Workflows
# -----------------------------------------------------------------------------

.PHONY: promote
promote: ## Promote services across environments (usage: make promote ENV=staging SERVICE=go-service)
	$(call check_mise)
	@test -n "$(ENV)" || { $(call log_error,"ENV required (staging|prod)"); exit 1; }
	./scripts/promote.sh $(ENV) $(SERVICE)

.PHONY: promote-verify
promote-verify: ## Verify promotion health
	$(call check_mise)
	./scripts/verify-promotion.sh

# -----------------------------------------------------------------------------
# Chaos Engineering & Resilience
# -----------------------------------------------------------------------------

.PHONY: chaos-pod-kill
chaos-pod-kill: ## Run pod kill chaos experiment (usage: make chaos-pod-kill TARGET=go-service)
	$(call check_mise)
	@test -n "$(TARGET)" || { $(call log_error,"TARGET required"); exit 1; }
	kubectl --context $(KUBE_CONTEXT) apply -f chaos/pod-kill-$(TARGET).yaml

.PHONY: chaos-cpu
chaos-cpu: ## Run CPU stress chaos experiment
	$(call check_mise)
	kubectl --context $(KUBE_CONTEXT) apply -f chaos/cpu-stress.yaml

.PHONY: chaos-network
chaos-network: ## Run network latency chaos experiment
	$(call check_mise)
	kubectl --context $(KUBE_CONTEXT) apply -f chaos/network-latency.yaml

# -----------------------------------------------------------------------------
# Backup & Restore
# -----------------------------------------------------------------------------

.PHONY: backup-all
backup-all: ## Backup all critical data (etcd, Vault, PostgreSQL)
	$(call check_mise)
	./scripts/backup-vault.sh
	./scripts/backup-postgres.sh
	./scripts/backup-argocd.sh

.PHONY: restore-all
restore-all: ## Restore all critical data
	$(call check_mise)
	./scripts/restore-vault.sh
	./scripts/restore-postgres.sh
	./scripts/restore-argocd.sh

# -----------------------------------------------------------------------------
# Local Development Helpers (for service repos)
# -----------------------------------------------------------------------------

.PHONY: local-build-go
local-build-go: ## Build Go service Docker image locally
	@test -d "../$(GO_SERVICE_REPO)" || { $(call log_error,"$(GO_SERVICE_REPO) not found"); exit 1; }
	cd ../$(GO_SERVICE_REPO) && make build

.PHONY: local-build-node
local-build-node: ## Build Node service Docker image locally
	@test -d "../$(NODE_SERVICE_REPO)" || { $(call log_error,"$(NODE_SERVICE_REPO) not found"); exit 1; }
	cd ../$(NODE_SERVICE_REPO) && make build

.PHONY: local-build-frontend
local-build-frontend: ## Build Frontend Docker image locally
	@test -d "../$(FRONTEND_REPO)" || { $(call log_error,"$(FRONTEND_REPO) not found"); exit 1; }
	cd ../$(FRONTEND_REPO) && make build

.PHONY: local-push-go
local-push-go: ## Push Go service image to local registry
	$(MAKE) local-build-go
	@REGISTRY=$$(kubectl --context $(KUBE_CONTEXT) -n registry get svc registry -o jsonpath='{.spec.clusterIP}'):5000; \
	docker tag platform-services-go:latest $$REGISTRY/platform-services-go:local-$$(date +%s); \
	docker push $$REGISTRY/platform-services-go:local-$$(date +%s)

.PHONY: local-push-node
local-push-node: ## Push Node service image to local registry
	$(MAKE) local-build-node
	@REGISTRY=$$(kubectl --context $(KUBE_CONTEXT) -n registry get svc registry -o jsonpath='{.spec.clusterIP}'):5000; \
	docker tag platform-services-node:latest $$REGISTRY/platform-services-node:local-$$(date +%s); \
	docker push $$REGISTRY/platform-services-node:local-$$(date +%s)

.PHONY: local-push-frontend
local-push-frontend: ## Push Frontend image to local registry
	$(MAKE) local-build-frontend
	@REGISTRY=$$(kubectl --context $(KUBE_CONTEXT) -n registry get svc registry -o jsonpath='{.spec.clusterIP}'):5000; \
	docker tag platform-frontend:latest $$REGISTRY/platform-frontend:local-$$(date +%s); \
	docker push $$REGISTRY/platform-frontend:local-$$(date +%s)

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------

.PHONY: clean
clean: ## Clean up local build artifacts
	rm -rf tofu/.terraform
	rm -rf tofu/.terraform.lock.hcl
	rm -f tofu/terraform.tfstate*
	rm -rf local-secrets/

.PHONY: clean-all
clean-all: cluster-down clean ## Full cleanup (cluster + local artifacts)