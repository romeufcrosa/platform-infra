#!/usr/bin/env bash
# Idempotently create the platform's SQS queues against a running Ministack.
#
# THIS FILE IS THE MASTER. There is exactly one copy of this logic in the repo
# and it is this one. The OpenTofu `kubernetes_job.bootstrap` in
# tofu/modules/ministack/main.tf mounts this file into the pod as a ConfigMap
# and runs it; it does not restate the queue names or the redrive wiring in
# HCL. The Job's own image and credentials come from tofu, everything
# behavioural comes from here.
#
# Consequence, and it is deliberate: if this file's path ever changes, the
# `file()` call in tofu/modules/ministack/main.tf fails at plan time rather
# than silently producing a Job with the wrong queue list. That is the failure
# mode we want. A second hand-synced copy would not fail; it would drift.
#
# The queue list and redrive wiring are ALSO passed in as environment
# variables by the Job, from `var.queues` / `var.redrive` in the module. In
# that path these defaults are never read — the module is the source. They
# exist only for running this file directly on a host, where there is no module
# to ask. That is the one residue: the values below and the two tofu variables
# are written twice. It is left visible rather than papered over with a
# generate-and-commit step, because a generated file that is committed is a
# third thing to keep honest, and this duplicate is inert in the path that
# actually provisions the cluster.
set -euo pipefail

EP="${MINISTACK_ENDPOINT:-http://localhost:4566}"

# Creation order matters. The DLQ must exist before the queue that redrives to
# it: SQS rejects a RedrivePolicy whose deadLetterTargetArn names a queue that
# does not exist yet. Verified 2026-09-30 against ministackorg/ministack:1.5.17
# — creating the source first errors, creating the DLQ first succeeds.
QUEUES="${MINISTACK_QUEUES:-order-events-dlq order-events platform-notifications}"

REDRIVE_SOURCE="${MINISTACK_REDRIVE_SOURCE:-order-events}"
REDRIVE_DLQ="${MINISTACK_REDRIVE_DLQ:-order-events-dlq}"
REDRIVE_MAX="${MINISTACK_REDRIVE_MAX:-3}"

# The AWS CLI needs BOTH a region and credentials, and refuses to run without
# them — verified 2026-09-30 against public.ecr.aws/aws-cli/aws-cli:2.17.0:
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

# A JSON interpreter is needed to build the --attributes file and to compare
# the stored RedrivePolicy as a value rather than as a substring. Which binary
# provides it differs between the two places this script runs, and neither
# name is a safe assumption:
#
#   * public.ecr.aws/aws-cli/aws-cli:2.17.0 has `python` (2.7.18) and NO
#     `python3` at all. Verified 2026-09-30 by running the image and testing
#     both names — `command -v python3` returns nothing.
#   * A macOS host typically has `python3` and no `python`.
#
# So detect, and fail loudly rather than silently. The Python used below is
# deliberately 2/3-compatible for exactly this reason.
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || {
  echo "ERROR: need python3 or python to build the SQS attributes JSON" >&2
  exit 1
}

# The account id is a property of the emulator, not configuration. It is
# derived by asking, not hardcoded, so a future emulator release that changes
# it does not silently produce ARNs pointing at nothing. Verified
# 2026-09-30: Ministack 1.5.17 reports 000000000000.
ACCOUNT_ID="$(aws --endpoint-url "$EP" sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
  echo "ERROR: could not determine the Ministack account id from $EP" >&2
  echo "       cannot build a RedrivePolicy target ARN without it" >&2
  exit 1
fi

echo "waiting for ministack at $EP"
until curl -sf "$EP/_ministack/health" >/dev/null 2>&1; do
  sleep 2
done

queue_url() {
  aws --endpoint-url "$EP" sqs get-queue-url --queue-name "$1" \
    --query QueueUrl --output text 2>/dev/null || true
}

# The RedrivePolicy, as SQS stores it: a JSON string, escaped inside the
# attribute map. --attributes accepts a file:// URL, and the CLI shorthand
# form CANNOT carry this value — verified 2026-09-30, the shorthand fails with
# "Error parsing parameter '--attributes': Expected: '=', received: '\"'".
# That is a CLI argument-parser limit, not a Ministack one, so the file form
# works and the shorthand does not. The tempfile is trap-cleaned.
write_attributes_file() {
  local policy="$1" visibility="$2" out
  out="$(mktemp)"
  "$PY" - "$out" "$policy" "$visibility" <<'PYEOF'
import json, sys
path, policy, visibility = sys.argv[1], sys.argv[2], sys.argv[3]
attrs = {"VisibilityTimeout": visibility}
if policy:
    attrs["RedrivePolicy"] = policy
with open(path, "w") as fh:
    json.dump(attrs, fh)
PYEOF
  printf '%s' "$out"
}

redrive_policy_json() {
  printf '{"deadLetterTargetArn":"arn:aws:sqs:%s:%s:%s","maxReceiveCount":%s}' \
    "$AWS_DEFAULT_REGION" "$ACCOUNT_ID" "$REDRIVE_DLQ" "$REDRIVE_MAX"
}

# Is this queue already redriving to the DLQ we intend? Compared as a parsed
# value, not as a substring, because SQS stores the JSON with escaped quotes
# and the exact byte form is not guaranteed.
has_expected_redrive() {
  local url="$1" want="$2" got
  got="$(aws --endpoint-url "$EP" sqs get-queue-attributes \
    --queue-url "$url" --attribute-names RedrivePolicy \
    --query 'Attributes.RedrivePolicy' --output text 2>/dev/null || true)"
  [ -n "$got" ] || return 1
  "$PY" - "$got" "$want" <<'PYEOF'
import json, sys
try:
    a = json.loads(sys.argv[1])
    b = json.loads(sys.argv[2])
except Exception:
    sys.exit(1)
sys.exit(0 if a == b else 1)
PYEOF
}

ensure_queue() {
  local name="$1" policy="$2" url attrs
  url="$(queue_url "$name")"
  if [ -n "$url" ]; then
    if [ -n "$policy" ] && ! has_expected_redrive "$url" "$policy"; then
      # The queue exists but is not redriving — it was created by an earlier
      # version of this script, or by the brief's original ensure loop. Attach
      # the policy now. `create-queue` CANNOT do this: it errors with
      # QueueAlreadyExists when attributes differ (verified 2026-09-30), so the
      # fix has to be an explicit SetQueueAttributes.
      attrs="$(write_attributes_file "$policy" 30)"
      aws --endpoint-url "$EP" sqs set-queue-attributes \
        --queue-url "$url" --attributes "file://$attrs" >/dev/null
      rm -f "$attrs"
      echo "attached redrive policy: $name -> $REDRIVE_DLQ (maxReceiveCount=$REDRIVE_MAX)"
    else
      echo "queue exists: $name"
    fi
    return 0
  fi

  attrs="$(write_attributes_file "$policy" 30)"
  aws --endpoint-url "$EP" sqs create-queue --queue-name "$name" \
    --attributes "file://$attrs" >/dev/null
  rm -f "$attrs"
  echo "created queue: $name"
}

# Note there is no `|| echo "queue already exists"` anywhere in this loop.
# That construct was in the original brief and it is a trap: under `set -e` it
# swallows a non-zero exit and prints a reassuring falsehood, so a total
# failure (missing credentials, unreachable endpoint) is indistinguishable
# from success. Every call here either succeeds or aborts the script.
for q in $QUEUES; do
  if [ "$q" = "$REDRIVE_SOURCE" ]; then
    ensure_queue "$q" "$(redrive_policy_json)"
  else
    ensure_queue "$q" ""
  fi
done

echo "--- queues ---"
aws --endpoint-url "$EP" sqs list-queues
echo "--- redrive verification ---"
SRC_URL="$(queue_url "$REDRIVE_SOURCE")"
if [ -n "$SRC_URL" ]; then
  aws --endpoint-url "$EP" sqs get-queue-attributes \
    --queue-url "$SRC_URL" --attribute-names RedrivePolicy QueueArn
fi
