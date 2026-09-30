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
  description = <<-EOT
    SQS queues to ensure at bootstrap, in CREATION ORDER. The names are a
    cross-task contract: `order-events` is what the Phase 2 Go service produces
    to and the Node service consumes from.

    The order is not cosmetic — `order-events-dlq` must be created FIRST.
    SQS rejects a queue whose RedrivePolicy names a dead-letter target that
    does not exist yet. Verified 2026-09-30 against
    ministackorg/ministack:1.5.17: creating the source first fails with
    `InvalidAttributeValue ... Value must be a JSON object containing string
    fields deadLetterTargetArn and maxReceiveCount`, and creating the DLQ first
    succeeds. The bootstrap script walks this list in order.
  EOT
  type        = list(string)
  default     = ["order-events-dlq", "order-events", "platform-notifications"]
}

# The redrive wiring. Without this the DLQ is decoration: a queue nothing
# points at never receives a poison message, and Phase 1 verification would
# show a DLQ that looks operational while catching nothing.
#
# `max_receive_count` is the number of receives after which a message is moved
# to the DLQ. Verified functionally end-to-end on 2026-09-30 against the real
# cluster: with 3, a message was received 3 times and the 4th receive found
# the source queue empty with the message sitting in `order-events-dlq`.
variable "redrive" {
  description = "Redrive policy attaching a dead-letter queue to a source queue."
  type = object({
    source_queue      = string
    dead_letter_queue = string
    max_receive_count = number
  })
  default = {
    source_queue      = "order-events"
    dead_letter_queue = "order-events-dlq"
    max_receive_count = 3
  }

  validation {
    condition     = var.redrive.max_receive_count >= 1 && var.redrive.max_receive_count <= 1000
    error_message = "SQS requires maxReceiveCount between 1 and 1000."
  }

  # NOTE: there is deliberately no validation here that the dead-letter queue
  # appears in `var.queues`. It is the obvious thing to add and OpenTofu
  # rejects it — a `validation` block may only refer to the variable it is
  # attached to, so `contains(var.queues, var.redrive.dead_letter_queue)` is a
  # hard error:
  #
  #   Error: Invalid reference in variable validation
  #     The condition for variable "redrive" can only refer to the variable
  #     itself, using var.redrive.
  #
  # Verified 2026-09-30 against OpenTofu 1.7.0. The cross-variable check lives
  # in the `check "redrive_queue_is_managed"` block in main.tf, where
  # referring to two variables is legal.
}

variable "namespace_dependency" {
  description = "Explicit dependency so the namespace exists before the workload is created."
  type        = any
  default     = null
}
