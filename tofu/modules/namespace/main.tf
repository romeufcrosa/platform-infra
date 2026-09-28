resource "kubernetes_namespace" "this" {
  count = var.create ? 1 : 0

  metadata {
    name = var.name
    labels = merge(var.labels, {
      "platform.environment" = var.environment
    })
    annotations = var.annotations
  }

  # `ignore_changes` on annotations, and the reason is a two-owner problem.
  #
  # The Global Constraint says OpenTofu owns every namespace. Task 5's
  # GitOps base *also* declares five of them, deliberately: the file header
  # says the two paths are meant to "converge on the same desired state", with
  # ArgoCD becoming authoritative in Phase 2+. Two writers, one object.
  #
  # ArgoCD stamps `argocd.argoproj.io/tracking-id` onto every resource it
  # manages. That annotation is not in this resource's config, so without this
  # block every single plan is:
  #
  #   ~ module.namespaces["external-secrets"].kubernetes_namespace.this[0]
  #     ~ metadata {
  #         ~ annotations = {
  #             - "argocd.argoproj.io/tracking-id" = "..." -> null
  #           }
  #     }
  #
  # which OpenTofu "fixes" by deleting the annotation, which ArgoCD re-adds on
  # its next sync. A perpetual diff, on every plan, forever — the exact
  # condition the plan's own guidance calls "a plan nobody reads".
  #
  # **The obvious fix is the destructive one.** Deleting the Namespace
  # documents from the GitOps base would leave OpenTofu the sole owner and end
  # the fight — except this Application runs with `prune: true`, so the next
  # sync would **delete five live namespaces**, taking every workload in them
  # with it. A clean diff is not worth a deleted namespace, and a diff that is
  # visible on every plan is merely annoying.
  #
  # So annotations are left alone. `metadata.labels` is deliberately NOT
  # ignored: the labels are the part both sides must agree on, the
  # `platform.environment` key is computed here from `var.environment`, and
  # silently dropping a real label drift is the failure this whole project
  # exists to teach against. ArgoCD's side of the same problem is handled by
  # the `ignoreDifferences` block in the bootstrap Application.
  lifecycle {
    ignore_changes = [metadata[0].annotations]
  }
}
