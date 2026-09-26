# NOTE: no `type = ` argument on these outputs.
#
# The task brief specified `type = map(string)` / `type = list(string)`, but
# `type` is a *Terraform* 1.3+ feature. OpenTofu's `output` block supports only
# value, description, sensitive, ephemeral, depends_on, deprecated — declaring
# `type` here is a hard error on the pinned OpenTofu 1.7.0:
#
#   Error: Unsupported argument
#   on outputs.tf line 3, in output "endpoints":
#     3:   type        = map(string)
#   An argument named "type" is not expected here.
#
# Verified against OpenTofu 1.7.0 on 2026-09-26. The values are still type-checked
# at consumption, so the contract later tasks rely on (a map of name -> URL, a
# sorted list of namespace names) is unchanged — only the redundant declaration
# is gone. See task-3-report.md.

output "endpoints" {
  description = "Map of component name to local endpoint URL. Extended by each component task."
  value       = {}
}

output "namespaces" {
  description = "Namespaces created by the platform modules."
  value       = sort([for ns in module.namespaces : ns.name])
}

# Surfaced deliberately, even though nothing consumes it yet.
#
# This is what makes the Phase 1 Atlantis exit criterion satisfiable: the
# criterion is "open a PR editing tofu/environments/local/overrides.tf and read
# the plan comment". A module output only shows a diff in the plan if something
# reads it. This output reads every one of them, so editing overrides.tf
# produces a visible, non-empty plan — which is the proof the criterion needs.
#
# Without this, `module "local"` would be declared-but-not-wired for real: the
# overrides would be computed, validated, and then invisible to every tool.
output "local_overrides" {
  description = "Values from the local environment profile, for plan visibility. Consumed by Tasks 7-10."
  value       = local.local_overrides
}
