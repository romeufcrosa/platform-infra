#!/usr/bin/env bash
# Fail if the secret contract has drifted between the two files that must agree:
#
#   scripts/seed-vault.sh                              (the writer)
#   examples/external-secrets/go-service-credentials.yaml  (the reader)
#
# WHY THIS IS A SCRIPT AND NOT A COMMENT. The two files name the same ten
# secrets in two different notations — the seed script writes
# `kv_put platform/go-service/database-url "$PG_DSN"` and the ExternalSecret
# reads `key: platform/go-service/database-url` plus `property: database-url`.
# Nothing in either language ties them together. Rename a path in one and the
# other still validates, still renders, and still reports `Ready=True`; the
# ExternalSecret simply stops finding a secret and reports `SecretSyncedError`
# in the cluster, which nothing local notices. That is the same class of defect
# as an unpinned chart version: two places asserting one fact, neither checked.
#
# It is called `SecretSyncedError` in the cluster and "works fine" everywhere
# else. This is the check that makes the disagreement local.
#
# WHAT IT COMPARES. For every path the seed script writes, the ExternalSecret
# must have a matching `remoteRef.key`, and that key's `property:` must equal
# the path's leaf segment — because the seed script stores each value under a
# key named after the leaf. It also checks the reverse: no `remoteRef.key` in
# the ExternalSecret may be absent from the seed script, because a reader
# pointing at a path nobody writes fails at runtime in exactly the same way.
#
# This covers the Go service only. The Node and frontend paths in the contract
# have no ExternalSecret yet — they are seeded and reserved for Phase 2 — so
# they are checked for well-formedness but not for a reader.
#
# Task 12 wires this into `make verify`. It is standalone and runnable now.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED="$REPO_ROOT/scripts/seed-vault.sh"
EXAMPLE="$REPO_ROOT/examples/external-secrets/go-service-credentials.yaml"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -f "$SEED" ]] || fail "no seed script at $SEED"
[[ -f "$EXAMPLE" ]] || fail "no canonical example at $EXAMPLE"

# --- The paths the seed script writes ---------------------------------------
# Match the two writer calls. `kv_put` and `kv_put_random` are the only things
# that write, so matching the calls rather than parsing a table means a new
# path added by copying an existing line is picked up automatically.
#
# grep -oE with a capture, not awk field-splitting: the arguments are quoted
# and whitespace-aligned for readability, so column positions are not stable.
seeded_paths="$(
  grep -oE '^[[:space:]]*kv_put(_random)?[[:space:]]+[A-Za-z0-9/_-]+' "$SEED" \
    | awk '{print $NF}' \
    | sort -u
)"
[[ -n "$seeded_paths" ]] || fail "found no kv_put calls in $SEED — the parser broke, which looks like a clean contract"

# --- The refs the ExternalSecret reads --------------------------------------
read -r -d '' ref_py <<'PY' || true
import re, sys
text = open(sys.argv[1]).read()
# remoteRef blocks: `key:` on one line, optional `property:` on the next.
pairs = re.findall(r'key:\s*(\S+)\s*\n\s*property:\s*(\S+)', text)
baremode = re.findall(r'key:\s*(\S+)\s*\n(?!\s*property:)', text)
for k, p in pairs:
    print(f"{k}\t{p}")
for k in baremode:
    print(f"{k}\t__MISSING_PROPERTY__")
PY
refs="$(python3 -c "$ref_py" "$EXAMPLE" | sort -u)"

[[ -n "$refs" ]] || fail "found no remoteRef entries in $EXAMPLE — the parser broke"

rc=0

# 1. Every seeded path the example reads must exist in the reader.
while IFS= read -r key; do
  prop="${key##*$'\t'}"
  path="${key%$'\t'*}"
  leaf="${path##*/}"
  if [[ "$prop" == "__MISSING_PROPERTY__" ]]; then
    printf 'FAIL: remoteRef key "%s" has no `property:`.\n' "$path" >&2
    printf '      Without it External Secrets writes the whole Vault entry as a\n'
    printf '      JSON envelope, so the service reads {"%s":"..."} instead of the\n' "$leaf" >&2
    printf '      credential. See the header of %s.\n' "$EXAMPLE" >&2
    rc=1
  elif [[ "$prop" != "$leaf" ]]; then
    printf 'FAIL: remoteRef key "%s" has property "%s"; the seed script stores it under "%s".\n' "$path" "$prop" "$leaf" >&2
    printf '      property: must equal the leaf segment of key:.\n' >&2
    rc=1
  fi
  if ! grep -qxF "$path" <<<"$seeded_paths"; then
    printf 'FAIL: remoteRef key "%s" is read by the example but never written by scripts/seed-vault.sh.\n' "$path" >&2
    rc=1
  fi
done <<<"$refs"

# 2. Every path the Go-service ExternalSecret reads must be seeded.
#    (All other contract paths have no reader yet; see the header.)

# 3. Well-formedness of the paths that have no reader: each must be a
#    non-empty, slash-separated path with at least one slash.
while IFS= read -r path; do
  [[ "$path" == */* ]] || { printf 'FAIL: seeded path "%s" has no slash.\n' "$path" >&2; rc=1; }
  [[ -n "${path##*/}" ]] || { printf 'FAIL: seeded path "%s" has an empty leaf.\n' "$path" >&2; rc=1; }
done <<<"$seeded_paths"

n_seed=$(wc -l <<<"$seeded_paths" | tr -d ' ')
n_ref=$(wc -l <<<"$refs" | tr -d ' ')
if [[ $rc -eq 0 ]]; then
  printf 'secret-contract OK: %s seeded paths, %s refs checked, no drift.\n' "$n_seed" "$n_ref"
fi
exit $rc
