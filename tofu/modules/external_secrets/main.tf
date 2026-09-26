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

# NOTE: this module does NOT create the `external-secrets-vault-creds` secret,
# and must not gain one.
#
# Task 9 (`tofu/modules/vault`) owns that secret, exactly once. It used to be
# declared here as `kubernetes_secret.es_creds`, gated on
# `count = var.vault_token == "" ? 0 : 1`, and it was a latent conflict rather
# than a working split: same `metadata.name`, same namespace, two modules, two
# OpenTofu resources competing for one Kubernetes object.
#
# The `count` guard hid the collision perfectly. `vault_token` was passed by no
# call site, so `es_creds` sat at count 0 and the plan stayed clean — until the
# one caller that sets it arrives, at which point two resources fight over one
# object (perpetual diff, or "Provider produced inconsistent result after
# apply" depending on ordering).
#
# The underlying reason the secret cannot live here: a Vault root token does
# not exist until Vault does, and Vault is Task 9. A count guard is the wrong
# tool for expressing "the value does not exist yet" — it defers the
# disagreement instead of removing it. Task 9 has the real token
# (`random_password.root_token.result`) and therefore the real writer.
