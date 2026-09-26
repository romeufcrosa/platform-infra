variable "namespace" {
  description = "Namespace for the operator and its credentials secret."
  type        = string
  default     = "external-secrets"
}

variable "chart_version" {
  description = "Pinned external-secrets chart version."
  type        = string
  default     = "0.9.11"
}

variable "timeout" {
  description = "Helm timeout in seconds."
  type        = number
  default     = 600
}

variable "vault_token" {
  description = "Vault token used by the ClusterSecretStore. Set by Task 9."
  type        = string
  default     = ""
  sensitive   = true
}
