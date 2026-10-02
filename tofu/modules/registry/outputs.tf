# NOTE: no `type =` on any of these. OpenTofu 1.7.0 rejects it on an `output`
# block as `Unsupported argument` (Global Constraint); `variable` blocks still
# take `type`.

output "registry_url" {
  description = "Host-local registry address, after `make port-forwards`. The push target every Phase 2 service uses."
  value       = "localhost:5000"
}

output "in_cluster_url" {
  description = "In-cluster address of the registry Service, for image references that pods pull from."
  # The namespace is interpolated rather than typed in: the Service lives in
  # `var.namespace`, and a literal `registry.kube-system.svc` here would be a
  # plausible-looking address that resolves to nothing.
  value = "registry.${var.namespace}.svc:5000"
}

output "pull_secret_name" {
  description = "Name of the image pull secret created in each namespace. Phase 2 workloads reference it by this name."
  # The name is the same in every namespace, so one arbitrary key is read rather
  # than a list of eleven identical strings. `sort(...)[0]` is deterministic;
  # `keys(...)[0]` is not, and a non-deterministic output produces a spurious
  # diff on every plan.
  value = kubernetes_secret.pull_secret[sort(var.namespaces)[0]].metadata[0].name
}