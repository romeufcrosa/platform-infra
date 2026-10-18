# ADR 004: ArgoCD App-of-Apps Pattern

**Status:** Accepted
**Date:** 2026-01-15

## Context

We need to manage deployment of multiple applications across multiple environments (dev, staging, prod). Options:
1. **Single Application** - One ArgoCD Application with all resources
2. **Application per service per environment** - 3 services × 3 envs = 9 Applications
3. **App-of-Apps (ApplicationSet)** - ApplicationSet generates Applications from template
4. **Helm umbrella chart** - Single chart with subcharts

## Decision

We will use **ArgoCD ApplicationSet with Matrix Generator** (App-of-Apps pattern).

### Architecture
```
ApplicationSet (platform-services)
├── Generator: Matrix (services × environments)
│   ├── Services: go-service, node-service, frontend
│   └── Environments: dev, staging, prod
├── Template: Helm chart reference + valueFiles per environment
└── Generated Applications (9 total):
    ├── go-service-dev, go-service-staging, go-service-prod
    ├── node-service-dev, node-service-staging, node-service-prod
    └── frontend-dev, frontend-staging, frontend-prod
```

### Sync Policies
| Environment | Sync Policy | Rationale |
|-------------|-------------|-----------|
| dev | Automated (prune, selfHeal) | Fast feedback, developers own |
| staging | Manual | QA validation required |
| prod | Manual + Sync Windows | Production protection |

## Consequences

### Positive
- **Declarative** - Desired state in Git, ArgoCD reconciles
- **Scalable** - Add services/environments by updating generator
- **Consistent** - Same template for all, reduces drift
- **Auditable** - Git history shows all changes
- **Rollback** - Single-click rollback per application
- **Multi-tenancy** - AppProjects isolate environments

### Negative
- **Learning curve** - ArgoCD concepts (ApplicationSet, AppProject, Sync Windows)
- **Debugging** - Generated Applications harder to inspect
- **Template complexity** - Go templates in YAML can be error-prone
- **Sync windows** - Can delay urgent production fixes

### Mitigation
- Individual Application manifests as fallback (Task 4)
- Comprehensive runbooks for ArgoCD operations
- Sync windows only for prod, with emergency override process
- Automated tests in CI before merge to main

## Related
- ADR 001: Multi-Repository Architecture
- ADR 006: External Secrets with Vault