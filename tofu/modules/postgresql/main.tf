# Install the CloudNativePG operator first to provide CRDs
resource "helm_release" "postgres_operator" {
  name       = "cloudnative-pg"
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  version    = "0.29.1"

  namespace = var.namespace

  # OpenTofu owns every namespace (see the Global Constraint). Without this
  # line a chart that defaults to creating its own namespace races the
  # `module.namespaces` for_each for the same object, and the two tools then
  # disagree about who owns it.
  create_namespace = false

  timeout = var.timeout

  values = [file("${path.module}/../../../helm/values/postgresql.yaml")]
}

# Install the PostgreSQL cluster
resource "helm_release" "postgresql" {
  name       = "postgres-cluster"
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cluster"
  version    = "0.9.0"

  namespace = var.namespace

  # OpenTofu owns every namespace (see the Global Constraint). Without this
  # line a chart that defaults to creating its own namespace races the
  # `module.namespaces` for_each for the same object, and the two tools then
  # disagree about who owns it.
  create_namespace = false

  timeout = var.timeout

  values = [file("${path.module}/../../../helm/values/postgresql.yaml")]

  set {
    name  = "instances"
    value = "1"
  }

  set {
    name  = "storage.size"
    value = "1Gi"
  }

  set {
    name  = "postgresql.username"
    value = var.postgres_user
  }

  set {
    name  = "postgresql.password"
    value = var.postgres_password
  }

  set {
    name  = "postgresql.database"
    value = var.postgres_db
  }


  depends_on = [var.namespace_dependency, helm_release.postgres_operator]
}