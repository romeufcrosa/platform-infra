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
# here rather than propagating it into the eight module outputs.tf files Tasks
# 4-10 add.
#
# The hard part is not the match, it is the false positives. This file's own
# header discusses `type` in prose, so a naive grep matches the documentation.
# Two things keep that from happening:
#
#   1. Comments are stripped first — both full-line (`# ...`) and trailing
#      (`... = "x"  # note`) forms.
#   2. What remains is scanned for a HCL *argument assignment*: the word `type`
#      not preceded by an identifier character, not inside a double-quoted
#      string, and followed by `=`. Prose like "no `type =` on any output"
#      survives comment-stripping only inside strings, which rule 2 excludes.
#
# The pattern is deliberately NOT anchored to start-of-line. `tofu fmt` will
# always put arguments on their own line, so an anchor there looks safe — but
# it is a guard against a *defect*, and a guard with a known hole is worse than
# one without: if a future hand-edit ever produces `output "x" { type = number`
# on one line, the anchored form reports PASS. Red control G2 in
# scripts/test-check-local-overrides.sh covers that case.
#
# Scope is every `tofu/**/outputs.tf`, not just the local profile's. Tasks 4-10
# add eight more, the `type =` prohibition has already been violated ten times
# in the plan, and this script is that prohibition's only automated enforcement.
# Scanning one file of three would let the other two regress in silence.
#
# The scan is per-file so the report can name the file. A `find` that matches
# nothing is a silently vacuous check — the exact defect class this script
# exists to prevent — so zero files is a FAIL, not a PASS.
#
# No `mapfile`/arrays: macOS ships bash 3.2, where `mapfile` does not exist.
# `find`'s stderr is discarded so that a wrong root lands on the explicit
# zero-files FAIL below rather than dying opaquely under `set -euo pipefail`
# with no explanation — a guard that dies without saying why is one nobody can
# act on.
output_tf_files="$(find "$REPO_ROOT/tofu" -name outputs.tf -type f 2>/dev/null | sort || true)"

if [ -z "$output_tf_files" ]; then
  printf '  FAIL no `type =` scan: found zero tofu/**/outputs.tf files\n'
  status=1
else
  file_count="$(printf '%s\n' "$output_tf_files" | wc -l | tr -d ' ')"
  printf '  scanning %s outputs.tf file(s) for `type =`\n' "$file_count"
  type_lines=""
  while IFS= read -r tf; do
    [ -n "$tf" ] || continue
    hits="$(
      # Strip comments outside of strings, then find `type` used as an argument.
      awk '
        {
          line = $0
          out = ""
          in_str = 0
          i = 1
          n = length(line)
          while (i <= n) {
            c = substr(line, i, 1)
            if (c == "\\" && in_str) { i += 2; continue }          # escaped char in string
            if (c == "\"") { in_str = !in_str; i++; continue }    # string delimiter
            if (!in_str && c == "#") break                          # comment: rest of line
            if (!in_str && c == "/" && substr(line, i+1, 1) == "/") break
            if (!in_str) out = out c
            i++
          }
          if (out ~ /(^|[^a-zA-Z0-9_"])type[ \t]*=/) print NR ": " line
        }
      ' "$tf"
    )"
    if [ -n "$hits" ]; then
      rel="${tf#"$REPO_ROOT"/}"
      type_lines+="${rel}"$'\n'
      while IFS= read -r hit; do
        [ -n "$hit" ] && type_lines+="    ${hit}"$'\n'
      done <<<"$hits"
    fi
  done <<<"$output_tf_files"
  if [ -z "$type_lines" ]; then
    printf '  PASS no `type =` on any output (OpenTofu 1.7 constraint)\n'
  else
    printf '  FAIL `type =` found on an output block:\n'
    printf '%s' "$type_lines"
    status=1
  fi
fi

printf '\n'
if [ "$status" -eq 0 ]; then
  printf 'LOCAL OVERRIDES CHECK PASSED\n'
else
  printf 'LOCAL OVERRIDES CHECK FAILED\n'
fi
exit "$status"
