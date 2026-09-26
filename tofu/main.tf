# Root module. Each component is added by its own task, in this order:
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
}
