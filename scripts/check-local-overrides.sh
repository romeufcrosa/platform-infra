#!/usr/bin/env bash
# Verify the local environment profile's key set is identical in both places it
# is declared.
#
# The declared-but-not-wired pattern has appeared three times in this repo, and
# this is the structural guard against a fourth. The two declarations are:
#
#   tofu/environments/local/outputs.tf   — one `output` per local in overrides.tf
#   tofu/main.tf                        — local.local_overrides, which reads them
#
# They MUST have the same keys. A key in outputs.tf that is missing from
# local_overrides is an override that is computed and then silently dropped — no
# tool would ever show it changing. That is precisely the defect the Phase 1
# Atlantis exit criterion would fail to catch, so it is checked here instead of
# in HCL: OpenTofu 1.7 cannot enumerate a module's output names, so the only
# available HCL expression compares the map's keys to itself — a tautology that
# can never fail. An untested check is worse than no check.
#
# Idempotent and read-only. Exits 0 when the key sets agree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_DIR="$REPO_ROOT/tofu/environments/local"
MAIN_TF="$REPO_ROOT/tofu/main.tf"

for f in "$MODULE_DIR/outputs.tf" "$MODULE_DIR/overrides.tf" "$MAIN_TF"; do
  [ -f "$f" ] || { printf 'ERROR: missing %s\n' "$f" >&2; exit 1; }
done

# --- 1. every local in overrides.tf must have an output -----------------------
# Capture first, then grep/awk the captured text. Never pipe a producer into a
# consumer that can exit early: under `set -o pipefail`, `<producer> | grep -q`
# reports a genuine match as FAILURE, because grep -q exits at the first match,
# the producer takes SIGPIPE (141), and pipefail promotes that to the status.
# The local names are read with a herestring, so there is no producer at all.
locals_block="$(awk '/^locals \{/,/^\}/' "$MODULE_DIR/overrides.tf")"
local_names="$(sed -n 's/^[[:space:]]*\([a-z_][a-z0-9_]*\)[[:space:]]*=.*/\1/p' <<<"$locals_block" | sort)"

outputs_block="$(cat "$MODULE_DIR/outputs.tf")"
output_names="$(sed -n 's/^output "\([a-z_][a-z0-9_]*\)".*/\1/p' <<<"$outputs_block" | sort)"

# --- 2. and must also be listed in local_overrides in main.tf ----------------
overrides_block="$(awk '/local_overrides = \{/,/^  \}/' "$MAIN_TF")"
consumed_names="$(sed -n 's/^[[:space:]]*\([a-z_][a-z0-9_]*\)[[:space:]]*=[[:space:]]*module\.local\..*/\1/p' <<<"$overrides_block" | sort)"

status=0
report() {
  local label="$1" missing="$2"
  if [ -z "$missing" ]; then
    printf '  PASS %s\n' "$label"
  else
    printf '  FAIL %s: missing %s\n' "$label" "$missing"
    status=1
  fi
}

# shellcheck disable=SC2001
missing_outputs="$(comm -23 <(printf '%s\n' "$local_names") <(printf '%s\n' "$output_names") | tr '\n' ' ')"
# shellcheck disable=SC2001
missing_consumed="$(comm -23 <(printf '%s\n' "$output_names") <(printf '%s\n' "$consumed_names") | tr '\n' ' ')"

printf 'overrides.tf locals:        %s\n' "$(tr '\n' ' ' <<<"$local_names")"
printf 'outputs.tf outputs:         %s\n' "$(tr '\n' ' ' <<<"$output_names")"
printf 'main.tf local_overrides:    %s\n' "$(tr '\n' ' ' <<<"$consumed_names")"
printf '\n'

report "every local has an output" "$missing_outputs"
report "every output is consumed by local_overrides" "$missing_consumed"

# --- 3. no `type =` on any output --------------------------------------------
# OpenTofu 1.7.0 rejects `type` in an output block (it is a Terraform 1.3+
# feature). This is the first file later tasks copy from, so catch a regression
# here rather than propagating it four times.
#
# Comments are stripped first, and the match is anchored to a real assignment.
# The file's own header discusses `type` at length, so an unanchored search
# would match this very check's documentation and fail forever.
type_lines="$(grep -nE '^[[:space:]]*type[[:space:]]*=' <<<"$(grep -vE '^[[:space:]]*#' <<<"$outputs_block")" || true)"
if [ -z "$type_lines" ]; then
  printf '  PASS no `type =` on any output (OpenTofu 1.7 constraint)\n'
else
  printf '  FAIL `type =` found on an output block: %s\n' "$type_lines"
  status=1
fi

printf '\n'
if [ "$status" -eq 0 ]; then
  printf 'LOCAL OVERRIDES CHECK PASSED\n'
else
  printf 'LOCAL OVERRIDES CHECK FAILED\n'
fi
exit "$status"
