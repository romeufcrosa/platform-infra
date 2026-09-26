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
fmt: ## Format and validate OpenTofu config and the local-overrides guard
	tofu -chdir=tofu fmt -recursive
	tofu -chdir=tofu validate
	./scripts/check-local-overrides.sh

.PHONY: test-guard
test-guard: ## Red/green controls for the local-overrides guard
	./scripts/test-check-local-overrides.sh

.PHONY: validate
validate: ## Run the same checks as CI: tofu fmt/validate, kustomize build, helm template, yamllint
	@helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
	@helm repo add runatlantis https://runatlantis.github.io/helm-charts 2>/dev/null || true
	@helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	@helm repo update >/dev/null
	tofu -chdir=tofu fmt -check -recursive
	tofu -chdir=tofu init -backend=false -input=false >/dev/null
	tofu -chdir=tofu validate
	kubectl kustomize kubernetes/platform-system >/dev/null && echo "kustomize: platform-system OK"
	kubectl kustomize argocd/applications >/dev/null && echo "kustomize: applications OK"
	kubectl kustomize argocd/projects >/dev/null && echo "kustomize: projects OK"
	@failed=""; \
	for pair in \
	  "argocd argo/argo-cd" \
	  "atlantis runatlantis/atlantis" \
	  "vault hashicorp/vault" \
	  "prometheus prometheus-community/kube-prometheus-stack"; do \
	  name="$${pair%% *}"; chart="$${pair#* }"; \
	  printf 'helm: %s ... ' "$$name"; \
	  if helm template "$$name" "$$chart" -f "helm/values/$$name.yaml" >/dev/null 2>&1; then \
	    echo OK; \
	  else \
	    echo FAILED; \
	    failed="$$failed $$name"; \
	  fi; \
	done; \
	test -z "$$failed" || { echo "helm template failed for:$$failed"; exit 1; }
	yamllint -c .yamllint.yaml . && echo "yamllint: OK"
