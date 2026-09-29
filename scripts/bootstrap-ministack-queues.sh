#!/usr/bin/env bash
# Idempotently create the platform's SQS queues against a running Ministack.
# Mirrors the ministack-bootstrap Job; if the two ever disagree, the Job is
# the source of truth and this script is the bug.
set -euo pipefail

EP="${MINISTACK_ENDPOINT:-http://localhost:4566}"
QUEUES=(order-events order-events-dlq platform-notifications)

# The AWS CLI needs BOTH a region and credentials, and refuses to run without
# them — verified 2026-09-28 against public.ecr.aws/aws-cli/aws-cli:2.17.0:
#
#   no region, no creds -> "You must specify a region."
#   region, no creds    -> "Unable to locate credentials."
#
# On a developer laptop the ambient environment usually has neither, so these
# are defaults rather than overrides: a caller who has real AWS config set
# still wins. The values are not secrets (Global Constraint) — they are the
# standard placeholders for a local emulator and authorise nothing. Ministack
# accepts them and performs no IAM check.
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"

command -v aws >/dev/null || { echo "aws CLI not found" >&2; exit 1; }
until curl -sf "$EP/_ministack/health" >/dev/null 2>&1; do
  echo "waiting for ministack at $EP"; sleep 2
done

for q in "${QUEUES[@]}"; do
  # `sqs describe-queues` is NOT a real AWS CLI operation and this script's
  # first draft used it. Verified 2026-09-28:
  #
  #   $ aws --endpoint-url "$EP" sqs describe-queues --queue-names order-events
  #   usage: aws [options] <command> ...
  #   aws: error: argument operation: Invalid choice, valid choices are:
  #     add-permission | change-message-visibility | create-queue | ...
  #   exit 252
  #
  # Because the check was in an `if`, a non-existent *operation* and a
  # non-existent *queue* were indistinguishable — both non-zero — so the
  # script would take the "create" branch on every single run, forever. The
  # queue set stayed correct only because `create-queue` is itself idempotent,
# # which means the idempotence the script claims to test was never actually
  # being tested. `get-queue-url` is the real operation: exit 0 when the queue
  # exists, exit 254 (NonExistentQueue) when it does not.
  if aws --endpoint-url "$EP" sqs get-queue-url --queue-name "$q" >/dev/null 2>&1; then
    echo "queue exists: $q"
  else
    aws --endpoint-url "$EP" sqs create-queue --queue-name "$q" \
      --attributes VisibilityTimeout=30 >/dev/null
    echo "created queue: $q"
  fi
done

aws --endpoint-url "$EP" sqs list-queues
