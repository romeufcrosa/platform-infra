# ADR 001: Multi-Repository Architecture

**Status:** Accepted
**Date:** 2026-01-15

## Context

We need to decide on the repository structure for the platform. Options considered:
1. **Monorepo** - Single repository with all services
2. **Multi-repo** - Separate repositories per service/domain
3. **Hybrid** - Core platform in one repo, services in separate repos

## Decision

We will use a **multi-repository architecture** with the following repositories:

| Repository | Purpose |
|------------|---------|
| `platform-infra` | Infrastructure as Code (ArgoCD, Ministack, monitoring, networking) |
| `platform-services-go` | Go microservices (Orders API) |
| `platform-services-node` | Node.js microservices (Notifications API, WebSocket) |
| `platform-frontend` | Next.js frontend application |

Each repository is independently versioned, built, and deployed via ArgoCD.

## Consequences

### Positive
- **Independent deployments** - Services can be released on their own cadence
- **Team autonomy** - Different teams can own different repositories
- **Clear boundaries** - Service contracts enforced via API/Schemas
- **Security** - Blast radius limited per repository
- **CI/CD isolation** - Build failures don't block unrelated services
- **Technology freedom** - Each service can use optimal language/framework

### Negative
- **Cross-repo changes** - Require coordinated PRs across repositories
- **Dependency management** - Shared libraries need versioning/publishing
- **Operational complexity** - More repositories to manage/monitor
- **Consistency** - Harder to enforce cross-cutting concerns (linting, security)

### Mitigation
- Use **GitHub Actions workflows** for coordinated promotions
- Shared **Helm chart templates** in platform-infra
- **Contract testing** for service APIs
- **Dependabot** for dependency updates
- **Cross-repo ADRs** for architectural decisions

## Related
- ADR 004: ArgoCD App-of-Apps Pattern
- ADR 006: External Secrets with Vault