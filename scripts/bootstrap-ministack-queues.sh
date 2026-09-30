#!/usr/bin/env bash
# Host entrypoint for the queue bootstrap. This is a WRAPPER, not a copy.
#
# The master lives at tofu/modules/ministack/bootstrap-ministack-queues.sh
# because OpenTofu's `file()` function cannot read outside the module
# directory — verified 2026-09-30 against OpenTofu 1.7.0:
#
#   Error: Invalid function argument
#     Invalid value for "path" parameter: no file exists at
#     "modules/ministack/../../scripts/bootstrap-ministack-queues.sh";
#     this function works only with files that are distributed as part of
#     the configuration source code
#
# So the master has to sit inside the module for the Job to mount it, and this
# script delegates. That direction matters: the logic lives with the resource
# that runs it, and the host entrypoint exists only so `make` targets and
# onboarding docs have a conventional path. There is exactly one copy of the
# queue list, the creation order and the redrive wiring in this repository,
# and this file is not it.
set -euo pipefail

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tofu/modules/ministack/bootstrap-ministack-queues.sh" "$@"
