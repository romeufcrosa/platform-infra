# Root module. Each component is added by its own task, in this order:
#   0. minikube_addons   (Task 3 — asserts the baseline; no resources)
#      local overrides   (Task 3 — the live deviation file)
#   1. namespaces        (Task 4)
#   2. external-secrets  (Task 4)
#   3. argocd            (Task 6)
#   4. ministack         (Task 7)
#   5. registry+prometheus (Task 8)
#   6. vault             (Task 9)
#   7. atlantis          (Task 10)
#
# OpenTofu resolves the dependency graph from the references between
# modules; the comment records intent, the references enforce it.
#
# The `terraform { required_version / required_providers }` block lives in
# versions.tf. Note that it is spelled `terraform`, not `tofu`: OpenTofu 1.7.0
# (the pin) does not accept a `tofu` block — that alias arrived in 1.8.0 and
# errors here as "Blocks of type \"tofu\" are not expected here". The Global
# Constraint against `terraform` is about the *binary invoked*, not the HCL
# block name. Verified 2026-09-26.

# Asserts the addon baseline (ingress, metrics-server). It creates NO
# resources — it exists so Task 2's `check` block actually evaluates. Before
# this module block was added, nothing referenced minikube_addons, so the check
# never ran and `tofu plan` showed no addon assertion at all: the drift signal
# was switched off.
#
# A failed `check` is a WARNING, not an error — `tofu plan` still exits 0. Do
# not write CI that treats this exit code as a gate. Anything that must
# hard-fail belongs in a resource `precondition` or in a shell script.
module "minikube_addons" {
  source = "./modules/minikube_addons"

  addons = ["ingress", "metrics-server"]
}

# The local environment profile. This is a real module, not a directory of
# comments: `locals` do not cross a module boundary, so
# environments/local/outputs.tf re-exports each override as a module output and
# the component modules read them from here.
#
# The root consumes these via `local_overrides` below, which is what makes the
# Phase 1 Atlantis exit criterion satisfiable: editing overrides.tf must show up
# in a plan. Were this module absent, that PR would produce an empty plan and
# the criterion would silently prove nothing.
module "local" {
  source = "./environments/local"
}

locals {
  environment = var.environment

  # SINGLE SOURCE OF TRUTH for every namespace in the platform.
  # Task 4 drives the namespace module's `for_each` from this list, and the
  # `namespaces` output below is derived from it, so the verify script reads
  # the same names. Declared in Task 3 rather than Task 4 so the names are
  # fixed before any task consumes them — the one thing later tasks cannot
  # recover. ADR-0002 makes this list authoritative; the Makefile's
  # NAMESPACES is a non-authoritative human-readable mirror.
  platform_namespaces = [
    "argocd",
    "atlantis",
    "ministack",
    "vault",
    "monitoring",
    "registry",
    "external-secrets",
    "platform-system",
    "dev",
    "staging",
    "prod",
  ]

  common_labels = {
    "app.kubernetes.io/part-of"    = "platform-learning-ecosystem"
    "app.kubernetes.io/managed-by" = "opentofu"
    "platform.environment"         = var.environment
  }

  # Every value the local environment profile deviates on, collected in one map.
  #
  # This local is the consuming reference that makes `module "local"` more than
  # a declared-but-unwired module. Components in Tasks 7-10 read
  # `local.local_overrides["<key>"]`.
  #
  # NOTE: there is deliberately NO `check` block here asserting that these keys
  # match the module's output names. OpenTofu 1.7 cannot enumerate a module's
  # output names, so the only available expression compares this map's keys to
  # itself — a tautology that can never fire, and an untested check is worse
  # than none. The key-set agreement is instead verified by
  # scripts/check-local-overrides.sh, which diffs the two files' keys. See
  # task-3-report.md, "Declared-but-not-wired audit".
  local_overrides = {
    vault_dev_mode                 = module.local.vault_dev_mode
    prometheus_retention           = module.local.prometheus_retention
    prometheus_persistence_enabled = module.local.prometheus_persistence_enabled
    atlantis_replica_count         = module.local.atlantis_replica_count
    ministack_replica_count        = module.local.ministack_replica_count
  }
}

# `local.platform_namespaces` is NOT re-declared here. It already exists above,
# from Task 3, and it has to: the namespace list is fixed *before* any namespace
# is created, because that is the one decision a later task cannot recover if it
# turns out wrong. Declaring it a second time in a second `locals` block is a hard
# HCL error — `Duplicate local value definition` / `Attribute redefined` — so the
# cluster would not come up at all.
#
# Task 4 adds the two `module` blocks below and nothing else to `tofu/main.tf`. The
# list itself is unchanged: all eleven names, platform eight plus `dev`, `staging`,
# `prod`. The application namespaces are created here rather than waiting for ArgoCD
# to sync the Kustomize manifests, so `make verify` has a deterministic cluster to
# check immediately after `tofu apply` instead of racing a GitOps sync.
module "namespaces" {
  source   = "./modules/namespace"
  for_each = toset(local.platform_namespaces)

  name = each.key
  # An application namespace is labelled with its own name; a platform namespace
  # is labelled `local`. This is what the verify script and the ArgoCD AppProjects
  # key off.
  environment = contains(["dev", "staging", "prod"], each.key) ? each.key : local.environment
  labels      = local.common_labels
}

module "external_secrets" {
  source    = "./modules/external_secrets"
  namespace = "external-secrets"
  timeout   = var.helm_timeout

  depends_on = [module.namespaces]
}

module "argocd" {
  source = "./modules/argocd"

  namespace      = "argocd"
  timeout        = var.helm_timeout
  admin_password = var.argocd_admin_password
  repo_url       = var.platform_infra_repo_url
  repo_password  = var.github_pat

  depends_on = [module.namespaces]
}

# Ministack has no Helm chart, so this module declares a `kubernetes_deployment`
# and a `kubernetes_service` rather than a `helm_release`. Verified 2026-09-28:
# `https://ministack.github.io/ministack-helm/index.yaml` returns 404 and no
# chart for Ministack is published anywhere, so a `helm_release` here would
# fail at apply with a repository-not-found error. There is deliberately no
# `helm/values/ministack.yaml` for the same reason.
module "ministack" {
  source = "./modules/ministack"

  namespace = "ministack"

  # The pin lives in exactly one place — `var.ministack_image` in Task 3 — so
  # the Global Constraint is checked by reading a single line. Splitting on ":"
  # is safe because the variable is a fully-qualified `repository:tag` by
  # construction; a caller who passed a digest (`@sha256:...`) or a bare tag
  # would get a wrong `image_tag` rather than an error, which is why the default
  # is written out in full rather than assembled.
  #
  # That caveat is not theoretical. Until Task 7 this variable's default was
  # `ghcr.io/ministack/ministack:v0.9.0` — the wrong organisation and a tag
  # that does not exist. The split silently produced `image_tag = "v0.9.0"`,
  # the module rendered `ministackorg/ministack:v0.9.0`, and `tofu plan` exited
  # 0. See the comment on the variable in tofu/variables.tf.
  image_tag = split(":", var.ministack_image)[1]

  # No `timeout` argument: this module installs no chart, so the Helm timeout
  # has nothing to govern. Passing it would suggest the resource has a
  # timeout-sensitive code path it does not have.
  depends_on = [module.namespaces]
}
