output "endpoint" {
  description = "Host-local endpoint, after `make port-forwards`. This is the URL in the endpoints output that the verify script and onboarding docs read."
  value       = "http://localhost:4566"
}

output "namespace" {
  description = "Namespace Ministack runs in."
  value       = kubernetes_deployment.ministack.metadata[0].namespace
}

output "queues" {
  description = <<-EOT
    The SQS queue names the bootstrap Job ensures. Exported so the verify
    script and the Phase 2 services read the contract from here rather than
    restating three string literals in a fourth place.
  EOT
  value       = var.queues
}

# NOTE: no `type = ` on any output above. OpenTofu 1.7.0 rejects it on an
# `output` block as `Unsupported argument` (see tofu/outputs.tf for the
# verified error). `variable` blocks still take `type`.

# The in-cluster URL — `http://ministack.ministack.svc.cluster.local:4566` — is
# deliberately NOT an output. It is a property of the Service's name and this
# module's namespace, so an output for it would be a second place to keep it
# correct. The bootstrap Job below builds it from those two facts, exactly as
# the Task 9 secret contract does. `output "namespace"` exists so a caller can
# *build* that URL rather than assume it.
