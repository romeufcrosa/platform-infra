output "webhook_secret_file" {
  description = "Path to the generated webhook secret file (mode 0600). The `webhook-register` Make target reads it; the secret itself is never an output."
  value       = local_file.webhook_secret.filename
}

output "namespace" {
  description = "Namespace Atlantis runs in."
  value       = helm_release.atlantis.namespace
}
