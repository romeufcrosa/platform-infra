# ADR 008: Shared PostgreSQL with Separate Schemas

**Status:** Accepted
**Date:** 2026-01-15

## Context

We need to decide on database architecture for multiple services. Options:
1. **Shared database, shared schema** - All services use same tables
2. **Shared database, separate schemas** - Each service owns a schema
3. **Separate databases per service** - Full isolation
4. **Separate database instances** - Maximum isolation

## Decision

We will use **shared PostgreSQL cluster with separate schemas per service**.

### Schema Allocation
| Service | Schema | Tables |
|---------|--------|--------|
| platform-services-go | `orders` | orders, order_items, customers |
| platform-services-node | `notifications` | notifications, subscriptions, preferences |
| platform-frontend | `frontend` | sessions, users, settings |

### Connection Pooling
- **PgBouncer** in transaction mode for all services
- Separate connection pools per service/schema
- Max connections: 100 per service

## Consequences

### Positive
- **Resource efficiency** - Single PostgreSQL instance, shared memory/CPU
- **Operational simplicity** - One database to backup, monitor, upgrade
- **Cross-service queries** - Possible for reporting/analytics (with care)
- **Transaction support** - Can use distributed transactions if needed
- **Cost effective** - Fewer managed database instances

### Negative
- **Noisy neighbor** - One service's load affects others
- **Schema coupling** - Migration coordination required
- **Blast radius** - Database outage affects all services
- **Permission complexity** - Need schema-level grants
- **Backup granularity** - pg_dump per schema, not per database

### Mitigation
- **Resource quotas** - CPU/memory limits per service via Kubernetes
- **PgBouncer pools** - Separate pools with max_client_conn per service
- **Schema ownership** - Each service owns its schema exclusively
- **Migration process** - Coordinated migrations via GitOps
- **Monitoring** - Per-schema query performance tracking

## Connection Strings
```
# Go Service
postgres://user:pass@pgbouncer:6432/orders

# Node Service
postgres://user:pass@pgbouncer:6432/notifications

# Frontend
postgres://user:pass@pgbouncer:6432/frontend
```

## Related
- ADR 001: Multi-Repository Architecture
- ADR 006: External Secrets with Vault