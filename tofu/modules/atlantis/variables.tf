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

variable "namespace_dependency" {
  description = "Explicit dependency so the namespace exists before the chart installs."
  type        = any
  default     = null
}
