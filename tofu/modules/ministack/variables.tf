variable "namespace" {
  description = "Namespace for the Ministack Deployment and Service. OpenTofu creates it in Task 4."
  type        = string
  default     = "ministack"
}

variable "image_tag" {
  description = "Pinned Ministack image tag, without the repository. Never 'latest' (Global Constraint)."
  type        = string
  default     = "1.5.17"
}

variable "bootstrap_image" {
  description = "Pinned image for the queue bootstrap Job. Must contain BOTH `aws` and `curl`."
  type        = string
  default     = "public.ecr.aws/aws-cli/aws-cli:2.17.0"
}

# The three queue names are a contract, not a default. `order-events` is what
# the Phase 2 Go service produces to and the Node service consumes from; the
# other two are its DLQ and the platform notification queue. Task 7's brief
# calls these "the exact names [that] are the contract", so they are pinned
# here as a variable default rather than inlined in the Job's shell script —
# the shell script and the output that reports them then read the same list.
variable "bootstrap_namespace" {
  description = <<-EOT
    Namespace the queue bootstrap Job runs in. Deliberately NOT `var.namespace`:
    `platform-system` is where the GitOps base lives, so the mirror manifest and
    this resource agree on the Job's location.
  EOT
  type        = string
  default     = "platform-system"
}

variable "queues" {
  description = "SQS queues to ensure at bootstrap. Names are a cross-task contract."
  type        = list(string)
  default     = ["order-events", "order-events-dlq", "platform-notifications"]
}

variable "namespace_dependency" {
  description = "Explicit dependency so the namespace exists before the workload is created."
  type        = any
  default     = null
}
