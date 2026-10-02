# One shared database credential for Go and Node

- Status: Accepted
- Date: 2026-10-02

## Context and Problem Statement

The secret contract seeded into Vault (`scripts/seed-vault.sh`) carries a
PostgreSQL DSN at two paths:

- `platform/go-service/database-url`
- `platform/node-service/database-url`

Both point at the same database, `platform`, as the same role, `platform`, with
the same password. A reader of the contract could reasonably take that for an
oversight and "fix" it by minting a second role for one service.

## Decision

The credential is deliberately shared in Phase 1, and the seed script writes
both paths from a single `PG_DSN` variable so the sameness is visible in the
source rather than coincidental.

## Rationale

The production design is separate credentials per service — a `go_service` and
a `node_service` role, each with its own password — so that one service's
credentials can be rotated or revoked without touching the other. That is the
right design and it is not what Phase 1 does.

The reasons are cost, not preference:

1. **Scope.** This is a learning platform on a disposable minikube cluster
   (ADR-0002). A second role is a second thing to provision, rotate, tear down
   and explain, bought in exchange for a property nobody can observe on a
   cluster that gets deleted weekly.
2. **The demonstration is not about credential isolation.** The exercise this
   serves is the Vault → External Secrets → Kubernetes Secret path. One
   credential exercises that path completely. Two would exercise it identically
   and teach nothing additional.
3. **It stays honest.** Both paths are named per service, so the shape Phase 2
   needs is already in the contract. Splitting the credential later is a change
   to two values in one script, not a contract redesign — which is precisely why
   writing it this way now is cheap.

## Consequences

- A leaked `platform` password compromises both services. Accepted knowingly.
- Rotating the shared credential requires restarting both services. Accepted for
  Phase 1; it becomes a per-service operation when the roles are split.
- **Phase 2 must revisit this.** When real services with real data exist, split
  the role per service before the credential is trusted with anything worth
  protecting. The two paths already exist, so the change is confined to
  `scripts/seed-vault.sh` and whatever issues the two `CREATE ROLE` statements.
- Anything written against this decision should link here rather than
  re-deriving it — the sameness is a decision, and a reader who assumes it is a
  bug will eventually fix it.