#!/usr/bin/env bash
# Fail if the secret contract has drifted between the two files that must agree:
#
#   scripts/seed-vault.sh                                 (the writer)
#   examples/external-secrets/go-service-credentials.yaml (the reader)
#
# WHY THIS IS A SCRIPT AND NOT A COMMENT. The two files name the same secrets in
# two different notations — the seed script writes
# `kv_put platform/go-service/database-url "$PG_DSN"` and the ExternalSecret
# reads `key: platform/go-service/database-url` plus `property: database-url`.
# Nothing in either language ties them together. Rename a path in one and the
# other still validates, still renders, and still reports `Ready=True`; the
# ExternalSecret simply stops finding a secret and reports `SecretSyncedError`
# in the cluster, which nothing local notices. In the cluster it is an error
# string; everywhere else it is "works fine". This is the check that makes the
# disagreement local.
#
# WHAT IT COMPARES, IN BOTH DIRECTIONS. Both directions are required, and the
# first version of this script implemented only one of them.
#
#   reader -> writer  every `remoteRef.key` is written by the seed script, and
#                    its `property:` equals the key's leaf segment (the leaf is
#                    the Vault key the seed stores the value under).
#   writer -> reader  every seeded path is well-formed AND is covered by a
#                    reader — see the asymmetry note below. The earlier version
#                    claimed this check and then did not implement it: deleting
#                    `kv_put platform/node-service/redis-url` still printed
#                    `secret-contract OK: 9 seeded paths, 4 refs checked, no
#                    drift.` with exit 0.
#
# THE ASYMMETRY IS REAL AND DELIBERATE. The seed script seeds TEN paths; the
# canonical ExternalSecret reads FOUR, because it is the Go service and the Node
# and frontend services have no ExternalSecret until Phase 2. So "every seeded
# path has a reader" is FALSE today and asserting it would fail on a correct
# tree. What is enforced instead:
#
#   * every READER path must be WRITTEN        (strict, both directions checked)
#   * every WRITTEN path must be well-FORMED   (strict)
#   * every WRITTEN path must be COVERED       (strict, against the full
#     contract list below, not against the four refs in the example)
#
# `CONTRACT_PATHS` is that list. It is written out here rather than derived,
# because deriving it would be circular — the thing being checked cannot also be
# the definition of correct. The list is a third place to update when a path is
# added, which is the cost, and scripts/seed-vault.sh says so at the point where
# a path is added. It is still better than a gate that reports "no drift" while
# checking one direction.
#
# HOW THE WRITER LIST IS PARSED, AND WHY IT IS EASY TO BREAK. `grep -oE` +
# `awk`, matching the `kv_put` / `kv_put_random` calls rather than a table, so a
# path added by copying a line is picked up automatically. Both steps tolerate
# "no match" — and that tolerance is a trap, because under `set -e` a failing
# `grep` inside a command substitution aborts the assignment before the
# diagnostic below can print, and the script then exits non-zero having said
# NOTHING. That is the worst possible failure mode for a gate, so the guard is
# written to detect the empty result rather than rely on the pipeline status.
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

# The full Phase 1 contract. Every one of these must be written by the seed
# script and be well-formed; four of them must additionally have a reader.
# Keep in sync with scripts/seed-vault.sh — it says so where paths are added.
read -r -d '' CONTRACT_PATHS <<'LIST' || true
ministack/endpoint
platform/frontend/nextauth-secret
platform/go-service/aws-access-key-id
platform/go-service/aws-secret-access-key
platform/go-service/database-url
platform/go-service/jwt-secret
platform/node-service/aws-access-key-id
platform/node-service/aws-secret-access-key
platform/node-service/database-url
platform/node-service/redis-url
LIST

# --- The paths the seed script writes ---------------------------------------
# `|| true` is REQUIRED and is the point of the empty-check immediately after:
# grep exits 1 when it matches nothing, and without `|| true` that would abort
# the assignment under `set -e` and silently kill the diagnostic.
seeded_paths="$(
  grep -oE '^[[:space:]]*kv_put(_random)?[[:space:]]+[A-Za-z0-9/_-]+' "$SEED" \
    | awk '{print $NF}' \
    | sort -u \
    || true
)"
# The guard the previous version got wrong. An empty list here means the parser
# stopped matching — someone renamed the writer call, reformatted the file, or
# moved the seeds. Compare two empty sets and you conclude "no drift", so this
# must be an explicit error, not an empty diff.
if [[ -z "$seeded_paths" ]]; then
  fail "found no kv_put calls in $SEED.
       The parser no longer matches the writer calls, so this script cannot
       compare anything and would otherwise report a clean contract.
       Check for a renamed helper (kv_put -> something else), a reformat, or
       paths moved out of scripts/seed-vault.sh."
fi

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
refs="$(python3 -c "$ref_py" "$EXAMPLE" | sort -u || true)"

if [[ -z "$refs" ]]; then
  fail "found no remoteRef entries in $EXAMPLE.
       The parser no longer matches, so this script cannot compare anything and
       would otherwise report a clean contract. Check the indentation or the
       'key:'/'property:' spelling in the example."
fi

rc=0

# --- DIRECTION 1: every path the READER wants must be WRITTEN ---------------
# (reader -> writer)
while IFS= read -r row; do
  path="${row%$'\t'*}"
  prop="${row##*$'\t'}"
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

# --- DIRECTION 2: every WRITTEN path must be in the contract, and well-formed -
# (writer -> contract). This is the direction that was missing.
while IFS= read -r path; do
  [[ -n "$path" ]] || continue

  if ! grep -qxF "$path" <<<"$CONTRACT_PATHS"; then
    printf 'FAIL: scripts/seed-vault.sh writes "%s", which is not in the contract list in %s.\n' "$path" "${BASH_SOURCE[0]}" >&2
    printf '      Either add it to CONTRACT_PATHS (if it is a real secret) or remove\n'
    printf '      the write. A path in neither list is a secret nobody has agreed to.\n' >&2
    rc=1
  fi

  # well-formedness
  [[ "$path" == */* ]] || { printf 'FAIL: seeded path "%s" has no slash.\n' "$path" >&2; rc=1; }
  [[ -n "${path##*/}" ]] || { printf 'FAIL: seeded path "%s" has an empty leaf.\n' "$path" >&2; rc=1; }

  # Every go-service path must have a reader: the canonical example IS the Go
  # service, so a go-service path with no reader means a line was deleted from
  # the example. Node and frontend paths legitimately have none until Phase 2.
  if ! grep -qF "${path}" <<<"$refs"; then
    case "$path" in
      platform/go-service/*)
        printf 'FAIL: "%s" is a go-service path but has no remoteRef in the canonical example.\n' "$path" >&2
        printf '      The example is the Go service; every go-service path must be read by it.\n' >&2
        rc=1
        ;;
      *)
        printf 'NOTE: "%s" has no reader yet (reserved for Phase 2).\n' "$path"
        ;;
    esac
  fi
done <<<"$seeded_paths"

# --- DIRECTION 3: every contract path must be WRITTEN ----------------------
# This is the check that catches a deleted write. Removing
# `kv_put platform/node-service/redis-url` from the seed script used to pass
# silently; now the path is in CONTRACT_PATHS, nothing writes it, and this
# fails.
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  if ! grep -qxF "$path" <<<"$seeded_paths"; then
    printf 'FAIL: contract path "%s" is never written by scripts/seed-vault.sh.\n' "$path" >&2
    rc=1
  fi
done <<<"$CONTRACT_PATHS"

n_seed=$(grep -c . <<<"$seeded_paths" || true)
n_ref=$(grep -c . <<<"$refs" || true)
n_contract=$(grep -c . <<<"$CONTRACT_PATHS" || true)

if [[ $rc -eq 0 ]]; then
  printf 'secret-contract OK: %s seeded paths, %s refs, %s contract paths; no drift.\n' "$n_seed" "$n_ref" "$n_contract"
else
  printf '\nsecret-contract FAILED: %s seeded paths, %s refs, %s contract paths.\n' "$n_seed" "$n_ref" "$n_contract" >&2
fi
exit $rc