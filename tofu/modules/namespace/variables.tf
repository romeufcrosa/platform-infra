variable "name" {
  description = "Namespace name."
  type        = string
}

variable "environment" {
  description = "Environment label applied to the namespace."
  type        = string
  default     = "local"
}

variable "labels" {
  description = "Additional labels."
  type        = map(string)
  default     = {}
}

variable "annotations" {
  description = "Additional annotations."
  type        = map(string)
  default     = {}
}

variable "create" {
  description = "Set false when the namespace is owned by another tool (e.g. a Helm chart)."
  type        = bool
  default     = true
}
