variable "namespace" {
  description = "Namespace for the Atlantis release. One of the platform namespaces."
  type        = string
  default     = "atlantis"
}

variable "timeout" {
  description = "Helm timeout in seconds."
  type        = number
  default     = 600
}

variable "github_pat" {
  description = "PAT Atlantis uses to clone the repo and post plan comments. Empty = a generated value, which cannot actually reach GitHub and fails at the first webhook."
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_user" {
  description = "GitHub username for Atlantis. Required if github_pat is set. Empty = dummy value for local dev without GitHub integration."
  type        = string
  default     = "local-dev"
}

variable "namespace_dependency" {
  description = "Explicit dependency so the namespace exists before the chart installs."
  type        = any
  default     = null
}

variable "values_file" {
  description = "Path to the helm values file, relative to the OpenTofu working directory (tofu/)."
  type        = string
}

variable "repo_config_content" {
  description = "Content of the atlantis.yaml repo config file (rendered from template)."
  type        = string
}
