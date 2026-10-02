variable "namespace" {
  description = "Namespace for kube-prometheus-stack. One of the platform namespaces."
  type        = string
  default     = "monitoring"
}

# 65.5.1 (appVersion v0.77.2), read off the live repo with
#   helm search repo prometheus-community/kube-prometheus-stack --version 65.5.1
# on 2026-09-30, not copied from documentation. The newest published version at
# that moment was 91.8.2 — nine major versions away. helm/values/prometheus.yaml
# is written against the 65.x schema; 91.x would fail at apply against keys that
# no longer exist. When the chart is upgraded, that values file is upgraded with
# it in the same commit.
variable "chart_version" {
  description = "Pinned kube-prometheus-stack chart version."
  type        = string
  default     = "65.5.1"
}

# Path to helm/values/prometheus.yaml, RELATIVE TO THE OPENTOFU WORKING
# DIRECTORY (`tofu/`), not to this module. See the note on `var.values_file`
# usage in main.tf: `file("${path.module}/../../...")` is rejected by
# OpenTofu 1.7.0 with "Invalid value for \"path\" parameter ... works only with
# files that are distributed as part of the configuration source code"
# (verified 2026-09-30). Same pattern, same default, as `module "argocd"`.
variable "values_file" {
  description = "Path to the chart's values file, relative to the OpenTofu working directory (tofu/)."
  type        = string
  default     = "../helm/values/prometheus.yaml"
}

variable "timeout" {
  description = "Helm timeout in seconds. Generous: a cold pull of the full stack is slow on a laptop."
  type        = number
  default     = 900
}

# `retention` and `persistence_enabled` are inputs rather than constants because
# they are local-profile deviations, not component settings — the production
# values (30d, PVC enabled) belong in the chart defaults and belong to a profile
# that does not exist yet. The defaults here are the local ones so the module is
# usable standalone; the root always passes the values from
# `tofu/environments/local/overrides.tf`, so forgetting costs a 2-day retention
# rather than a loud error.
variable "retention" {
  description = "Prometheus metric retention. Overridden per environment by the local profile."
  type        = string
  default     = "30d"
}

variable "persistence_enabled" {
  description = "Back Prometheus with a PVC. Off for local: the whole cluster is disposable and the PVC costs a slow first apply."
  type        = bool
  default     = false
}

variable "namespace_dependency" {
  description = "Explicit dependency so the namespace exists before the chart installs."
  type        = any
  default     = null
}