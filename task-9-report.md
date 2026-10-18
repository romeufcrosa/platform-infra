# Task 9 Report: Vault and Secret Material Contract

## Fix round 3

### What was done
- Added variables `REDIS_URL="redis://redis.platform-system.svc:6379/0"` and `TEST_VALUE="test"` to `scripts/seed-vault.sh` to avoid duplicating literals.
- Updated `kv_put` calls:
  - `platform/go-service/aws-access-key-id` and `platform/go-service/aws-secret-access-key` now use `"$TEST_VALUE"`
  - `platform/node-service/aws-access-key-id` and `platform/node-service/aws-secret-access-key` now use `"$TEST_VALUE"`
  - `platform/node-service/redis-url` now uses `"$REDIS_URL"`
  - Other secrets (`platform/go-service/database-url`, `platform/node-service/database-url`, `ministack/endpoint`) continue to use their existing variables (`PG_DSN`, `MINISTACK_EP`).
- Changed read-back assertions for three fixed-string secrets to use hard‑coded strings from the brief:
  - `platform/go-service/database-url`: assertion now is `'d == "postgres://platform:platform@postgres.platform-system.svc:5432/platform?sslmode=disable"'`
  - `platform/node-service/database-url`: assertion now is `'d == "postgres://platform:platform@postgres.platform-system.svc:5432/platform?sslmode=disable"'`
  - `ministack/endpoint`: assertion now is `'d == "http://ministack.ministack.svc.cluster.local:4566"'`
  (The read‑back for `platform/node-service/redis-url` and the four test AWS secrets already used hard‑coded strings and were left unchanged.)
- Updated the comment above the read‑back block to explain that write operations use variables to avoid duplicating literals, read‑back uses hard‑coded strings from the brief, and that if the expected value changes both the variable and the hard‑coded string must be updated.

### Verification performed
- Syntax check: `bash -n scripts/seed-vault.sh` passed (no output).
- Confirmed `set -euo pipefail` is present in the script.
- Verified the script contains no `|| echo` or `|| true` constructs that could swallow failures.
- Reviewed the diff to ensure only the intended lines were changed.
- After committing the changes (commit 754230f), the following verification steps were run and passed:
  - `tofu fmt -check -recursive`: clean
  - `tofu validate`: Success
  - `make validate`: exit 0 (vault actively templated)
  - R29b check: `kubectl kustomize kubernetes/platform-system | grep -cE '^kind: (Deployment|Service|ServiceAccount|Job|Namespace)'` returned `0`.
  - `scripts/seed-vault.sh`: runs to completion with output "SEED COMPLETE" and all ten exact-value read-backs passing.
  - Vault workload: `vault-0 1/1 Running`, unsealed.
  - ClusterSecretStore: `Ready=True`.
  - ExternalSecret example: present and correct in `examples/external-secrets/go-service-credentials.yaml`.

### Concerns
- The AppProject invariant (mentioned in the seed script comments) has no executable test in the repository, so we cannot verify it programmatically.
- The `CONTRACT_PATHS` variable (if it exists elsewhere) could become a third place to update if the contract changes, but we did not encounter such a variable in our changes; the contract is sourced from the brief and `docs/runbooks/vault-secrets.md`.
- The prometheus schema claim in the comment (regarding the 64‑hex‑character nature of `jwt-secret` and `nextauth-secret`) was not verified by us, but it matches the brief and we did not alter those assertions.
