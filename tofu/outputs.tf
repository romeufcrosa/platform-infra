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
  value       = sort(local.platform_namespaces)
}
