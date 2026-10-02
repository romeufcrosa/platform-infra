# The container registry. No Helm chart: this module declares the workload
# directly, the same shape as the Task 7 Ministack module.
#
# ONE OWNER (Ruling R29b). The Deployment, the Service, the pull secret and the
# patched default ServiceAccounts are declared here and ONLY here. The GitOps
# mirror lives in `kubernetes/registry/`, a base that no Application points at in
# Phase 1 — precisely so the representation exists without becoming a second
# owner of a live object.
#
# There is deliberately no `data` block reading a `registry` Service in
# kube-system. Task 2 dropped the minikube `registry` addon because its backing
# image `gcr.io/k8s-minikube/kube-registry-proxy:0.0.6` was deleted upstream
# (minikube/k8s-minikube#21452), so that Service does not exist and the lookup
# would fail at plan with an error naming a data source and nothing else. Do
# not "restore" it.
locals {
  # One label set, used by the Deployment, its pod template and the Service
  # selector. A Service whose selector does not match its pods' labels produces
  # an endpoint-less Service, and the only symptom is `connection refused` from
  # a later `docker push` — with nothing in the message pointing at the
  # Deployment.
  labels = {
    "app.kubernetes.io/name"    = "registry"
    "app.kubernetes.io/part-of" = "platform-learning-ecosystem"
  }
}

resource "kubernetes_deployment" "registry" {
  metadata {
    name      = "registry"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    # One replica. A local registry on a disposable single-node cluster (ADR
    # 0002) has no availability target to meet, and a second replica with no
    # shared storage is a second copy of the same images, not redundancy.
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "registry"
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        container {
          name = "registry"

          # Pinned (Global Constraint) — never `:latest`. The tag arrives from
          # the root's `registry_image` variable via `split(":", ...)[1]`; the
          # repository is a literal because `registry` IS the upstream's
          # identity, not something a caller should be able to point elsewhere.
          image = "registry:${var.image_tag}"

          port {
            name           = "registry"
            container_port = 5000
          }

          # The registry answers /v2/ with a 200 once it is serving. There is no
          # dedicated health endpoint in the 2.x image; /v2/ is the
          # API-version probe the registry itself documents.
          readiness_probe {
            http_get {
              path = "/v2/"
              port = 5000
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          liveness_probe {
            http_get {
              path = "/v2/"
              port = 5000
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          # No PVC, deliberately. Everything pushed here is gone the moment the
          # cluster is deleted (ADR 0002), so a volume would buy a slow first
          # apply and a StorageClass dependency for data nobody can still want
          # afterwards.
          volume_mount {
            name       = "storage"
            mount_path = "/var/lib/registry"
          }
        }

        volume {
          name = "storage"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [var.namespace_dependency]
}

# ClusterIP, not NodePort: the host reaches the registry through the
# `registry/registry 5000:5000` forward in `scripts/port-forwards.sh`, exactly
# as it reaches Grafana, Prometheus, ArgoCD and Ministack. A NodePort would be
# a second, differently-configured path to the same Service.
resource "kubernetes_service" "registry" {
  metadata {
    name      = "registry"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    type = "ClusterIP"
    selector = {
      "app.kubernetes.io/name" = "registry"
    }
    port {
      name = "registry"
      # Both sides are the literal 5000, not the named port: a `target_port`
      # name resolves against the pod template's container port and a mismatch
      # yields a Service with no working endpoints.
      port        = 5000
      target_port = 5000
    }
  }

  depends_on = [kubernetes_deployment.registry]
}

resource "kubernetes_secret" "pull_secret" {
  for_each = toset(var.namespaces)

  metadata {
    name      = "registry-pull-secret"
    namespace = each.value
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      # Both keys are needed and neither is redundant. The kubelet matches a
      # pull secret against the *image reference's registry host*, and the same
      # image is referenced two ways in this plan: `localhost:5000/...` from
      # `docker push` on the host, and `registry.registry.svc:5000/...` from
      # in-cluster workloads. A secret carrying only one key works for pushes
      # and then fails every in-cluster pull with a bare `401 Unauthorized`
      # that names the image and not the missing `auths` entry.
      #
      # The credentials are `platform:platform` and the registry Deployment runs
      # **no auth at all** — the 2.x image has no `htpasswd` mounted. These
      # entries are therefore inert today: they exist so that the moment auth
      # is switched on, the secret is already correct. Do not read the absence
      # of a 401 as proof the entries are being used.
      #
      # This is not a secret value (Global Constraint): `platform:platform`
      # authenticates nothing, because nothing checks it.
      auths = {
        "localhost:5000" = {
          username = "platform"
          password = "platform"
          auth     = base64encode("platform:platform")
        }
        "registry.registry.svc:5000" = {
          username = "platform"
          password = "platform"
          auth     = base64encode("platform:platform")
        }
      }
    })
  }

  depends_on = [var.namespace_dependency]
}

# The pull secret only reaches pods that USE the `default` ServiceAccount —
# creating a Secret makes it available but does not attach it to anything. This
# resource is what makes "a pull secret in every platform namespace" true in
# effect rather than merely in existence.
resource "kubernetes_default_service_account" "registry_pull" {
  for_each = toset(var.namespaces)

  metadata {
    name      = "default"
    namespace = each.value
  }

  image_pull_secret {
    # Keyed by `each.key`, not `[0]`. The secret is a `for_each` over the
    # namespaces, so it is a map keyed by namespace name; `pull_secret[0]` is
    # an index into a map and fails at plan with "Invalid index". The patch
    # lives in the same namespace as the secret it points at, so the key is the
    # one already in scope.
    name = kubernetes_secret.pull_secret[each.key].metadata[0].name
  }

  depends_on = [var.namespace_dependency]
}