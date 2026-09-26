variable "kube_context" {
  description = "kubectl context every provider and Helm release targets."
  type        = string
  default     = "platform"
}

variable "environment" {
  description = "Deployment profile. Only 'local' exists in Phase 1."
  type        = string
  default     = "local"

  validation {
    condition     = contains(["local"], var.environment)
    error_message = "Phase 1 supports only the 'local' environment."
  }
}

variable "helm_timeout" {
  description = "Per-release Helm timeout. Prometheus is slow on a cold pull."
  type        = number
  default     = 900
}

# No reader until Task 10, which renders it into the generated `atlantis.yaml`
# via `local_file.atlantis_repo_config`. Not an orphan — do not re-file.
variable "atlantis_repo" {
  description = "GitHub repo Atlantis serves, as 'org/repo'."
  type        = string
  default     = ""
}

variable "argocd_admin_password" {
  description = "Optional fixed ArgoCD admin password. Empty = generated."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ministack_image" {
  description = "Pinned Ministack image tag. Never 'latest' (Global Constraint)."
  type        = string
  default     = "ghcr.io/ministack/ministack:v0.9.0"
}
