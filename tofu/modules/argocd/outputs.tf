output "password_file" {
  description = "Path to the generated admin password file (mode 0600)."
  value       = local_file.admin_password.filename
}

output "namespace" {
  description = "Namespace ArgoCD runs in."
  value       = helm_release.argocd.namespace
}
