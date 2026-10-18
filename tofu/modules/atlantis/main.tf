resource "random_password" "encryption_key" { length = 32 special = false }
resource "random_password" "github_token" {
  length  = 40
  special = false
  # Prefer the PAT from the environment over a generated value: Atlantis
  # needs a real credential to talk to GitHub.
  keepers = { source = var.github_pat }
}
resource "random_password" "webhook_secret" { length = 32 special = false }

locals {
  github_token = var.github_pat != "" ? var.github_pat : random_password.github_token.result
}

resource "kubernetes_secret" "atlantis" {
  metadata {
    name      = "atlantis-secrets"
    namespace = var.namespace
  }
  data = {
    github_token   = local.github_token
    encryption_key = random_password.encryption_key.result
    webhook_secret = random_password.webhook_secret.result
  }
  depends_on = [var.namespace_dependency]
}

resource "helm_release" "atlantis" {
  name       = "atlantis"
  repository = "https://runatlantis.github.io/helm-charts"
  chart      = "atlantis"
  version    = "6.16.0"   # ships appVersion v0.48.0; see the divergence table

  namespace = var.namespace

  # OpenTofu owns every namespace (see the Global Constraint). Without this
  # line a chart that defaults to creating its own namespace races the
  # `module.namespaces` for_each for the same object, and the two tools then
  # disagree about who owns it.
  create_namespace = false
  timeout   = var.timeout

  values = concat(
    [file("${path.module}/../../helm/values/atlantis.yaml")],
    [yamlencode({
      # Server-side repo config is a top-level inline YAML string in this
      # chart, and there is no key anywhere in the 6.x line that points it at
      # a Secret instead. The contents come from the *rendered* repo-root
      # atlantis.yaml, not the .tftpl: reading the generated file rather than
      # re-rendering here is what keeps the repo identity in one place. The
      # root decides which repo, and the module ships whatever config the root
      # produced.
      repoConfig = file("${path.module}/../../atlantis.yaml")

      # Read the PAT and the webhook secret from a Secret we already own,
      # rather than passing them as values. The chart's own template stores
      # whatever it is given in the release's stored values, which are
      # plaintext base64 in the namespace; the Secret is not. `vcsSecretName`
      # also tells the chart to skip creating its own webhook Secret, so
      # there is exactly one copy of each value in the cluster.
      vcsSecretName = kubernetes_secret.atlantis.metadata[0].name

      # Atlantis reads the encryption key from the pod environment, not from
      # a values key — there is no `encryption` key anywhere in the chart, and
      # `encryption` block in a values file would be rejected by the chart's JSON
      # schema outright. environmentSecrets is the documented shape
      # ({name, secretKeyRef:{name, key}}), which is what the encryption_key
      # entry above exists for.
      environmentSecrets = [{
        name = "ATLANTIS_ENCRYPTION_KEY"
        secretKeyRef = {
          name = kubernetes_secret.atlantis.metadata[0].name
          key  = "encryption_key"
        }
      }]
    })],
  )

  depends_on = [kubernetes_secret.atlantis]
}

resource "local_file" "webhook_secret" {
  filename             = "${path.module}/../../../local-secrets/atlantis-webhook-secret"
  content              = random_password.webhook_secret.result
  file_permission      = "0600"
  directory_permission = "0700"
}
