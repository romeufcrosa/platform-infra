# No `type =` on either block: OpenTofu 1.7 rejects it on `output` blocks as
# `Unsupported argument`. `variable` blocks above take `type` normally. See
# tofu/outputs.tf for the full error text.

output "root_token_file" {
  description = <<-EOT
    Path to the generated Vault root token file (mode 0600).
    `scripts/seed-vault.sh` and `docs/runbooks/vault-secrets.md` both read it
    from here; no token value is ever an output.
  EOT
  value       = local_file.root_token.filename
}

output "namespace" {
  description = "Namespace Vault runs in."
  value       = helm_release.vault.namespace
}
