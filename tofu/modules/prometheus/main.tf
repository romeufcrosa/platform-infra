# kube-prometheus-stack. One `helm_release`; the chart owns roughly 80 rendered
# objects, which is exactly why none of them are re-declared anywhere else.
locals {
  # The chart's rendered object names, read off `helm template` output against
  # 65.5.1 with helm/values/prometheus.yaml. They are NOT the names the plan
  # assumed, and getting this wrong produces a port-forward that fails with
  # `service "prometheus-server" not found` — an error that names nothing
  # useful. Verified 2026-09-30:
  #
  #   $ helm template kube-prometheus-stack prom/kube-prometheus-stack \
  #       --version 65.5.1 -f helm/values/prometheus.yaml
  #
  #   Service grafana                 (80 -> 3000)
  #   Service prometheus-prometheus   (9090)
  #   Service prometheus-alertmanager (9093)
  #   Prometheus CR  prometheus-prometheus
  #
  # The plan wrote `deploy/prometheus-server` and `prometheus-operated`. Neither
  # exists in 65.5.1: `prometheus-server` is the pre-40.0.0 kube-prometheus
  # name, and this chart creates only the Prometheus CR — the operator creates
  # the StatefulSet from it, named after the CR. There is no Deployment to wait
  # on for Prometheus at all.
  grafana_service      = "grafana"
  prometheus_service   = "prometheus-prometheus"
  alertmanager_service = "prometheus-alertmanager"

  # `var.values_file` is a path RELATIVE TO THE WORKING DIRECTORY OpenTofu runs
  # from (`tofu/`), not to this module. That is not a typo and it is not the
  # elegant-looking spelling:
  #
  #   file("${path.module}/../../helm/values/prometheus.yaml")
  #
  # which is what the brief wrote, fails at validate:
  #
  #   Error: Invalid function argument
  #     on modules/prometheus/main.tf ... in resource "helm_release" "prometheus"
  #   Invalid value for "path" parameter: no file exists at
  #   "modules/prometheus/../../helm/values/prometheus.yaml"; this function
  #   works only with files that are distributed as part of the configuration
  #   source code.
  #
  # Verified 2026-09-30 against OpenTofu 1.7.0. It is the same restriction
  # Task 7 hit reading `scripts/bootstrap-ministack-queues.sh` from
  # `tofu/modules/ministack`. The fix is not to move the values file into the
  # module — the Makefile chart gate reads `helm/values/prometheus.yaml` at the
  # repo root, and a second copy would be a third place to keep the pin right.
  # It is to let the caller name the path, exactly as `module "argocd"` already
  # does for `helm/values/argocd.yaml`.
  #
  # The consequence, stated plainly: this default resolves only when OpenTofu
  # is invoked from `tofu/` (every `make` target and every `tofu -chdir=tofu`
  # does). Running `tofu` from the repo root against `tofu/` does not. Same
  # constraint the argocd module already has.

  # The Prometheus workload is operator-created, so there is no
  # `kubernetes_manifest` to declare for it. `tofu wait` would be the natural
  # thing here; it is deliberately NOT used, because a wait on an operator-
  # created StatefulSet fails on a clean cluster where the operator has not got
  # there yet, and a check that fails on ordering trains everyone to ignore it.
  # scripts/verify-phase1.sh checks readiness instead.
}

resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "helm_release" "prometheus" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.chart_version

  namespace = var.namespace

  # OpenTofu owns every namespace (Global Constraint). Without this line the
  # chart races `module.namespaces`'s for_each for the same object and the two
  # tools disagree about who owns it.
  create_namespace = false
  timeout          = var.timeout

  values = concat(
    [file(var.values_file)],
    [yamlencode({
      grafana = { adminPassword = random_password.grafana.result }
      prometheus = {
        prometheusSpec = {
          retention   = var.retention
          persistence = { enabled = var.persistence_enabled }
        }
      }
    })],
  )

  # NOTE: the plan also carried
  #   set { name = "prometheus.prometheusSpec.serviceMonitorSelector"
  #         value = "{}" }
  # It is gone. helm/values/prometheus.yaml already sets the key, and a Helm
  # `set` value is a STRING — the provider serialises it, the chart receives
  # `"{}"` rather than `{}`, and the two disagree about the same key in the
  # same release. Verified by rendering: with the values file alone the
  # Prometheus CR carries `serviceMonitorSelector: {}` as a real map. Two
  # mechanisms setting one key, one of them wrong-typed, is a worse outcome
  # than either alone.

  depends_on = [var.namespace_dependency]
}

# The Grafana admin password in plaintext, under the gitignored local-secrets/.
# The brief put this at
#   ${path.module}/../../../local-secrets/grafana-admin-password
# `../../../` from `tofu/modules/prometheus` is the repo root, which is correct.
resource "local_file" "grafana_password" {
  filename             = "${path.module}/../../../local-secrets/grafana-admin-password"
  content              = random_password.grafana.result
  file_permission      = "0600"
  directory_permission = "0700"
}

# --- NO `kubernetes_config_map.alertmanager_routes` ------------------------
#
# The brief declared a ConfigMap `alertmanager-platform-routes` in the
# monitoring namespace, labelled `alertmanager: main`, holding a `routes.yaml`
# key with a null receiver. Nothing in 65.5.1 reads it.
#
# Verified against the pulled chart:
#   $ grep -rn "alertmanager: main" kube-prometheus-stack/templates/
#   (no matches)
#
# The label `alertmanager: main` belongs to the Helm chart's *manual*
# configuration path, which this chart does not use. templates/alertmanager/
# secret.yaml:1-27 renders the entire Alertmanager configuration into a Secret
# named `alertmanager-<crname>` with the single key `alertmanager.yaml`, built
# from `.Values.alertmanager.config`. The route therefore lives in
# helm/values/prometheus.yaml, where it is rendered into that Secret — verified
# by decoding the rendered `alertmanager.yaml` and reading `route.receiver:
# "null"` and `group_by: [alertname, namespace]` in it.
#
# The consequence of shipping the ConfigMap would have been a ConfigMap that
# looks like the alerting configuration and is not one: every alert would be
# delivered by the chart's own default route, and a reader debugging "why did
# my route not fire" would be reading a file the running system never opened.