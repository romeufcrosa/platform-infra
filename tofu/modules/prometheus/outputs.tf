# NOTE: no `type =` on any output. OpenTofu 1.7.0 rejects it on an `output`
# block as `Unsupported argument` (see tofu/outputs.tf for the verified error).
# `variable` blocks still take `type`.

output "grafana_password_file" {
  description = "Path to the generated Grafana admin password file (mode 0600). The verify script reads it to prove the password is reachable without printing it."
  value       = local_file.grafana_password.filename
}

output "namespace" {
  description = "Namespace kube-prometheus-stack runs in."
  value       = helm_release.prometheus.namespace
}

# The three Service names the chart actually renders, read off `helm template`
# output rather than assumed. `scripts/port-forwards.sh` and the Grafana
# datasource ConfigMap both need them, and the plan's names
# (`prometheus-server`, `prometheus-operated`) are not objects this chart
# creates. Exporting them is what keeps those three places from becoming four.
output "service_names" {
  description = "Service names the chart renders in var.namespace: grafana (80), prometheus (9090), alertmanager (9093)."
  value = {
    grafana      = local.grafana_service
    prometheus   = local.prometheus_service
    alertmanager = local.alertmanager_service
  }
}

# Grafana's URL is deliberately NOT an output: `http://localhost:3000` is a
# host-local address that belongs to the root's `endpoints` map, the single
# place the verify script and docs/onboarding.md read. Same for the
# `release: kube-prometheus-stack` ServiceMonitor label — it is a string every
# Phase 2 service must carry, and giving it an output would give it two homes,
# one of them a module a future profile may not install.