variable "addons" {
  description = "Addons expected to be enabled on the cluster."
  type        = list(string)
  default     = ["ingress", "metrics-server"]
}
