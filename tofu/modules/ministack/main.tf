locals {
  # One label set, used by the Deployment, its pod template and the Service
  # selector. A Service whose selector does not match its pods' labels produces
  # an endpoint-less Service and an error that only shows up as "connection
  # refused" from the queue bootstrap Job minutes later — so the selector is
  # written as a literal here rather than derived, and `app.kubernetes.io/name`
  # is the only key it depends on.
  labels = {
    "app.kubernetes.io/name"    = "ministack"
    "app.kubernetes.io/part-of" = "platform-learning-ecosystem"
  }

  # The bootstrap Job runs in `platform-system`, not in `var.namespace`.
  # Two reasons, both verified:
  #
  #   * `platform-system` is where the GitOps base lives, so the mirror
  #     manifest and the imperative resource agree on where the Job is.
  #   * The Job is a one-shot task, not part of the emulated service. Putting
  #     it in the `ministack` namespace would make `kubectl -n ministack delete
  #     ns` a way to orphan a completed Job record.
  #
  # The ServiceAccount it references therefore has to exist in this namespace,
  # which is why the ServiceAccount below is declared against
  # `var.bootstrap_namespace` and not `var.namespace`.
  endpoint = "http://ministack.${var.namespace}.svc.cluster.local:4566"

  # The Job's script lives in a local rather than inline in the `command`
  # argument, because an HCL heredoc cannot be an element of a list literal —
  # `command = ["/bin/sh", "-c", <<-EOT ... EOT]` is a hard
  # `Missing item separator` parse error, verified 2026-09-28.
  #
  # This text is mirrored in kubernetes/platform-system/platform/ministack.yaml.
  # The two must stay identical apart from `${local.endpoint}` and
  # `${join(" ", var.queues)}` being resolved here rather than written out
  # there. `make validate` kustomize-builds the mirror on every run, but no
  # check compares the two bodies — see the report's follow-ups.
  bootstrap_script = <<-EOT
    set -eu
    EP="${local.endpoint}"
    echo "waiting for $EP"
    until curl -sf "$EP/_ministack/health" >/dev/null 2>&1; do
      sleep 2
    done
    for q in ${join(" ", var.queues)}; do
      echo "ensuring queue: $q"
      aws --endpoint-url "$EP" sqs create-queue --queue-name "$q" \
        --attributes VisibilityTimeout=30 >/dev/null || \
        echo "queue $q already exists"
    done
    aws --endpoint-url "$EP" sqs list-queues
  EOT
}

# --- The workload itself -------------------------------------------------
#
# There is no `helm_release` here and no `helm/values/ministack.yaml`, and that
# is not an oversight. Verified 2026-09-28:
#
#   $ curl -s -o /dev/null -w '%{http_code}' https://ministack.github.io/ministack-helm/index.yaml
#   404
#
# No Helm chart for Ministack is published anywhere; a `helm_release` would fail
# at `tofu apply` with a repository-not-found error. The image is
# `ministackorg/ministack` (Docker Hub) — not `ghcr.io/ministack/ministack`,
# which is the wrong organisation and the wrong version scheme. Tag `1.5.17`
# verified present on Docker Hub with linux/amd64 and linux/arm64 manifests.
#
# This is the same class of upstream breakage that made Task 2 drop the
# minikube `registry` addon. A three-line Deployment is the part of the system
# that does not break when upstream does.

resource "kubernetes_deployment" "ministack" {
  metadata {
    name      = "ministack"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    # One replica, and deliberately not wired to
    # local.local_overrides["ministack_replica_count"]: a single emulated
    # gateway cannot be scaled horizontally behind one ClusterIP, so a replica
    # count above 1 would produce a Service whose requests are load-balanced
    # across N Ministack processes that do not share queue state. The override
    # exists (Task 3) and stays unwired; that is a real limitation, recorded
    # rather than papered over with a knob that only breaks.
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "ministack"
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        container {
          name = "ministack"

          # The tag arrives as an input so the Global Constraint ("no :latest")
          # is enforced in exactly one place — the root's `ministack_image`
          # variable, which splits on ":" — while the repository is a literal
          # here. The registry and org are part of the upstream's identity, not
          # something a caller should be able to point elsewhere.
          image = "ministackorg/ministack:${var.image_tag}"

          port {
            name           = "gateway"
            container_port = 4566
          }

          # Verified 2026-09-28 against the pinned image: 4566 is the only
          # port, and this health path returns 200 with a per-service
          # availability map. Anything else and the probe would be a guess.
          readiness_probe {
            http_get {
              path = "/_ministack/health"
              port = "gateway"
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          liveness_probe {
            http_get {
              path = "/_ministack/health"
              port = "gateway"
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
          }
        }
      }
    }
  }

  depends_on = [var.namespace_dependency]
}

# The Service exists only for the queue bootstrap Job and the in-cluster
# endpoint the Task 9 secret contract publishes; the host reaches Ministack
# through `make port-forwards`, so ClusterIP is enough and no NodePort is
# opened.
resource "kubernetes_service" "endpoint" {
  metadata {
    name      = "ministack"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    type = "ClusterIP"
    selector = {
      "app.kubernetes.io/name" = "ministack"
    }
    port {
      name = "gateway"
      # Both sides are the literal 4566, not the named port: `target_port` as a
      # name resolves against the pod template's container port, and a name that
      # does not match there yields a Service with no working endpoints.
      port        = 4566
      target_port = 4566
    }
  }

  depends_on = [kubernetes_deployment.ministack]
}

# --- Queue bootstrap -----------------------------------------------------
#
# The queues exist as Kubernetes objects, not as a host script someone ran.
# A Job makes the desired queue set declarative and re-runnable.

resource "kubernetes_service_account" "bootstrap" {
  metadata {
    name      = "ministack-bootstrap"
    namespace = var.bootstrap_namespace
    labels    = local.labels
  }
}

# THERE IS NO Role/RoleBinding, AND THAT IS A DELIBERATE DEPARTURE FROM THE
# BRIEF. The brief says to add "a Role/RoleBinding granting `sqs:*`". There is
# no Kubernetes resource that can express that grant, and writing one anyway
# would be actively misleading.
#
# Ministack is reached over plain HTTP by an AWS CLI process — not through the
# Kubernetes API. The Job calls no AWS IAM operation, so Kubernetes RBAC has
# nothing to gate. Verified 2026-09-28, against the pinned emulator, with
# deliberately fake credentials and no IAM check anywhere in the path:
#
#   AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
#     aws --endpoint-url http://... sqs create-queue --queue-name order-events
#   -> {"QueueUrl": "http://.../000000000000/order-events"}     exit 0
#
# S3 PutObject/GetObject and Secrets Manager CreateSecret/GetSecretValue were
# exercised the same way (see docs/runbooks/ministack-api-coverage.md).
#
# So a Role here would be a wildcard grant in a PUBLIC repository's history,
# attached to a ServiceAccount that provably cannot use it, that a future
# reader would trust as load-bearing. This project has already recorded the
# principle it applies to unused Helm inputs — "an input that does nothing is
# worse than a missing one because the next reader cannot tell it apart from a
# bug" (tofu/modules/ministack/variables.tf). A permission is worse: it looks
# like security. If the Job ever breaks, this absence is not the reason.
#
# The ServiceAccount below is still declared, because the Job's
# `serviceAccountName` references it and omitting it would leave the pod
# running as `default`.

resource "kubernetes_job" "bootstrap" {
  metadata {
    name      = "ministack-bootstrap"
    namespace = var.bootstrap_namespace
    labels    = local.labels
  }

  spec {
    backoff_limit = 6

    # The Job deletes itself an hour after completing, and OpenTofu recreates
    # it on the next apply. That is the intended re-runnability, not a bug:
    # the ensure loop below is idempotent, so a re-run is a no-op that still
    # proves the endpoint is reachable. The cost is that `tofu plan` shows a
    # create for this Job once the TTL has expired. That is a real, expected
    # diff and it is a better trade than a completed Job that never re-checks.
    ttl_seconds_after_finished = 3600

    template {
      metadata {
        labels = local.labels
      }

      spec {
        restart_policy       = "OnFailure"
        service_account_name = kubernetes_service_account.bootstrap.metadata[0].name

        container {
          name  = "aws-cli"
          image = var.bootstrap_image

          # THE AWS CLI NEEDS A REGION *AND* CREDENTIALS, AND THE BRIEF SET
          # NEITHER. This is the defect that made this Job unrunnable, so it
          # is documented at length rather than quietly fixed.
          #
          # Verified 2026-09-28 inside this exact image:
          #
          #   $ docker run --rm public.ecr.aws/aws-cli/aws-cli:2.17.0 \
          #       aws --endpoint-url http://... sqs list-queues
          #   You must specify a region. You can also configure your region
          #   by running "aws configure".
          #
          #   $ docker run --rm -e AWS_DEFAULT_REGION=us-east-1 \
          #       public.ecr.aws/aws-cli/aws-cli:2.17.0 aws ... sqs list-queues
          #   Unable to locate credentials. You can also configure your
          #   credentials by running "aws configure".
          #
          # In a cluster pod there is no ~/.aws and no IRSA, so *both* are
          # absent. Every `aws` call in the brief's script fails, and the
          # failure is then hidden: the create loop ends in
          # `|| echo "queue $q already exists"`, which under `set -e` swallows
          # a non-zero exit and prints a reassuring falsehood. The Job would
          # report "queue order-events already exists" three times having
          # created nothing.
          #
          # The only thing that fails is the final, unguarded `list-queues`, so
          # the Job goes red — but the log would blame the wrong thing
          # entirely. These three values are the standard fake credentials for
          # a local emulator and are not secrets (Global Constraint: no secret
          # *value* in a committed file — `test`/`test` authenticates nothing
          # and authorises nothing; verified, every operation below succeeds
          # with them).
          env {
            name  = "AWS_DEFAULT_REGION"
            value = "us-east-1"
          }
          env {
            name  = "AWS_ACCESS_KEY_ID"
            value = "test"
          }
          env {
            name  = "AWS_SECRET_ACCESS_KEY"
            value = "test"
          }
          # Silences the CLI's update pings; keeps Job logs to the thing that
          # matters.
          env {
            name  = "AWS_PAGER"
            value = ""
          }

          # `curl` is confirmed present in this image (verified 2026-09-28,
          # /usr/bin/curl 8.3.0), so the wait loop below needs no second image
          # and no custom entrypoint.
          command = ["/bin/sh", "-c", local.bootstrap_script]
        }
      }
    }
  }

  depends_on = [kubernetes_service.endpoint]
}
