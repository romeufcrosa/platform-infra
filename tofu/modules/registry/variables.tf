variable "namespace" {
  description = "Namespace for the registry Deployment and Service. OpenTofu creates it in Task 4."
  type        = string
  default     = "registry"
}

# There is deliberately NO `chart_version` and NO `timeout` here, and their
# absence is the tell that this is not a chart module: both exist on the
# `helm_release` modules purely to feed `version = ` and `timeout = `. Here they
# would be inputs that do nothing, and an input that does nothing is worse than
# a missing one, because the next reader cannot tell it apart from a bug. What
# this module has instead of those two is `image_tag`: the registry is the
# second named exception to "every deployed workload is Helm-installed by
# OpenTofu" (Global Constraints).

variable "image_tag" {
  description = "Pinned registry image tag, without the repository. Never 'latest' (Global Constraint)."
  type        = string
  default     = "2.8.3"
}

# The registry is the second named exception to "every deployed workload is
# Helm-installed by OpenTofu", and `image_tag` is its whole surface.
#
# 2.8.3 is the last stable 2.x. The 3.x line exists but 2.8.3 has the widest
# documentation, which is the same reason kube-prometheus-stack is pinned to
# 65.5.1 rather than newest. The root passes this from `var.registry_image`
# rather than relying on the default, so the Global Constraint is checked by
# reading one line.

variable "namespaces" {
  description = "Namespaces that receive the registry image pull secret, and whose default ServiceAccount is patched to use it."
  type        = list(string)
  # A literal copy of the eleven platform namespaces rather than a shared
  # `local`, because locals do not cross a module boundary. The root's
  # `module "registry"` block passes the real `local.platform_namespaces`
  # explicitly so this default is never what is applied — but it is written out
  # in full so the module is usable standalone rather than mysteriously empty.
  default = [
    "argocd",
    "atlantis",
    "ministack",
    "vault",
    "monitoring",
    "registry",
    "external-secrets",
    "platform-system",
    "dev",
    "staging",
    "prod",
  ]
}

variable "namespace_dependency" {
  description = "Explicit dependency so the namespace exists before the workload is created."
  type        = any
  default     = null
}