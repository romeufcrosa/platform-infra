#!/usr/bin/env bash
# Deliver a synthetic GitHub pull_request event to Atlantis and assert it
# acknowledges the delivery. Verifies tunnel + endpoint + secret in one shot.
set -euo pipefail

URL="${ATLANTIS_PUBLIC_URL:?set ATLANTIS_PUBLIC_URL to the cloudflared URL}"
SECRET_FILE="${SECRET_FILE:-local-secrets/atlantis-webhook-secret}"
REPO="${GITHUB_ORG:-romeufcrosa}/$(GITHUB_REPO:-platform-infra)"

[ -f "$SECRET_FILE" ] || { echo "missing $SECRET_FILE — run make deploy-infra" >&2; exit 1; }
SECRET="$(cat "$SECRET_FILE")"

BODY=$(python3 - "$REPO" <<'PY'
import json, sys, time
repo = sys.argv[1]
print(json.dumps({
  "action": "opened",
  "number": 9999,
  "pull_request": {
    "number": 9999,
    "state": "open",
    "title": "smoke: synthetic webhook",
    "head": {"ref": "smoke/synthetic-webhook"},
    "base": {"ref": "main"},
    "user": {"login": "atlantis-smoke"}
  },
  "repository": {"full_name": repo, "name": repo.split("/")[1],
                 "owner": {"login": repo.split("/")[0]}},
  "installation": {"id": 1}
}))
PY
)

SIG="sha256=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"

echo "POST $URL/events (X-Hub-Signature-256: $SIG)"
code=$(curl -s -o /tmp/atlantis-smoke.out -w '%{http_code}' \
  -X POST "$URL/events" \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: pull_request" \
  -H "X-Hub-Signature-256: $SIG" \
  -H "X-GitHub-Delivery: $(uuidgen)" \
  -d "$BODY")
cat /tmp/atlantis-smoke.out; echo
[ "$code" = "200" ] || { echo "FAIL: expected 200, got $code" >&2; exit 1; }
echo "WEBHOOK ACCEPTED — check 'kubectl -n atlantis logs deploy/atlantis' for the lock/plan result"
