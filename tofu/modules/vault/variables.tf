variable "namespace" {
  description = "Namespace for the Vault release. One of the platform namespaces."
  type        = string
  default     = "vault"
}

variable "chart_version" {
  description = "Pinned hashicorp/vault chart version (not the Vault application version)."
  type        = string
  default     = "0.28.0"

  # This is the CHART version, not the Vault version it ships. The two number
  # independently; pasting the app version here is the mistake this default
  # exists to prevent, and the error it produces — `chart "vault" version
  # "1.16.1" not found` — reads like a repository outage rather than a
  # category error.
  #
  # Both numbers verified against the live registry, not from memory, on
  # 2026-09-30:
  #
  #   $ helm search repo hashicorp/vault --version 0.28.0
  #   NAME            CHART VERSION  APP VERSION  DESCRIPTION
  #   hashicorp/vault 0.28.0         1.16.1        Official HashiCorp Vault Chart
  #
  # `helm pull hashicorp/vault --version 0.28.0 --untar` then confirms
  # Chart.yaml `version: 0.28.0` / `appVersion: 1.16.1`, and the rendered
  # container image is `hashicorp/vault:1.16.1`. The pin is present in the live
  # index. The same trap is waiting in Task 8, where chart `65.5.1` ships
  # Prometheus `v0.77.2`; neither number is a typo for the other.
  #
  # `make validate` re-renders this exact version, so a bump here that is not
  # made in the Makefile turns the CI gate into coverage of a chart nothing runs.
}

variable "values_file" {
  description = "Path to the chart's values file, relative to the OpenTofu working directory (tofu/)."
  type        = string
  default     = "../helm/values/vault.yaml"
}

variable "timeout" {
  description = "Helm timeout in seconds. Vault's hook Jobs are slow to start on a cold cluster."
  type        = number
  default     = 600
}

variable "namespace_dependency" {
  description = "Explicit dependency so the namespace exists before the chart installs."
  type        = any
  default     = null
}

variable "external_secrets_dependency" {
  description = <<-EOT
    Explicit dependency on the External Secrets Operator module, so the
    ClusterSecretStore CRD exists before the ClusterSecretStore and the creds
    Secret are planned. `type = any` for the same reason as
    `namespace_dependency`: OpenTofu cannot read through `any` to discover the
    ordering, so the root writes the module reference out longhand.
  EOT
  type        = any
  default     = null
}
