resource "random_password" "root_token" {
  length  = 32
  special = false # the token is passed through env vars and kubectl exec
}

resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = var.chart_version

  namespace = var.namespace

  # OpenTofu owns every namespace (see the Global Constraint). Without this
  # line a chart that defaults to creating its own namespace races the
  # `module.namespaces` for_each for the same object, and the two tools then
  # disagree about who owns it.
  create_namespace = false
  timeout          = var.timeout

  values = concat(
    # `var.values_file` is a path RELATIVE TO THE OpenTofu working directory
    # (`tofu/`), not to this module. The brief's spelling —
    # `file("${path.module}/../../helm/values/vault.yaml")` — is a hard error
    # at validate, verified here before anything was applied:
    #
    #   Error: Invalid function argument
    #     on modules/vault/main.tf line 22, in resource "helm_release" "vault"
    #   Invalid value for "path" parameter: no file exists at
    #   "modules/vault/../../helm/values/vault.yaml"; this function works only
    #   with files that are distributed as part of the configuration source
    #   code.
    #
    # `file()` refuses a relative path built from `path.module` because
    # `path.module` is itself relative to the root module. The repo already
    # solved this twice — `module "prometheus"` (Task 8) and `module "argocd"`
    # (Task 6) — the same way: the caller names the path. The fix is not to
    # move helm/values/vault.yaml into the module, because `make validate`
    # reads that exact path at the repo root and a second copy would be a third
    # place to keep the chart's values right.
    [file(var.values_file)],
    # Only the root token is machine-specific, so only the root token is
    # overlaid here. `server.dev.enabled: true` is NOT set from this module: it
    # is a posture decision, not a per-run value, and it belongs in
    # `helm/values/vault.yaml` where a reader can see it without evaluating
    # OpenTofu. Adding `enabled` to this `yamlencode` would work and would be
    # worse — it would move the one key that decides whether Vault starts in
    # dev mode out of the file anyone actually opens when Vault misbehaves.
    #
    # The fact that `module.local.vault_dev_mode` exists in
    # `tofu/environments/local/overrides.tf:14` and is deliberately NOT read
    # here is worth naming, because an unread override looks like an oversight.
    # Wiring it would mean `server.dev.enabled = module.local.vault_dev_mode`,
    # which puts the mode decision in a file nobody opens when Vault misbehaves
    # and leaves `helm/values/vault.yaml` free to be edited into a state that
    # no longer matches the cluster. See docs/runbooks/vault-secrets.md.
    [yamlencode({
      server = {
        dev = { devRootToken = random_password.root_token.result }
      }
    })],
  )

  depends_on = [var.namespace_dependency]
}

resource "local_file" "root_token" {
  filename             = "${path.module}/../../../local-secrets/vault-root-token"
  content              = random_password.root_token.result
  file_permission      = "0600"
  directory_permission = "0700"
}

# The ClusterSecretStore is applied as a manifest because the operator
# reconciles it — declaring it with kubernetes_manifest keeps it visible in
# plan output instead of hiding it in a post-apply kubectl call.
#
# It depends on module.external_secrets because `kubernetes_manifest` resolves
# the GVK against the LIVE API at PLAN time, not at apply time. On a cluster
# where external-secrets.io/v1beta1 is not yet installed, this resource fails
# the whole plan with "API did not recognize GroupVersionKind" before any
# apply-time ordering is considered — the same wall `module.argocd`'s
# bootstrap_application hit, and the reason `make deploy-infra` has a
# `bootstrap-argocd` leg. It needs no such leg here: the CRD is installed by
# module.external_secrets, which is in the same apply, and the dependency below
# is enough because the plan that matters runs against a cluster where Task 4
# has already been applied.
resource "kubernetes_manifest" "cluster_secret_store" {
  manifest = yamldecode(file("${path.module}/cluster-secret-store.yaml"))

  depends_on = [var.external_secrets_dependency]
}

# The token External Secrets uses to authenticate to Vault. This module is the
# ONLY writer of this object. An earlier draft of the plan also declared it in
# `tofu/modules/external_secrets`, gated behind a `count` so it stayed dormant —
# two resources with one name in two modules, invisible until a caller passed the
# token, at which point OpenTofu reported a perpetual diff naming neither. That
# resource and its `vault_token` variable are gone; see the note in that
# module's `main.tf`. Do not re-add a second writer here to "share" the secret:
# one object, one owner.
resource "kubernetes_secret" "vault_creds" {
  metadata {
    name      = "external-secrets-vault-creds"
    namespace = "external-secrets"
  }
  data = {
    token = random_password.root_token.result
  }

  depends_on = [var.external_secrets_dependency]
}
