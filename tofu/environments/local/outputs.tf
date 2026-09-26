# `locals` do not cross a module boundary, so this module re-exports each local
# from overrides.tf as an output of the same name and type. The root then passes
# them to the component modules (Tasks 7–10).
#
# THIS FILE IS LIVE, and it is the subject of the Phase 1 Atlantis exit
# criterion: "open a PR editing overrides.tf and read the plan comment." If the
# overrides were inert, that edit would produce an empty plan and the criterion
# could not be met — the one manual proof that the webhook, tunnel, PAT, repo
# lock and `dir: tofu` all work together would silently prove nothing.
#
# Note the absence of `type =` on every output below. `type` on an `output`
# block is a Terraform 1.3+ feature; OpenTofu 1.7.0's `output` block rejects it
# as a hard error:
#
#   Error: Unsupported argument
#     An argument named "type" is not expected here.
#
# `variable` blocks still accept `type`. This file is the first one later tasks
# copy from, so getting the shape wrong here propagates. Verified 2026-09-26.

output "vault_dev_mode" {
  description = "Vault runs in dev mode: single unseal key, in-memory storage."
  value       = local.vault_dev_mode
}

output "prometheus_retention" {
  description = "Prometheus metric retention. 2d locally; 30d is the production value."
  value       = local.prometheus_retention
}

output "prometheus_persistence_enabled" {
  description = "Prometheus persistence. False locally so a laptop reset is cheap."
  value       = local.prometheus_persistence_enabled
}

output "atlantis_replica_count" {
  description = "Atlantis replica count. One locally."
  value       = local.atlantis_replica_count
}

output "ministack_replica_count" {
  description = "Ministack replica count. One locally."
  value       = local.ministack_replica_count
}
