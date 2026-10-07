variable "namespace" {
  description = "Namespace for the PostgreSQL cluster."
  type        = string
  default     = "dev"
}

variable "timeout" {
  description = "Helm timeout in seconds."
  type        = number
  default     = 600
}

variable "postgres_user" {
  description = "PostgreSQL username."
  type        = string
}

variable "postgres_password" {
  description = "PostgreSQL password."
  type        = string
}

variable "postgres_db" {
  description = "PostgreSQL database name."
  type        = string
}

variable "namespace_dependency" {
  description = "Dependency on namespace creation."
  type        = any
}