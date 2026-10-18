# ADR 009: ArgoCD ApplicationSet with Matrix Generator

**Status:** Accepted
**Date:** 2026-01-15

## Context

We need to deploy multiple services (go-service, node-service, frontend) across multiple environments (dev, staging, production) using ArgoCD. Options:

1. **Individual Application manifests** - One Application per service per environment (9 total)
2. **ApplicationSet with Matrix Generator** - Single ApplicationSet generates Applications from service × environment matrix
3. **ApplicationSet with Git Generator** - Generate from Git directory structure
4. **Helmfile + ArgoCD** - Use helmfile to generate Applications
5. **Manual Application management** - Create/update Applications manually

## Decision

We will use **ArgoCD ApplicationSet with Matrix Generator** to manage multi-service, multi-environment deployments.

### ApplicationSet Structure

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-services
  namespace: argocd
spec:
  generators:
    - matrix:
        generators:
          - git:
              repoURL: https://github.com/romeufcrosa/platform-infra.git
              revision: main
              directories:
                - path: argocd/services/*
          - clusters:
              selector:
                matchLabels:
                  environment: "{{item.path.basename}}"
  template:
    metadata:
      name: "{{item.path.basename}}-{{item.cluster.name}}"
      namespace: argocd
    spec:
      project: "{{item.cluster.name}}"
      source:
        repoURL: https://github.com/romeufcrosa/{{item.path.basename}}.git
        targetRevision: main
        path: helm/{{item.path.basename}}
        helm:
          valueFiles:
            - values-{{item.cluster.name}}.yaml
      destination:
        server: "{{item.cluster.server}}"
        namespace: "{{item.cluster.name}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

### Matrix Dimensions

| Dimension | Values | Description |
|-----------|--------|-------------|
| Services | go-service, node-service, frontend | Platform microservices |
| Environments | dev, staging, production | Deployment environments |

This creates 3 × 3 = 9 Applications automatically.

## Consequences

### Positive
- **Single source of truth** - One ApplicationSet defines all deployments
- **Automatic scaling** - New services/environments added by updating matrix
- **Consistent configuration** - All Applications share same template
- **GitOps native** - Changes via Git PRs, no manual ArgoCD UI actions
- **Environment parity** - Same Helm chart, different values files per environment

### Negative
- **Complexity** - Matrix generator syntax can be confusing
- **Debugging** - Harder to trace which generated Application has issues
- **Coupling** - All services share same sync policy, project structure
- **Cluster dependency** - Requires cluster secrets/labels for environment mapping

### Mitigation
- Document ApplicationSet structure in runbook
- Use `argocd appset generate` to preview generated Applications
- Label clusters with `environment` label for generator
- Keep sync policy simple; override per-service if needed

## Related
- ADR 004: ArgoCD App-of-Apps Pattern
- ADR 010: Helm Environment-Specific Values Files
- ADR 011: GitHub Actions Promotion Workflow