# Ministack AWS API coverage

What Phase 1 actually verified about the emulator, and what it did not.

This is the honest input to ADR 0004. Every "verified" row below was executed
against the pinned image `ministackorg/ministack:1.5.17` on the live `platform`
minikube profile on **2026-09-28** — both as a throwaway `docker run` during
development and, for the SQS rows, again through the real Service via a
port-forward on `localhost:4566`. Every "not verified" row is an operation
Phase 2 will plausibly need that nobody has run yet. Nothing here is inferred
from Ministack's documentation.

## Emulator identity

| Fact | Value | How verified |
|---|---|---|
| Image | `ministackorg/ministack` (Docker Hub) | `docker pull`, run, health 200 |
| Tag | `1.5.17` | Docker Hub tags API; linux/amd64 + linux/arm64 |
| Port | 4566, the only one | container run + probe |
| Health path | `GET /_ministack/health` | returns 200 + per-service availability map |
| Account id | `000000000000` | appears in every queue URL and ARN |
| Region | caller-supplied; `us-east-1` used throughout | queue ARN `arn:aws:sqs:us-east-1:000000000000:...` |
| Auth | none enforced | all rows below succeeded with `test`/`test` |
| Helm chart | **none published** | `https://ministack.github.io/ministack-helm/index.yaml` → 404 |

The account id being `000000000000` matters for Phase 2: the brief's smoke-test
queue URL (`http://localhost:4566/000000000000/order-events`) is correct, and
both SDKs will form the same URL from the region/endpoint alone.

## Verified — SQS

All against `order-events` unless noted. Namespace-agnostic: the in-cluster URL
the Job uses differs only in host.

| Operation | Result |
|---|---|
| `CreateQueue` | `{"QueueUrl": "http://localhost:4566/000000000000/order-events"}` |
| `CreateQueue` (repeat, same attributes) | exit 0, same URL — **idempotent** |
| `CreateQueue` (existing, different attributes) | exit 254, `QueueAlreadyExists` |
| `ListQueues` | exactly the 3 expected URLs, no duplicates |
| `GetQueueUrl` (exists) | exit 0 — the correct existence check |
| `GetQueueUrl` (absent) | exit 254, `AWS.SimpleQueueService.NonExistentQueue` |
| `SendMessage` | `MessageId` returned; `MD5OfMessageBody` + `MD5OfMessageAttributes` present |
| `ReceiveMessage` | `ReceiptHandle` returned; body round-trips byte-identical |
| `DeleteMessage` | exit 0 |
| `ChangeMessageVisibility` | exit 0 |
| `GetQueueAttributes` (`All`) | `QueueArn`, `VisibilityTimeout`, `ApproximateNumberOfMessages`, `…NotVisible`, retention, delay, max size |
| `SetQueueAttributes` | exit 0; used to attach `RedrivePolicy` to an existing queue |
| `GetQueueAttributes` (`RedrivePolicy`) | round-trips the stored JSON |
| `sts GetCallerIdentity` → Account | `000000000000` — the script derives the ARN from this rather than hardcoding it |

## Verified — redrive / dead-letter (added 2026-09-30)

Ministack does **not** merely store a `RedrivePolicy`, it implements the
behaviour. Proven end-to-end against the real cluster queues, not just by
reading the attribute back:

- With `maxReceiveCount: 3`, a message sent to `order-events` was received
  three times; the fourth `receive-message` found the source empty and the
  message sitting in `order-events-dlq` with its body intact
  (`{"type":"poison"}`).
- Attaching a policy to a queue that already exists requires
  `SetQueueAttributes`: `CreateQueue` on an existing name with a *different*
  attribute errors with `QueueAlreadyExists`. The bootstrap script handles the
  repair case explicitly.
- **Ordering is load-bearing.** Creating the source queue before its DLQ fails:

  ```
  An error occurred (InvalidAttributeValue) when calling the CreateQueue
  operation: Invalid value for the parameter RedrivePolicy. Value must be a
  JSON object containing string fields deadLetterTargetArn and maxReceiveCount
  (an integer between 1 and 1000).
  ```

  `var.queues` therefore lists the DLQ first, and a `check` block asserts it.

- **The CLI's `--attributes` shorthand cannot carry a RedrivePolicy at all.**
  It fails in the argument parser with `Expected: '=', received: '"'`. A
  `file://` attributes document works. This is a CLI limitation, not a
  Ministack one — worth knowing because it is the obvious first thing to try.

**`DescribeQueues` does not exist.** It is not an AWS CLI operation at all:

```
$ aws --endpoint-url "$EP" sqs describe-queues --queue-names order-events
aws: error: argument operation: Invalid choice, valid choices are:
  add-permission | change-message-visibility | create-queue | delete-message | ...
exit 252
```

`GetQueueUrl` is the substitute. Anything in Phase 2 that reaches for
`DescribeQueues` should use it.

Two SQS behaviours worth pinning, because both are easy to get wrong:

- **Message attributes are not a flag.** `--message-attribute probe=true` is
  rejected by the CLI's own parameter validation
  (`Invalid type for parameter MessageAttributes.probe … valid types: dict`).
  The working form is
  `--message-attributes '{"probe":{"DataType":"String","StringValue":"true"}}'`.
  An SDK call is unaffected — this is a CLI-syntax trap only, but the
  onboarding docs will copy CLI commands.
- **Idempotence rests on attribute equality.** `CreateQueue` on an existing
  name with the *same* attributes returns the existing URL; with a *different*
  attribute it errors. So re-running the bootstrap after someone changed
  `VisibilityTimeout` out of band fails loudly, which is the behaviour to keep.

## Verified — S3

| Operation | Result |
|---|---|
| `CreateBucket` (`s3 mb`) | ok |
| `PutObject` (`s3 cp` up) | ok |
| `GetObject` (`s3 cp` down) | content round-trips |

## Verified — Secrets Manager

| Operation | Result |
|---|---|
| `CreateSecret` | ARN `arn:aws:secretsmanager:us-east-1:000000000000:secret:…` |
| `GetSecretValue` | returns the exact string written |

## Not verified — the honest gap

Phase 2 will hit these. None has been run, so none is a guarantee.

**SQS**
- `DeleteQueue`, `PurgeQueue`
- Batch APIs: `SendMessageBatch`, `ReceiveMessage` with `DeleteMessageBatch`,
  `ChangeMessageVisibilityBatch`
- `AddPermission` / `RemovePermission` / queue policies
- Delay queues (`DelaySeconds`), FIFO queues (`.fifo` names, `MessageGroupId`),
  long polling (`WaitTimeSeconds`)
- Redrive *behaviour* over `maxReceiveCount` values other than 3, and
  `ApproximateAgeOfOldestMessage` accounting in the DLQ
- Message retention and visibility-timeout *expiry* over time — only the
  immediate call was checked, not the passage of time

**S3**
- `DeleteObject`, `ListObjectsV2`, multipart upload, presigned URLs
- Bucket versioning, bucket policy, CORS
- Object metadata and content-type round-tripping (matters if Phase 2 stores
  JSON events with a declared type)

**Secrets Manager**
- `PutSecretValue` (rotation / version staging), `DescribeSecret`,
  `ListSecrets`, `DeleteSecret`, `TagResource`
- Whether the version-id suffix `-<7 hex>` behaves the same way the Go and Node
  SDKs expect

**Cross-cutting**
- Concurrent access from more than one client
- Behaviour across a Deployment restart — **state is in-process and is lost on
  restart.** The bootstrap Job is re-runnable precisely because of this, and
  `ttlSecondsAfterFinished: 3600` plus OpenTofu's recreate-on-next-apply is
  what makes the queue set converge again. A Phase 2 service that assumes
  queue durability across a pod restart will be wrong.
- `replicas > 1` on the Deployment. `local_overrides["ministack_replica_count"]`
  is declared (Task 3) and deliberately unwired: two Ministack processes behind
  one ClusterIP would not share queue state, so scaling out would silently
  split the queues across pods.
- **Ownership, unresolved.** The `Deployment` and `Service` are declared by
  OpenTofu *and* by `kubernetes/platform-system/platform/ministack.yaml`, which
  the ArgoCD bootstrap Application syncs with `recurse: true` / `prune: true` /
  `selfHeal: true`. One object, two owners. The queue bootstrap Job had exactly
  this bug and was resolved on 2026-09-30 by moving it to OpenTofu only; the
  Deployment and Service are still duplicated and are reported, not fixed.

## Re-running these checks

```bash
kubectl --context platform -n ministack port-forward svc/ministack 4566:4566 &
export AWS_DEFAULT_REGION=us-east-1 AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
EP=http://localhost:4566
./scripts/bootstrap-ministack-queues.sh
aws --endpoint-url $EP sqs list-queues
```

`test`/`test` are not secrets — Ministack performs no IAM check. See the
Global Constraint note in `tofu/modules/ministack/main.tf`.
