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
