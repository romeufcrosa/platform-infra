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
  # CORRECTED 2026-09-28 by Task 7. This was `ghcr.io/ministack/ministack:v0.9.0`,
  # which is wrong in two independent ways and failed silently in a third.
  #
  #   * Wrong organisation. Ministack publishes to Docker Hub as
  #     `ministackorg/ministack`. `ghcr.io/ministack/ministack` is not where
  #     the image is.
  #   * Wrong version scheme. The current line is 1.5.x, not v0.9.0. The
  #     newest verified tag is 1.5.17; 0.9.0 does not exist.
  #   * Worst of the three: `module "ministack"` does
  #     `split(":", var.ministack_image)[1]` and builds
  #     `ministackorg/ministack:${image_tag}`. With the old default that
  #     rendered `ministackorg/ministack:v0.9.0` — a plausible-looking string
  #     pointing at an image that does not exist. `tofu validate` passed and
  #     `tofu plan` exited 0. The failure would have surfaced only as
  #     ImagePullBackOff, and the Job's wait loop would have masked it by
  #     spinning until backoffLimit was spent.
  #
  # Verified 2026-09-28 against Docker Hub: tag 1.5.17 exists with linux/amd64
  # and linux/arm64 manifests, and was pulled and run successfully.
  default = "ministackorg/ministack:1.5.17"
}

variable "platform_infra_repo_url" {
  description = <<-EOT
    Git URL of this repository. Used twice, deliberately: ArgoCD registers it
    as a repo secret so the Application can read its own source, and the
    Atlantis module uses the same value for the repo it locks. One variable,
    so the two can never disagree about which repo the platform manages.
  EOT
  type        = string
  default     = "https://github.com/romeufcrosa/platform-infra.git"
}

variable "github_pat" {
  description = "PAT used by ArgoCD to read the repo and by the Atlantis smoke test. Empty for a public repo."
  type        = string
  default     = ""
  sensitive   = true
}
