# ADR 010: Helm Environment-Specific Values Files

**Status:** Accepted
**Date:** 2026-01-15

## Context

We need to configure Helm charts differently for dev, staging, and production environments. Options:

1. **Single values.yaml with conditionals** - Use `.Values.environment` and `if` statements in templates
2. **Separate values files per environment** - `values-dev.yaml`, `values-staging.yaml`, `values-production.yaml`
3. **Kustomize overlays** - Base chart + environment overlays
4. **Helm post-renderer** - Transform rendered manifests per environment
5. **Values file + environment variables** - Base values + env var overrides

## Decision

We will use **separate values files per environment** (`values-{dev,staging,production}.yaml`) referenced by the ApplicationSet.

### File Structure

```
helm/
├── go-service/
│   ├── values.yaml           # Base defaults (shared)
│   ├── values-dev.yaml       # Dev overrides
│   ├── values-staging.yaml   # Staging overrides
│   └── values-production.yaml # Production overrides
├── node-service/
│   ├── values.yaml
│   ├── values-dev.yaml
│   ├── values-staging.yaml
│   └── values-production.yaml
└── frontend/
    ├── values.yaml
    ├── values-dev.yaml
    ├── values-staging.yaml
    └── values-production.yaml
```

### Base Values (values.yaml)

Contains defaults shared across all environments:
- Image repository (without tag)
- Resource requests/limits (conservative)
- Service ports
- Common labels/annotations
- Default affinity, tolerations

### Environment Overrides

| Environment | Key Differences |
|-------------|-----------------|
| **dev** | `replicaCount: 1`, `autoscaling.enabled: false`, `image.tag: dev`, `resources` minimal, `ingress.enabled: false`, `podDisruptionBudget.enabled: false`, `networkPolicy.enabled: false` |
| **staging** | `replicaCount: 2`, `autoscaling.enabled: true`, `minReplicas: 2`, `image.tag: staging`, `resources` moderate, `ingress.enabled: true`, `podDisruptionBudget.enabled: true`, `networkPolicy.enabled: true` |
| **production** | `replicaCount: 3`, `autoscaling.enabled: true`, `minReplicas: 3`, `image.tag: <semver>`, `resources` generous, `ingress.enabled: true` with TLS, `podDisruptionBudget.enabled: true` with `minAvailable: 50%`, `networkPolicy.enabled: true` with strict rules |

### ApplicationSet Reference

```yaml
spec:
  template:
    spec:
      source:
        helm:
          valueFiles:
            - values-{{item.cluster.name}}.yaml
```

## Consequences

### Positive
- **Clear separation** - Environment differences explicit in files
- **Git diff friendly** - Changes to one environment don't affect others
- **Reviewable** - PR shows exactly what changes per environment
- **No template logic** - Templates stay simple, no `if .Values.environment == "production"`
- **Override chain** - Base values + env file = complete config

### Negative
- **Duplication** - Some values repeated across env files
- **Drift risk** - Easy to forget to update all env files when adding new config
- **File count** - 3 files per service × 3 services = 9 files to maintain

### Mitigation
- Use `helm template -f values-dev.yaml -f values-staging.yaml` to compare
- Document required keys in base values.yaml comments
- CI check: `helm template` for all environments must succeed
- Keep base values.yaml comprehensive; env files only override

## Example: go-service values-production.yaml

```yaml
replicaCount: 3

image:
  repository: ghcr.io/romeufcrosa/go-service
  tag: "v1.2.3"

resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 250m
    memory: 256Mi

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 20
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 10
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 15
        - type: Pods
          value: 4
          periodSeconds: 15
      selectPolicy: Max

podDisruptionBudget:
  enabled: true
  minAvailable: 50%

networkPolicy:
  enabled: true
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              name: postgres
      ports:
        - protocol: TCP
          port: 5432
    - to:
        - namespaceSelector:
            matchLabels:
              name: ministack
      ports:
        - protocol: TCP
          port: 4566

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/rate-limit: "100"
  hosts:
    - host: go-service.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: go-service-tls
      hosts:
        - go-service.example.com
```

## Related
- ADR 009: ArgoCD ApplicationSet with Matrix Generator
- ADR 008: Production Hardening Standards