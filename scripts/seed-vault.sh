#!/usr/bin/env bash
# Seed the platform secret paths listed in the Task 9 contract.
# Idempotent: re-running overwrites with fresh random values, which is the
# desired behaviour locally (it is what you want after a cluster reset).
#
# THE PATHS BELOW ARE THE INTERFACE. Phase 2 services read these exact paths
# out of Vault by name; a rename here is a breaking change to every service
# team, which is why they are written out literally rather than derived from
# a loop or a table. The source of truth is the table in the Task 9 brief and
# its copy in docs/runbooks/vault-secrets.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
TOKEN_FILE="${TOKEN_FILE:-local-secrets/vault-root-token}"
PG_DSN="postgres://platform:platform@postgres.platform-system.svc:5432/platform?sslmode=disable"
MINISTACK_EP="http://ministack.ministack.svc.cluster.local:4566"

command -v vault >/dev/null || { echo "vault CLI not found" >&2; exit 1; }
[ -f "$TOKEN_FILE" ] || { echo "no token at $TOKEN_FILE — run 'make deploy-infra' first" >&2; exit 1; }

# Assigned and exported on one line. The brief had these as two lines
# (`export VAULT_TOKEN` then `VAULT_TOKEN="$(cat ...)"`), which does work —
# a bare `export NAME` marks the name for export and a later assignment updates
# the exported value — but it reads like a bug and invites someone to "fix" it
# into one that is a bug. Verified, both forms export the value to children.
VAULT_TOKEN="$(cat "$TOKEN_FILE")"
export VAULT_ADDR VAULT_TOKEN

# The value is stored under a KEY NAMED AFTER THE LEAF SEGMENT OF THE PATH, not
# under a generic `value` key. The brief used `value=`, and that is wrong in a
# way that does not show up until a service actually reads the secret.
#
# `vault kv put secret/platform/go-service/database-url value=<dsn>` writes
# `{"value": "<dsn>"}`. The ExternalSecret's `remoteRef` selects the whole
# secret with no `property:` field, so the Kubernetes key `database-url`
# receives the literal string `{"value":"postgres://..."}` — a JSON envelope,
# not a DSN. Verified on the live cluster before this was fixed:
#
#   database-url = {"value":"postgres://platform:platform@postgres..."}
#
# A Go service doing `os.Getenv("DATABASE_URL")` gets a string that begins with
# `{` and fails to parse at connect time, with an error that names neither
# Vault nor External Secrets. Every service team would have hit it separately.
#
# The brief's own verification step hid this: it read the value back with
# `["data"]["data"]["value"]` — i.e. it asserted the envelope it had just
# created, so it passed. Verifying against the artifact the CONSUMER sees, not
# the one the producer wrote, is the whole point of the read-back below.
#
# Keying by the leaf segment also makes each path a single-purpose secret, which
# is what lets a per-service Vault policy grant `platform/go-service/*` without
# also handing over `platform/node-service/*`.
kv_put() { # kv_put <path> <value> — key = the last segment of <path>
  local key="${1##*/}"
  vault kv put "secret/$1" "$key=$2" >/dev/null && echo "wrote secret/$1 (key: $key)"
}

kv_put_random() { # kv_put_random <path> — 32 bytes of entropy as 64 hex chars
  local key="${1##*/}"
  vault kv put "secret/$1" "$key=$(openssl rand -hex 32)" >/dev/null && echo "wrote secret/$1 (key: $key)"
}

echo "seeding Vault at $VAULT_ADDR"
kv_put platform/go-service/database-url           "$PG_DSN"
kv_put platform/go-service/aws-access-key-id       "test"
kv_put platform/go-service/aws-secret-access-key   "test"
kv_put platform/node-service/database-url          "$PG_DSN"
kv_put platform/node-service/redis-url             "redis://redis.platform-system.svc:6379/0"
kv_put platform/node-service/aws-access-key-id      "test"
kv_put platform/node-service/aws-secret-access-key  "test"
kv_put ministack/endpoint                          "$MINISTACK_EP"
kv_put_random platform/go-service/jwt-secret
kv_put_random platform/frontend/nextauth-secret

# Verify, and verify MORE than the brief did. The brief checked one path
# (go-service/database-url). One check cannot tell "Vault accepted the writes"
# from "Vault accepted these particular writes" — the second path could be
# missing entirely and the check would still print `database-url OK`. Every
# path in the contract is read back and asserted, so a typo in a path is a
# failed seed rather than a mystery for whoever first reads that secret.
echo "--- verifying (all 10 contract paths) ---"
read_back() { # read_back <path> <python expression over `d` that must be true>
  # Reads the LEAF KEY, not `value` — see the note on kv_put. Reading
  # `["value"]` here would assert the JSON envelope rather than the credential,
  # which is precisely the mistake this function exists to catch.
  local key="${1##*/}"
  vault kv get -format=json "secret/$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]["data"][sys.argv[1]]
assert eval(sys.argv[2]), f"unexpected value: {d!r}"
' "$key" "$2"
  echo "  ok  secret/$1"
}

# Every read-back below asserts the EXACT value from the contract table, not a
# shape. Six of these used to assert a URL scheme, which is the defect this
# block exists to prevent: `d.startswith("postgres://")` is satisfied by
# `postgres://wrong:wrong@wrong-host:5432/wrongdb`, so a seed pointed at the
# wrong database would have printed `ok` on every run and nobody would have
# found out until a service failed to connect.
#
# The static values are compared by equality. The two random ones cannot be —
# they are generated per run — so they are asserted structurally (64 lowercase
# hex chars) and, crucially, checked for being DIFFERENT from each other and
# from the previous run's value is not asserted, because re-seeding is supposed
# to change them. What matters for a random secret is that it exists, is the
# right shape, and is not the empty string.
#
# `PG_DSN` and `MINISTACK_EP` are interpolated rather than repeated, so the
# assertion and the write cannot drift apart: both read the same variable.

read_back platform/go-service/database-url          "d == '''$PG_DSN'''"
read_back platform/go-service/jwt-secret            'len(d) == 64 and all(c in "0123456789abcdef" for c in d)'
read_back platform/go-service/aws-access-key-id      'd == "test"'
read_back platform/go-service/aws-secret-access-key  'd == "test"'
read_back platform/node-service/database-url         "d == '''$PG_DSN'''"
read_back platform/node-service/redis-url            'd == "redis://redis.platform-system.svc:6379/0"'
read_back platform/node-service/aws-access-key-id     'd == "test"'
read_back platform/node-service/aws-secret-access-key 'd == "test"'
read_back platform/frontend/nextauth-secret          'len(d) == 64 and all(c in "0123456789abcdef" for c in d)'
read_back ministack/endpoint                         "d == '''$MINISTACK_EP'''"

echo "SEED COMPLETE"
