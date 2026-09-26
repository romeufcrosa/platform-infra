variable "namespace" {
  description = "Namespace for the operator and its credentials secret."
  type        = string
  default     = "external-secrets"
}

variable "chart_version" {
  description = "Pinned external-secrets chart version. DO NOT \"refresh\" this — see below."
  type        = string
  default     = "0.9.11"

  # Pinned — Global Constraint. Verified present in the live repo.
  #
  # DO NOT "refresh" this to 2.x. The pin is old on purpose: 0.9.x serves the
  # `external-secrets.io/v1beta1` API, which is what every manifest in this
  # plan declares (see `cluster-secret-store.yaml` in this module and all 14
  # ClusterSecretStore references in Task 9). The 2.x line moved to `v1`, so a
  # version bump here is not a version bump — it is an API contract change that
  # would break Task 9 with no error at the pin site. Verified 2026-09-26: 0.9.11
  # exists (appVersion v0.9.11); current upstream is 2.11.0. The served versions
  # were re-confirmed against the live CRD on 2026-09-26, which reports
  # `v1alpha1 v1beta1` — `v1beta1` present, `v1` absent.
  #
  # Bumping this also invalidates `crd_names` in outputs.tf: the CRD set is
  # part of the operator's API contract, and the chart is what installs it.
  # A bump here is two coupled changes, not one.
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
