# Root module. Each component is added by its own task, in this order:
#   0. minikube_addons   (Task 3 — asserts the baseline; no resources)
#      local overrides   (Task 3 — the live deviation file)
#   1. namespaces        (Task 4)
#   2. external-secrets  (Task 4)
#   3. argocd            (Task 6)
#   4. ministack         (Task 7)
#   5. registry+prometheus (Task 8)
#   6. vault             (Task 9)
#   7. atlantis          (Task 10)
#
# OpenTofu resolves the dependency graph from the references between
# modules; the comment records intent, the references enforce it.
#
# The `terraform { required_version / required_providers }` block lives in
# versions.tf. Note that it is spelled `terraform`, not `tofu`: OpenTofu 1.7.0
# (the pin) does not accept a `tofu` block — that alias arrived in 1.8.0 and
# errors here as "Blocks of type \"tofu\" are not expected here". The Global
# Constraint against `terraform` is about the *binary invoked*, not the HCL
# block name. Verified 2026-09-26.

# Asserts the addon baseline (ingress, metrics-server). It creates NO
# resources — it exists so Task 2's `check` block actually evaluates. Before
# this module block was added, nothing referenced minikube_addons, so the check
# never ran and `tofu plan` showed no addon assertion at all: the drift signal
# was switched off.
#
# A failed `check` is a WARNING, not an error — `tofu plan` still exits 0. Do
# not write CI that treats this exit code as a gate. Anything that must
# hard-fail belongs in a resource `precondition` or in a shell script.
module "minikube_addons" {
  source = "./modules/minikube_addons"

  addons = ["ingress", "metrics-server"]
}

# The local environment profile. This is a real module, not a directory of
# comments: `locals` do not cross a module boundary, so
# environments/local/outputs.tf re-exports each override as a module output and
# the component modules read them from here.
#
# The root consumes these via `local_overrides` below, which is what makes the
# Phase 1 Atlantis exit criterion satisfiable: editing overrides.tf must show up
# in a plan. Were this module absent, that PR would produce an empty plan and
# the criterion would silently prove nothing.
module "local" {
  source = "./environments/local"
}

locals {
  environment = var.environment

  # SINGLE SOURCE OF TRUTH for every namespace in the platform.
  # Task 4 drives the namespace module's `for_each` from this list, and the
  # `namespaces` output below is derived from it, so the verify script reads
  # the same names. Declared in Task 3 rather than Task 4 so the names are
  # fixed before any task consumes them — the one thing later tasks cannot
  # recover. ADR-0002 makes this list authoritative; the Makefile's
  # NAMESPACES is a non-authoritative human-readable mirror.
  platform_namespaces = [
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

  common_labels = {
    "app.kubernetes.io/part-of"    = "platform-learning-ecosystem"
    "app.kubernetes.io/managed-by" = "opentofu"
    "platform.environment"         = var.environment
  }

  # Every value the local environment profile deviates on, collected in one map.
  #
  # This local is the consuming reference that makes `module "local"` more than
  # a declared-but-unwired module. Components in Tasks 7-10 read
  # `local.local_overrides["<key>"]`.
  #
  # NOTE: there is deliberately NO `check` block here asserting that these keys
  # match the module's output names. OpenTofu 1.7 cannot enumerate a module's
  # output names, so the only available expression compares this map's keys to
  # itself — a tautology that can never fire, and an untested check is worse
  # than none. The key-set agreement is instead verified by
  # scripts/check-local-overrides.sh, which diffs the two files' keys. See
  # task-3-report.md, "Declared-but-not-wired audit".
  local_overrides = {
    vault_dev_mode                 = module.local.vault_dev_mode
    prometheus_retention           = module.local.prometheus_retention
    prometheus_persistence_enabled = module.local.prometheus_persistence_enabled
    atlantis_replica_count         = module.local.atlantis_replica_count
    ministack_replica_count        = module.local.ministack_replica_count

    # Read by `module "argocd"` below. scripts/check-local-overrides.sh requires
    # every key in environments/local/outputs.tf to appear here, so this is not
    # optional bookkeeping.
    argocd_service_monitor_enabled = module.local.argocd_service_monitor_enabled
  }
}

# `local.platform_namespaces` is NOT re-declared here. It already exists above,
# from Task 3, and it has to: the namespace list is fixed *before* any namespace
# is created, because that is the one decision a later task cannot recover if it
# turns out wrong. Declaring it a second time in a second `locals` block is a hard
# HCL error — `Duplicate local value definition` / `Attribute redefined` — so the
# cluster would not come up at all.
#
# Task 4 adds the two `module` blocks below and nothing else to `tofu/main.tf`. The
# list itself is unchanged: all eleven names, platform eight plus `dev`, `staging`,
# `prod`. The application namespaces are created here rather than waiting for ArgoCD
# to sync the Kustomize manifests, so `make verify` has a deterministic cluster to
# check immediately after `tofu apply` instead of racing a GitOps sync.
module "namespaces" {
  source   = "./modules/namespace"
  for_each = toset(local.platform_namespaces)

  name = each.key
  # An application namespace is labelled with its own name; a platform namespace
  # is labelled `local`. This is what the verify script and the ArgoCD AppProjects
  # key off.
  environment = contains(["dev", "staging", "prod"], each.key) ? each.key : local.environment
  labels      = local.common_labels
}

module "external_secrets" {
  source    = "./modules/external_secrets"
  namespace = "external-secrets"
  timeout   = var.helm_timeout

  depends_on = [module.namespaces]
}

module "argocd" {
  source = "./modules/argocd"

  namespace      = "argocd"
  timeout        = var.helm_timeout
  admin_password = var.argocd_admin_password
  repo_url       = var.platform_infra_repo_url
  repo_password  = var.github_pat

  # Only true from Task 8 onward: the argocd chart gates its ServiceMonitor
  # template on the monitoring.coreos.com/v1 CRD existing at render time, and
  # that CRD arrives with kube-prometheus-stack.
  enable_service_monitor = module.local.argocd_service_monitor_enabled

  # module.prometheus joins module.namespaces for the same reason: a
  # ServiceMonitor is worth nothing until the CRD exists, and without the
  # ordering constraint one `tofu apply` can render the ArgoCD release before
  # Prometheus is installed — the race Task 6 was repaired to avoid, arriving
  # from the other direction.
  depends_on = [module.namespaces, module.prometheus]
}

# kube-prometheus-stack. The chart renders 80 objects, which is why none of them
# are re-declared in the GitOps base.
module "prometheus" {
  source = "./modules/prometheus"

  namespace = "monitoring"

  # Pinned at the call site on purpose, even though the module has the same
  # default. Every `module` block in this plan pins its chart version here: a
  # module default that silently upgrades a chart on a future `tofu apply` is
  # how a laptop ends up running a stack version nobody chose, and the Atlantis
  # plan comment is the only place that change would be visible.
  #
  # 65.5.1 (appVersion v0.77.2), read off the live repo with
  # `helm search repo prometheus-community/kube-prometheus-stack --version
  # 65.5.1` on 2026-09-30. The newest published version that day was 91.8.2.
  # helm/values/prometheus.yaml is written against the 65.x schema and is
  # upgraded with the chart in the same commit.
  chart_version = "65.5.1"

  # This is module.local's FIRST real consumer. Until this line existed,
  # `prometheus_retention` in overrides.tf was a local nothing read, editing it
  # produced an empty plan, and the Phase 1 exit criterion ("open a PR editing
  # overrides.tf, read the Atlantis plan comment") would have passed
  # vacuously.
  retention           = module.local.prometheus_retention
  persistence_enabled = module.local.prometheus_persistence_enabled

  timeout              = var.helm_timeout
  namespace_dependency = module.namespaces

  depends_on = [module.local]
}

# The container registry. No Helm chart: the module declares a
# kubernetes_deployment / kubernetes_service / kubernetes_secret, the same shape
# as module "ministack" above.
#
# This completes the picture for Task 2: the minikube `registry` addon was
# dropped there because its backing image
# `gcr.io/k8s-minikube/kube-registry-proxy:0.0.6` was deleted upstream, and
# Task 2 promised the workload would arrive here. It does — created, not
# addressed. Had the addon survived, this module would have had nothing to make
# usable.
module "registry" {
  source = "./modules/registry"

  namespace = "registry"

  # Same one-place pin as Ministack: the tag lives in the root's
  # `registry_image` variable so the Global Constraint is checked by reading one
  # line, and the module receives only the tag. Splitting on ":" is safe because
  # the variable is a fully-qualified `repository:tag` by construction — a
  # caller who passed a digest or a bare tag would get a wrong `image_tag`
  # rather than an error, which is why the default is written out in full.
  image_tag = split(":", var.registry_image)[1]

  # The same list module.namespaces iterates, so "a pull secret in every
  # platform namespace" is true by construction rather than by two lists
  # agreeing. The root's copy of the module.namespaces depends_on is written out
  # rather than inferred, because `namespace_dependency` is `type = any` and
  # OpenTofu cannot read through `any` to discover the ordering on its own.
  namespaces           = local.platform_namespaces
  namespace_dependency = module.namespaces

  depends_on = [module.namespaces]
}

# Ministack has no Helm chart, so this module declares a `kubernetes_deployment`
# and a `kubernetes_service` rather than a `helm_release`. Verified 2026-09-28:
# `https://ministack.github.io/ministack-helm/index.yaml` returns 404 and no
# chart for Ministack is published anywhere, so a `helm_release` here would
# fail at apply with a repository-not-found error. There is deliberately no
# `helm/values/ministack.yaml` for the same reason.
module "ministack" {
  source = "./modules/ministack"

  namespace = "ministack"

  # The pin lives in exactly one place — `var.ministack_image` in Task 3 — so
  # the Global Constraint is checked by reading a single line. Splitting on ":"
  # is safe because the variable is a fully-qualified `repository:tag` by
  # construction; a caller who passed a digest (`@sha256:...`) or a bare tag
  # would get a wrong `image_tag` rather than an error, which is why the default
  # is written out in full rather than assembled.
  #
  # That caveat is not theoretical. Until Task 7 this variable's default was
  # `ghcr.io/ministack/ministack:v0.9.0` — the wrong organisation and a tag
  # that does not exist. The split silently produced `image_tag = "v0.9.0"`,
  # the module rendered `ministackorg/ministack:v0.9.0`, and `tofu plan` exited
  # 0. See the comment on the variable in tofu/variables.tf.
  image_tag = split(":", var.ministack_image)[1]

  # No `timeout` argument: this module installs no chart, so the Helm timeout
  # has nothing to govern. Passing it would suggest the resource has a
  # timeout-sensitive code path it does not have.
  depends_on = [module.namespaces]
}

# Vault. The only module in this plan that carries a `local_file` and writes a
# credential: the root token is generated here, handed to the chart through
# `yamlencode`, and written to local-secrets/ (gitignored) for
# scripts/seed-vault.sh. No token value is ever an output or a committed file.
#
# The chart pin is at the call site for the same reason as every other module
# here: see the long comment on `module "prometheus"`. 0.28.0 is the CHART
# version and ships Vault 1.16.1 — the two number independently.
module "vault" {
  source = "./modules/vault"

  namespace     = "vault"
  chart_version = "0.28.0"
  timeout       = var.helm_timeout

  # Two ordering constraints, and they are for different reasons.
  #
  # 1. The namespace must exist before the chart installs, because
  #    `create_namespace = false` (OpenTofu owns every namespace).
  # 2. The External Secrets Operator must exist before the ClusterSecretStore
  #    and the creds Secret are planned, because `kubernetes_manifest` resolves
  #    the GVK against the live API at PLAN time. Without this, a plan against
  #    a cluster where Task 4 has not been applied fails with "API did not
  #    recognize GroupVersionKind" — the same wall module.argocd hit.
  namespace_dependency        = module.namespaces
  external_secrets_dependency = module.external_secrets

  # Task 10's `module "atlantis"` declares `depends_on = [module.vault]`. Until
  # this block existed that reference pointed at a module that did not exist
  # and Task 10 would have failed `tofu validate` with a "module not found"
  # naming the wrong task.
  depends_on = [module.namespaces, module.external_secrets]
}

# Render the Atlantis repo config from template. The template uses var.atlantis_repo
# which must be set (empty default would produce an invalid config).
resource "local_file" "atlantis_repo_config" {
  filename = "${path.root}/atlantis.yaml"
  content  = templatefile("${path.root}/../atlantis.yaml.tftpl", {
    atlantis_repo = var.atlantis_repo
  })
}

# Atlantis. Task 10: Terraform PR automation via GitHub webhooks.
# Depends on Vault because the Atlantis module reads the webhook secret
# from a Kubernetes Secret that the Vault module creates (in Task 9).
# The chart uses `defaultTFDistribution: opentofu` and `defaultTFVersion`
# pinned to the same version as the root's required_providers.
module "atlantis" {
  source = "./modules/atlantis"

  namespace               = "atlantis"
  timeout                 = var.helm_timeout
  github_pat              = var.github_pat
  github_user             = "local-dev"
  values_file             = "../helm/values/atlantis.yaml"
  repo_config_content     = local_file.atlantis_repo_config.content
  namespace_dependency    = module.namespaces

  depends_on = [module.vault, local_file.atlantis_repo_config]
}

#   8. postgresql        (Task 2 - Phase 2)


# Generate PostgreSQL credentials
resource "random_password" "postgres_user" {
  length  = 16
  special = false
}

resource "random_password" "postgres_password" {
  length  = 16
  special = false
}

resource "local_file" "postgres_user" {
  filename        = "${path.root}/../local-secrets/postgres-user"
  content         = random_password.postgres_user.result
  file_permission = "0600"
}

resource "local_file" "postgres_password" {
  filename        = "${path.root}/../local-secrets/postgres-password"
  content         = random_password.postgres_password.result
  file_permission = "0600"
}

module "postgresql" {
  source      = "./modules/postgresql"
  namespace   = "dev"
  postgres_user = random_password.postgres_user.result
  postgres_password = random_password.postgres_password.result
  postgres_db   = "orders"
  namespace_dependency = module.namespaces
  depends_on   = [module.namespaces]
}
