#!/usr/bin/env bash
# Red/green control suite for scripts/check-local-overrides.sh.
#
# A check whose failure mode was never exercised is not a checked gate — it is
# a comment that happens to run. The controls for this guard existed only as
# prose in a review report, so the next person to touch the awk had no way to
# re-run them and their first red control would have been their own. This script
# makes that impossible to repeat: every case below is executed here.
#
# Method: each case gets a THROWAWAY COPY of the tree (a temp dir, never the
# working tree), the guard is run inside that copy, and the case asserts on the
# guard's exit status. The point of the copy is that the F4 scan is a `find`
# over `$REPO_ROOT/tofu`, so a mutation has to be visible to the guard as a file
# on disk — editing the real tree in place would work but leaves the repo
# red between cases, and one Ctrl-C would strand it that way.
#
# The working tree is never written to at all, so `trap` only has to remove the
# temp dir. That is asserted explicitly at the end: if a future edit ever
# reintroduces an in-place mutation, the suite fails instead of quietly
# mutating the repo.
#
# Exits 0 when every control behaves as specified. Exits 1 otherwise.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD_REL="scripts/check-local-overrides.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/guard-controls.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM HUP

pass_count=0
fail_count=0

# Snapshot the tree's state so G8 can prove the suite changed nothing. Comparing
# against "clean" instead would false-fail whenever the suite is run on top of
# legitimate in-progress work.
BASELINE_STATUS="$(git -C "$REPO_ROOT" status --porcelain)"

cleanup_workdir() { rm -rf "$WORKDIR"; }

# --- harness -----------------------------------------------------------------

# A minimal tree the guard can run against: the guard needs scripts/, tofu/main.tf
# and the local module. Provider plugins are hundreds of MB and the guard never
# touches them.
seed_tree() {
  local dest="$1"
  mkdir -p "$dest/scripts" "$dest/tofu"
  cp "$REPO_ROOT/$GUARD_REL" "$dest/$GUARD_REL"
  cp "$REPO_ROOT/tofu/main.tf" "$dest/tofu/main.tf"
  cp -R "$REPO_ROOT/tofu/environments" "$dest/tofu/environments"
  cp -R "$REPO_ROOT/tofu/modules" "$dest/tofu/modules"
  cp -R "$REPO_ROOT/tofu/variables.tf" "$dest/tofu/variables.tf"
}

# Append lines to a file in a case's tree.
inject() {
  local tree="$1" rel="$2"
  shift 2
  printf '%s\n' "$@" >>"$tree/$rel"
}

# Overwrite a file in a case's tree. The false-positive controls use this on a
# MODULE outputs.tf rather than injecting into the local profile's, because
# checks 1 and 2 are scoped to the local module and would fail for an unrelated
# reason (a new output name that local_overrides does not consume), masking
# what the case is actually asserting.
write_module_output() {
  local tree="$1"
  cat >"$tree/tofu/modules/minikube_addons/outputs.tf"
}

# --- controls ----------------------------------------------------------------

# run_case <expected 0|1> <label> <mutation-fn> [expected-diagnostic]
#
# The optional fourth argument is the substring the guard's output must contain.
# Without it a red control proves only that the guard exited nonzero for SOME
# reason — a stale path, a shell error, an unrelated check failing would all
# satisfy it. Asserting the diagnostic pins the control to the specific
# behavior it is meant to guard.
run_case() {
  local expected="$1" label="$2" mutation="$3" expect_out="${4:-}"
  local tree_path="$WORKDIR/tree"
  cleanup_workdir
  mkdir -p "$WORKDIR"
  seed_tree "$tree_path"

  if [ -n "$mutation" ]; then "$mutation" "$tree_path"; fi

  local out status
  set +e
  out="$(bash "$tree_path/$GUARD_REL" 2>&1)"
  status=$?
  set -e

  if [ "$status" -ne "$expected" ]; then
    printf '  FAIL %-52s guard exit %s (expected %s)\n' "$label" "$status" "$expected"
    printf '%s\n' "$out" | sed 's/^/         | /'
    fail_count=$((fail_count + 1))
    return
  fi

  if [ -n "$expect_out" ] && ! printf '%s\n' "$out" | grep -qF "$expect_out"; then
    printf '  FAIL %-52s exit %s but output lacks: %s\n' "$label" "$status" "$expect_out"
    printf '%s\n' "$out" | sed 's/^/         | /'
    fail_count=$((fail_count + 1))
    return
  fi

  printf '  PASS %-52s guard exit %s (expected %s)\n' "$label" "$status" "$expected"
  pass_count=$((pass_count + 1))
}

# G1 — `type =` on its own line inside an output block. The canonical defect:
#      what `tofu fmt` produces when a Terraform 1.3+ habit is pasted in.
m_type_own_line() {
  inject "$1" tofu/environments/local/outputs.tf \
    'output "g_control" {' \
    '  description = "control case G1."' \
    '  type        = bool' \
    '  value       = true' \
    '}'
}

# G2 — the same defect written on one line. This is the case the unanchored
#      regex exists for: an anchored check reports PASS here.
m_type_one_line() {
  inject "$1" tofu/environments/local/outputs.tf \
    'output "g_control" { type = bool value = true }'
}

# G3 — false-positive control. `type =` inside a TRAILING comment must not trip
#      the check; a hand-annotating note is a normal thing to add.
m_type_trailing_comment() {
  write_module_output "$1" <<'EOF'
output "addons" {
  description = "The addon set asserted by this module." # note: type = bool is rejected on 1.7
  value       = local.expected_addons
}
EOF
}

# G4 — false-positive control. `type =` inside a quoted description string. The
#      unmutated outputs.tf header already contains this shape in prose.
m_type_in_string() {
  write_module_output "$1" <<'EOF'
output "addons" {
  description = "A `type = bool` mentioned here is prose, not an argument."
  value       = local.expected_addons
}
EOF
}

# G5 — THE NEW SCOPE. The same defect in a `tofu/modules/*/outputs.tf`. Before
#      the F4 widening this case passed silently, because the check only ever
#      read the local profile's file. Tasks 4-10 add eight more such files.
m_type_in_module() {
  inject "$1" tofu/modules/minikube_addons/outputs.tf \
    'output "g_control" {' \
    '  description = "control case G5."' \
    '  type        = bool' \
    '  value       = true' \
    '}'
}

# G6 — every outputs.tf deleted. The guard must fail, and it does so at the
#      required-file check: checks 1 and 2 need the local profile's outputs.tf
#      as their subject. Asserted on THAT diagnostic, because the vacuity
#      branch below is unreachable from this input.
m_no_outputs_files() {
  find "$1/tofu" -name outputs.tf -type f -delete
}

# G6b — the guard's own `find` root mutated to a path that matches nothing, the
#      realistic way the F4 scan silently goes vacuous: a refactor retargets
#      `find` at one directory (or mistypes it) and the scan quietly covers
#      nothing while checks 1 and 2 keep passing on files they still find. This
#      is the only input that reaches the zero-file branch, and it is the defect
#      class the guard exists to prevent, applied to the guard itself.
m_find_root_moved() {
  sed -i.bak \
    's|^output_tf_files="\$(find "\$REPO_ROOT/tofu"|output_tf_files="$(find "$REPO_ROOT/tofu_DOES_NOT_EXIST"|' \
    "$1/$GUARD_REL"
  rm -f "$1/$GUARD_REL.bak"
}

printf 'control suite: scripts/check-local-overrides.sh\n\n'

printf 'red controls (guard MUST fail):\n'
run_case 1 'G1 `type =` on its own line in an output block' \
  m_type_own_line 'FAIL `type =` found on an output block'
run_case 1 'G2 `output "x" { type = bool }` on one line' \
  m_type_one_line 'FAIL `type =` found on an output block'
run_case 1 'G5 `type =` in a tofu/modules/*/outputs.tf' \
  m_type_in_module 'tofu/modules/minikube_addons/outputs.tf'
run_case 1 'G6 every outputs.tf deleted' \
  m_no_outputs_files 'ERROR: missing'
run_case 1 'G6b guard find root matches nothing (vacuous scan)' \
  m_find_root_moved 'found zero tofu/**/outputs.tf files'

printf '\ngreen controls (guard MUST pass):\n'
run_case 0 'G3 `type =` inside a trailing # comment' m_type_trailing_comment
run_case 0 'G4 `type =` inside a quoted description string' m_type_in_string
run_case 0 'G7 unmutated tree' ""

# The real tree must be untouched. The suite copies before it mutates, so this
# is a structural invariant, and it is checked rather than assumed.
cleanup_workdir
after_status="$(git -C "$REPO_ROOT" status --porcelain)"
if [ "$after_status" = "$BASELINE_STATUS" ]; then
  printf '  PASS %-52s tree unchanged from baseline\n' 'G8 working tree byte-identical after suite'
  pass_count=$((pass_count + 1))
else
  printf '  FAIL %-52s tree differs from baseline:\n' 'G8 working tree byte-identical after suite'
  diff <(printf '%s\n' "$BASELINE_STATUS") <(printf '%s\n' "$after_status") | sed 's/^/         | /'
  fail_count=$((fail_count + 1))
fi

printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
if [ "$fail_count" -eq 0 ]; then
  printf 'GUARD CONTROL SUITE PASSED\n'
  exit 0
fi
printf 'GUARD CONTROL SUITE FAILED\n'
exit 1
