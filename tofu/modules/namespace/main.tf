resource "kubernetes_namespace" "this" {
  count = var.create ? 1 : 0

  metadata {
    name = var.name
    labels = merge(var.labels, {
      "platform.environment" = var.environment
    })
    annotations = var.annotations
  }
}
