# --- The admin password: generate once, persist, read back -----------------
#
# The chart does not take a plaintext admin password. `configs.secret
# .argocdServerAdminPassword` is a **bcrypt hash** — the chart says so twice
# (values.yaml:536-539, "Bcrypt hashed admin password", and README.md:706).
# A plaintext value renders without complaint, lands in argocd-secret, and
# then fails to authenticate at the login prompt.
#
# The non-obvious half: OpenTofu's `bcrypt()` salts randomly, so calling it
# inline produces a DIFFERENT hash on every plan. The chart's stored admin
# password would change on every apply, and the password handed to the reader
# would be wrong by the next one. So the hash is computed once and persisted,
# and read back whenever it already exists.
locals {
  # The same gitignored directory Task 9 writes the Vault root token into and
  # Task 10 writes the Atlantis webhook secret into. One `local-secrets/`, not
  # a second one — the .gitignore rule and the runbooks both name that path.
  #
  # The path arrives through `var.local_secrets_dir` rather than an inline
  # `path.module` expression because `file()`/`fileexists()` are confined to
  # the OpenTofu root module and `local-secrets/` is above it. Read
  # variables.tf before changing either of these back to a literal.
  #
  # `abspath()` because `local_file.filename` echoes back whatever it is given,
  # and the `password_file` output would otherwise be the relative string
  # `../local-secrets/argocd-admin-password` — meaningless to every consumer
  # that is not OpenTofu running from `tofu/`.
  local_secrets_dir = abspath(var.local_secrets_dir)

  admin_pw_plain_file = "${local.local_secrets_dir}/argocd-admin-password"
  admin_pw_hash_file  = "${local.local_secrets_dir}/argocd-admin-password.bcrypt"
}

resource "random_password" "argocd_admin" {
  length  = 32
  special = false # avoid shell-quoting hazards in kubectl exec one-liners

  # After the first apply the two files above are the source of truth, so a
  # re-rolled `result` would change nothing — but it would still show up as a
  # permanent diff on every subsequent plan, and a plan that always shows a
  # diff is a plan nobody reads. Freezing it keeps the run clean.
  lifecycle {
    ignore_changes = [result]
  }
}

locals {
  # Plaintext, in the order it is looked for: the persisted file, then the
  # caller's override, then the generated password. `var.admin_password`
  # (root `var.argocd_admin_password`) seeds a fresh checkout exactly once;
  # after that it is inert, deliberately. A variable that re-hashed on every
  # plan would reintroduce precisely the churn this shape exists to stop.
  admin_password_plain = (
    fileexists(local.admin_pw_plain_file)
    ? trimspace(file(local.admin_pw_plain_file))
    : var.admin_password != ""
    ? var.admin_password
    : random_password.argocd_admin.result
  )

  admin_password = (
    fileexists(local.admin_pw_hash_file)
    ? trimspace(file(local.admin_pw_hash_file))
    : bcrypt(local.admin_password_plain)
  )
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  # Pinned — Global Constraint. Chart 6.7.x renders ArgoCD 2.10.x natively
  # (6.7.18 -> appVersion v2.10.9), matching the v2.10.9 image tag in
  # helm/values/argocd.yaml. Verified present in argo/argo-helm 2026-09-26.
  version = var.chart_version

  namespace = var.namespace

  # OpenTofu owns every namespace (see the Global Constraint). Without this
  # line a chart that defaults to creating its own namespace races the
  # `module.namespaces` for_each for the same object, and the two tools then
  # disagree about who owns it.
  create_namespace = false

  timeout = var.timeout

  values = [file(var.values_file)]

  set {
    # The FLAT key. The nested spelling that reads naturally —
    # `configs.secret.argocdServer`, then `admin`, then `password` — is not
    # this chart's key. The secret template tests the flat one
    # (templates/argocd-configs/argocd-secret.yaml:41-43), so the nested
    # spelling is dropped without an error and the rendered argocd-secret
    # comes out with NO `admin.password` entry at all. ArgoCD then comes up
    # with an admin login that nobody can use, and nothing in `tofu apply`,
    # `helm list`, or the pod logs says why.
    #
    # The value is the bcrypt hash, not the plaintext — see the locals above.
    name  = "configs.secret.argocdServerAdminPassword"
    value = local.admin_password
  }
  set {
    # The dots after `server` are ESCAPED, and they have to be. The Helm
    # Terraform provider splits `set.name` on `.` and rebuilds a nested map,
    # so the unescaped form of this same name becomes
    # `{configs:{params:{server:{insecure:true}}}}` — junk in the params
    # ConfigMap — while the key the chart actually wants stays at its `false`
    # default (values.yaml:245 spells it `server.insecure: false`, a literal
    # key with a dot in the name). argocd-server reads that ConfigMap key
    # (argocd-server/deployment.yaml, via the ARGOCD_SERVER_INSECURE env var
    # sourced from configMapRef argocd-cmd-params-cm), so `ARGOCD_SERVER_INSECURE`
    # stays "false": the exact opposite of the intent, silently. The
    # unescaped form is the one a reader expects to see, and it is the one
    # that is wrong.
    name  = "configs.params.server\\.insecure"
    value = "true" # localhost port-forward only; see runbook
  }
  set {
    # The other half of the ServiceMonitor ordering fix. The `false` in
    # helm/values/argocd.yaml is what makes this a real toggle: Task 8 sets
    # the variable to true only after kube-prometheus-stack has installed the
    # CRD the chart's ServiceMonitor template gates on, and a value that was
    # already true by default would leave nothing to flip.
    name  = "server.metrics.serviceMonitor.enabled"
    value = tostring(var.enable_service_monitor)
  }

  depends_on = [var.namespace_dependency]
}

# The plaintext is what a human needs in order to log in; the hash is what the
# chart gets. Both live under the gitignored local-secrets/ (Global
# Constraint: no secret value in any committed file).
resource "local_file" "admin_password" {
  filename             = local.admin_pw_plain_file
  content              = local.admin_password_plain
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "local_file" "admin_password_hash" {
  filename             = local.admin_pw_hash_file
  content              = local.admin_password
  file_permission      = "0600"
  directory_permission = "0700"
}

# **There is deliberately no "initial admin" Secret here.** ArgoCD reads a
# Secret by that name exactly once, at first boot, and then never again — the
# chart's own NOTES.txt:15 tells you to delete it afterwards. A bootstrap that
# cannot be repeated is a second owner racing the chart's supported path to the
# same fact: the chart reads `configs.secret.argocdServerAdminPassword` and
# writes `admin.password` into argocd-secret itself, on every apply, from the
# value above. One path to one secret. The chart's path is the one that survives
# a `tofu destroy`, a `helm upgrade`, and a fresh cluster.

# In-cluster registration of this repo, so the Application in
# argocd/applications/platform-system.yaml can resolve its source.
resource "kubernetes_secret" "repo_secret" {
  metadata {
    name      = "platform-infra-repo"
    namespace = var.namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }
  data = {
    type     = "git"
    url      = var.repo_url
    username = var.repo_username
    password = var.repo_password
  }
}

locals {
  # Rendered ONCE and used twice: the committed file ArgoCD's own repo
  # registration points at, and the live object. `yamldecode` of the same
  # string is what makes them the same manifest rather than two similar ones.
  bootstrap_application_yaml = templatefile(
    "${path.module}/bootstrap-application.yaml.tftpl",
    { repo_url = var.repo_url },
  )
}

resource "local_file" "bootstrap_application" {
  # Rendered over the hand-written placeholder from Task 5 — same path, one
  # file, one owner. It does NOT go in `kubernetes/platform-system/`: that base
  # is what this Application syncs, so an Application living inside it is a
  # self-reference, and the plan has already committed to having none. The
  # `argocd/applications/` kustomization that already exists and that CI
  # already builds (`kubectl kustomize argocd/applications`) references this
  # path, so the rendered file needs no new wiring anywhere.
  filename        = "${path.module}/../../argocd/applications/platform-system.yaml"
  content         = local.bootstrap_application_yaml
  file_permission = "0644"
}

resource "kubernetes_manifest" "bootstrap_application" {
  manifest = yamldecode(local.bootstrap_application_yaml)

  # `depends_on` is correct but NOT SUFFICIENT, and the reason matters because
  # the first apply of this module cannot succeed without knowing it.
  #
  # `kubernetes_manifest` resolves the manifest's GroupVersionKind against the
  # LIVE API at PLAN time — the provider has to build an OpenAPI-backed schema
  # for the object before it can plan a create. If `applications.argoproj.io`
  # is not registered, planning fails with:
  #
  #   Error: API did not recognize GroupVersionKind from manifest
  #     (CRD may not be installed)
  #   no matches for kind "Application" in group "argoproj.io"
  #
  # That is the exact error `depends_on` was supposed to prevent, and it fires
  # on the FIRST apply of a fresh cluster — the one time the CRD is genuinely
  # missing. A plan-time dependency cannot order a plan-time discovery that
  # happens before the dependency is considered; `depends_on` only sequences
  # APPLY, and this failure is in PLAN. Verified against the kubernetes
  # provider 2.38.0 on OpenTofu 1.7.0.
  #
  # So the bootstrap is two applies, and `make deploy-infra` runs them in
  # order. The first is `-target=module.argocd.helm_release.argocd`, which
  # installs the chart and therefore the CRDs, and is a no-op once they are
  # there; the second is the ordinary full apply, whose plan now resolves
  # `Application` fine. This edge is a property of the provider, not of this
  # module, so no value or ordering inside the module removes it.
  depends_on = [helm_release.argocd]
}
