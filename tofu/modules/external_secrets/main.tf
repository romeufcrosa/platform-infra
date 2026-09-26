resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  # Pinned — Global Constraint. Verified present in the live repo.
  #
  # DO NOT "refresh" this to 2.x. The pin is old on purpose: 0.9.x serves the
  # `external-secrets.io/v1beta1` API, which is what every manifest in this
  # plan declares (see `cluster-secret-store.yaml` below and all 14
  # ClusterSecretStore references in Task 9). The 2.x line moved to `v1`, so a
  # version bump here is not a version bump — it is an API contract change that
  # would break Task 9 with no error at the pin site. Verified 2026-09-26: 0.9.11
  # exists (appVersion v0.9.11); current upstream is 2.11.0.
  version = "0.9.11"

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
