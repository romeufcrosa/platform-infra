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
	$(MAKE) bootstrap-argocd
	tofu -chdir=tofu apply -auto-approve -input=false

.PHONY: bootstrap-argocd
bootstrap-argocd: ## Install the ArgoCD chart (and its CRDs) before the first full apply
	@# `kubernetes_manifest.bootstrap_application` resolves Application against
	@# the live API at PLAN time, so on a cluster where the CRD is not yet
	@# installed the full plan fails with "no matches for kind Application"
	@# before any apply-time `depends_on` can be considered. Applying the
	@# release on its own first installs applications.argoproj.io and makes the
	@# full plan resolvable. Idempotent: a no-op once the chart is installed.
	@# See tofu/modules/argocd/main.tf and docs/runbooks/argocd-out-of-sync.md.
	tofu -chdir=tofu apply -auto-approve -input=false -target=module.argocd.helm_release.argocd

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
	@# The chart versions below MUST match each module's `chart_version` default. An
	@# unpinned `helm template` resolves to whatever the repo serves *today*, so the
	@# gate can render a materially different object set than the one deployed
	@# and still go green — argo/argo-cd unpinned was rendering 10.9.2 against a
	@# module pinned to 6.7.18. A gate that validates the wrong chart is worse
	@# than no gate, because it looks like coverage.
	@#
	@# A chart whose values file does not exist yet is SKIPped, not FAILED. The
	@# list is deliberately ahead of the code: the values files for vault,
	@# prometheus and atlantis land in Tasks 8, 9 and 10. Reporting those as
	@# failures is noise that trains people to ignore this target, and "SKIP
	@# (no helm/values/vault.yaml)" says plainly which task is outstanding. Once
	@# a file exists the leg is real and a render failure is a real failure.
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
	  "argocd argo/argo-cd 6.7.18" \
	  "atlantis runatlantis/atlantis 6.16.0" \
	  "vault hashicorp/vault 0.28.0" \
	  "prometheus prometheus-community/kube-prometheus-stack 65.5.1"; do \
	  name="$$(echo $$pair | cut -d' ' -f1)"; \
	  chart="$$(echo $$pair | cut -d' ' -f2)"; \
	  ver="$$(echo $$pair | cut -d' ' -f3)"; \
	  vf="helm/values/$$name.yaml"; \
	  printf 'helm: %s (%s) ... ' "$$name" "$$ver"; \
	  if [ ! -f "$$vf" ]; then \
	    echo "SKIP (no $$vf)"; \
	  elif helm template "$$name" "$$chart" --version "$$ver" -f "$$vf" >/dev/null 2>&1; then \
	    echo OK; \
	  else \
	    echo FAILED; \
	    failed="$$failed $$name"; \
	  fi; \
	done; \
	test -z "$$failed" || { echo "helm template failed for:$$failed"; exit 1; }
	yamllint -c .yamllint.yaml . && echo "yamllint: OK"
