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

  # The bootstrap Job runs in `platform-system`, not in `var.namespace`. It is
  # a one-shot task rather than part of the emulated service, and putting it in
  # the `ministack` namespace would make `kubectl -n ministack delete ns` a way
  # to orphan a completed Job record.
  #
  # It is NOT in the GitOps base, and that is deliberate — see the "Queue
  # bootstrap" section below.
  endpoint = "http://ministack.${var.namespace}.svc.cluster.local:4566"

  # The Job's script, read once at plan time from the single master copy that
  # lives beside this file. It is shipped to the pod as a ConfigMap and run
  # from there; nothing about the queue list, the creation order or the redrive
  # wiring is restated in HCL.
  #
  # `file()` rather than `templatefile()`: the same file has to stay directly
  # executable on a developer's machine, and a template would put HCL
  # interpolation syntax into a script that also runs under /bin/sh.
  #
  # The path is inside the module because `file()` cannot read outside it —
  # verified 2026-09-30, `../../scripts/...` fails with "Invalid value for
  # \"path\" parameter ... works only with files that are distributed as part of
  # the configuration source code". `scripts/bootstrap-ministack-queues.sh` is
  # therefore a wrapper that execs this file, not a second copy of it.
  bootstrap_script = file("${path.module}/bootstrap-ministack-queues.sh")
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
#
# ONE OWNER. This Job is declared here and ONLY here. It was briefly also in
# kubernetes/platform-system/platform/ministack.yaml, which was a two-owner bug:
# that base is not inert, the bootstrap Application syncs it with
# `directory.recurse: true` / `prune: true` / `selfHeal: true`, and the two
# copies of the Job had the same name with different specs. The synced copy
# still carried the `|| echo "queue already exists"` swallow that logs a
# falsehood on failure. Verified 2026-09-30 against the live Application.
#
# The manifest now says where the Job went and why, so the next reader does not
# "restore" it.

# The single master copy of the queue logic, shipped to the pod.
#
# `file()` is deliberate. It resolves at PLAN time, so if the script moves or
# is deleted this fails the plan instead of silently deploying a Job with
# stale behaviour. The alternative — a second copy of this logic in HCL, or in
# the kustomize manifest — would not fail; it would drift, which is the failure
# this project has now hit twice.
# The dead-letter queue has to be one of the queues this module creates, and it
# has to be created before the queue that redrives to it. Neither is enforced
# by the bootstrap script, which only walks `var.queues`; both are ways to ship
# a redrive policy pointing at a queue that does not exist.
#
# A `check` block, not a `validation` block on the variable, because OpenTofu
# 1.7.0 rejects a validation that refers to a second variable — see the note in
# variables.tf. A failed `check` is a WARNING and `plan` still exits 0, which
# is the documented behaviour of this repo's `check` blocks; treat it as a
# signal, not a gate.
check "redrive_queue_is_managed" {
  assert {
    condition     = contains(var.queues, var.redrive.dead_letter_queue)
    error_message = "The dead-letter queue (${var.redrive.dead_letter_queue}) is not in var.queues, so the bootstrap will never create it and the redrive policy will point at nothing."
  }
}

check "redrive_source_is_managed" {
  assert {
    condition     = contains(var.queues, var.redrive.source_queue)
    error_message = "The redrive source queue (${var.redrive.source_queue}) is not in var.queues, so the policy will be attached to a queue that is never created."
  }
}

check "redrive_target_created_first" {
  assert {
    condition     = index(var.queues, var.redrive.dead_letter_queue) < index(var.queues, var.redrive.source_queue)
    error_message = "The dead-letter queue (${var.redrive.dead_letter_queue}) must come BEFORE the source queue in var.queues. SQS rejects a RedrivePolicy whose target does not exist yet (verified 2026-09-30: InvalidAttributeValue)."
  }
}

resource "kubernetes_config_map" "bootstrap_script" {
  metadata {
    name      = "ministack-bootstrap-script"
    namespace = var.bootstrap_namespace
    labels    = local.labels
  }

  data = {
    "bootstrap-ministack-queues.sh" = local.bootstrap_script
  }
}

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

        # The master script, mounted read-only from the ConfigMap above. This
        # is the whole of the Job's behaviour: the queue names, the ordering,
        # the redrive wiring and the error handling all live in that one file
        # and are identical whether it runs in this pod or on a laptop.
        volume {
          name = "bootstrap-script"

          config_map {
            name = kubernetes_config_map.bootstrap_script.metadata[0].name
          }
        }

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
          # absent. Every `aws` call in the brief's script failed, and the
          # failure was then hidden: the create loop ended in
          # `|| echo "queue $q already exists"`, which under `set -e` swallows
          # a non-zero exit and prints a reassuring falsehood. The Job would
          # report "queue order-events already exists" three times having
          # created nothing.
          #
          # The master script no longer contains that construct at all. These
          # values are the standard fake credentials for a local emulator and
          # are not secrets (Global Constraint: no secret *value* in a
          # committed file — `test`/`test` authenticates nothing and authorises
          # nothing; verified, every operation in the runbook succeeds with
          # them).
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

          # The script reads these instead of hardcoding them, so the queue
          # list and the redrive wiring have exactly one source of truth
          # (var.queues / var.redrive) whether it runs in-cluster or on a host.
          env {
            name  = "MINISTACK_ENDPOINT"
            value = local.endpoint
          }
          env {
            name  = "MINISTACK_QUEUES"
            value = join(" ", var.queues)
          }
          env {
            name  = "MINISTACK_REDRIVE_SOURCE"
            value = var.redrive.source_queue
          }
          env {
            name  = "MINISTACK_REDRIVE_DLQ"
            value = var.redrive.dead_letter_queue
          }
          env {
            name  = "MINISTACK_REDRIVE_MAX"
            value = tostring(var.redrive.max_receive_count)
          }

          volume_mount {
            name       = "bootstrap-script"
            mount_path = "/opt/scripts"
            read_only  = true
          }

          # `curl`, `python3` and `/bin/sh` are all confirmed present in this
          # image (verified 2026-09-30: /usr/bin/curl 8.3.0, Python 3.11.8), so
          # the script needs no second image and no custom entrypoint.
          command = ["/bin/sh", "/opt/scripts/bootstrap-ministack-queues.sh"]
        }
      }
    }
  }

  depends_on = [kubernetes_service.endpoint]
}
