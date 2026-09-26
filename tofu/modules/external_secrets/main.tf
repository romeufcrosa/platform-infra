resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"

  # The pin lives in `var.chart_version` — read variables.tf for why 0.9.x must
  # not be "refreshed" to 2.x. The warning sits with the value, not here.
  version = var.chart_version

  namespace = var.namespace

  # OpenTofu owns every namespace (see the Global Constraint). Without this
  # line a chart that defaults to creating its own namespace races the
  # `module.namespaces` for_each for the same object, and the two tools then
  # disagree about who owns it.
  create_namespace = false

  timeout = var.timeout

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "replicaCount"
    value = "1"
  }
  set {
    name  = "leaderElector.enabled"
    value = "false"
  }
  set {
    name  = "webhook.replicaCount"
    value = "1"
  }
  # Single replica, no leader election: this is a laptop. Documented in
  # docs/adr/0002-single-minikube-cluster.md.
}

resource "kubernetes_secret" "es_creds" {
  count = var.vault_token == "" ? 0 : 1

  metadata {
    name      = "external-secrets-vault-creds"
    namespace = var.namespace
  }

  data = {
    token = var.vault_token
  }

  depends_on = [helm_release.external_secrets]
}
