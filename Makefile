SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

MINIKUBE_PROFILE ?= platform
NAMESPACES := argocd atlantis ministack vault monitoring registry external-secrets platform-system

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: cluster-up
cluster-up: ## Create/start the minikube cluster with pinned addons
	./scripts/setup-minikube.sh

.PHONY: cluster-down
cluster-down: ## Delete the minikube cluster (destructive)
	@read -p "Delete minikube profile '$(MINIKUBE_PROFILE)' and ALL its data? [y/N] " a; [ "$$a" = y ]
	minikube delete -p $(MINIKUBE_PROFILE)

.PHONY: deploy-infra
deploy-infra: ## Apply all infrastructure with OpenTofu
	tofu -chdir=tofu init -upgrade=false -input=false
	tofu -chdir=tofu apply -auto-approve -input=false

.PHONY: destroy-infra
destroy-infra: ## Destroy all infrastructure managed by OpenTofu (destructive)
	@read -p "Destroy ALL OpenTofu-managed resources? [y/N] " a; [ "$$a" = y ]
	tofu -chdir=tofu destroy -auto-approve -input=false

.PHONY: port-forwards
port-forwards: ## Forward ArgoCD, Grafana, Vault, Ministack, registry to localhost
	./scripts/port-forwards.sh

.PHONY: verify
verify: ## Run the Phase 1 success-criteria gate
	./scripts/verify-phase1.sh

.PHONY: fmt
fmt: ## Format and validate OpenTofu configuration
	tofu -chdir=tofu fmt -recursive
	tofu -chdir=tofu validate
