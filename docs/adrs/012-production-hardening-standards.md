# ADR 012: Production Hardening Standards

**Status:** Accepted
**Date:** 2026-01-15

## Context

We need to define mandatory security and reliability standards for all production workloads. These standards apply to all services deployed to the `production` namespace.

## Decision

All production deployments **MUST** implement the following hardening standards. These are enforced via Helm chart defaults and CI validation.

### 1. Pod Security Standards (Restricted)

```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault

securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
```

**Requirements:**
- `runAsNonRoot: true` - Container cannot run as root
- `readOnlyRootFilesystem: true` - No writes to container filesystem
- `allowPrivilegeEscalation: false` - Prevent privilege escalation
- `capabilities.drop: ["ALL"]` - Drop all Linux capabilities
- `seccompProfile: RuntimeDefault` - Default seccomp profile

### 2. Pod Disruption Budget

```yaml
podDisruptionBudget:
  enabled: true
  minAvailable: 50%  # Or specific number: minAvailable: 2
```

**Requirements:**
- `enabled: true` for all production deployments
- `minAvailable: 50%` minimum (or absolute number ensuring quorum)
- Max unavailable: 1 for stateful workloads

### 3. Network Policy

```yaml
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
    - to: []
      ports:
        - protocol: TCP
          port: 53
        - protocol: UDP
          port: 53
```

**Requirements:**
- `enabled: true` for all production deployments
- **Default deny** - Explicit allow rules only
- **Ingress**: Only from ingress-nginx (or internal service mesh)
- **Egress**: Only to required dependencies (PostgreSQL, Redis, Ministack, DNS)
- **No catch-all egress** - Block unknown destinations

### 4. Horizontal Pod Autoscaler with Behavior Config

```yaml
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
```

**Requirements:**
- `enabled: true` for all production deployments
- `minReplicas: 3` minimum for HA
- `behavior.scaleDown.stabilizationWindowSeconds: 300` (5 min) - Prevent thrashing
- `behavior.scaleUp.selectPolicy: Max` - Aggressive scale-up for latency

### 5. Pod Anti-Affinity

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app.kubernetes.io/name
                operator: In
                values:
                  - {{ .Release.Name }}
          topologyKey: kubernetes.io/hostname
```

**Requirements:**
- Spread pods across nodes (soft anti-affinity)
- `topologyKey: kubernetes.io/hostname` for node-level spreading
- Weight: 100 (highest preference)

### 6. Resource Limits and Requests

```yaml
resources:
  limits:
    cpu: 1000m
    memory: 1Gi
  requests:
    cpu: 500m
    memory: 512Mi
```

**Requirements:**
- **Limits = 2x Requests** (QoS: Burstable, not Guaranteed)
- CPU limit ≤ 2000m (2 cores)
- Memory limit ≤ 2Gi
- Requests set to handle baseline load

### 7. Liveness and Readiness Probes

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /ready
    port: http
  initialDelaySeconds: 5
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
```

**Requirements:**
- Separate `/health` (liveness) and `/ready` (readiness) endpoints
- Readiness must check dependencies (DB, cache, upstream)
- Liveness only checks process health

### 8. Image Pull Policy and Verification

```yaml
image:
  pullPolicy: IfNotPresent  # Or Always for :latest
  # For production, use specific tags, not :latest
```

**Requirements:**
- **Never use `:latest` tag in production**
- Use semantic version tags: `v1.2.3`
- `pullPolicy: IfNotPresent` (images pre-pulled by node)
- Image signing verification (cosign) - future enhancement

### 9. Service Account and RBAC

```yaml
serviceAccount:
  create: true
  name: "{{ .Release.Name }}"
  annotations: {}
```

**Requirements:**
- Dedicated ServiceAccount per service
- Minimal RBAC (only required permissions)
- No cluster-admin bindings

### 10. Ingress with TLS

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/rate-limit: "100"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
  tls:
    - secretName: "{{ .Release.Name }}-tls"
      hosts:
        - "{{ .Release.Name }}.example.com"
```

**Requirements:**
- TLS termination at ingress (cert-manager + Let's Encrypt)
- Rate limiting annotation
- HSTS and secure headers via ingress annotations

## Enforcement

### CI Validation (GitHub Actions)

```yaml
# .github/workflows/helm-lint.yaml
- name: Validate production hardening
  run: |
    for env in production; do
      for chart in helm/*/; do
        helm template test "$chart" -f "$chart/values-$env.yaml" | \
          ./scripts/validate-hardening.sh
      done
    done
```

### validate-hardening.sh checks:
1. `runAsNonRoot: true` present
2. `readOnlyRootFilesystem: true` present
3. `capabilities.drop: ["ALL"]` present
4. `podDisruptionBudget.enabled: true` present
5. `networkPolicy.enabled: true` present
5. `autoscaling.enabled: true` present
6. `affinity.podAntiAffinity` present
7. No `:latest` image tag
8. `livenessProbe` and `readinessProbe` configured
9. Resources limits/requests set

### ArgoCD Pre-Sync Hook (Optional)

Validate before sync:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Validate=true
```

## Compliance Matrix

| Standard | Dev | Staging | Production | Enforcement |
|----------|-----|---------|------------|-------------|
| runAsNonRoot | ✅ | ✅ | ✅ (required) | CI + Admission |
| readOnlyRootFS | ❌ | ✅ | ✅ (required) | CI + Admission |
| drop ALL caps | ❌ | ✅ | ✅ (required) | CI + Admission |
| PodDisruptionBudget | ❌ | ✅ | ✅ (required) | CI |
| NetworkPolicy | ❌ | ✅ | ✅ (required) | CI + CNI |
| HPA + behavior | ❌ | ✅ | ✅ (required) | CI |
| Pod Anti-Affinity | ❌ | ✅ | ✅ (required) | CI |
| Resource limits | ✅ | ✅ | ✅ (required) | CI |
| Probes | ✅ | ✅ | ✅ (required) | CI |
| No :latest tag | ✅ | ✅ | ✅ (required) | CI |
| TLS Ingress | ❌ | ✅ | ✅ (required) | CI |

## Exceptions

Exceptions require **Security Review** and **Platform Lead approval**:
1. Legacy workloads needing privileged access
2. Init containers requiring filesystem writes
3. Sidecars with different security profiles

Document exception in ADR appendix with:
- Justification
- Compensating controls
- Expiration date
- Owner

## Related
- ADR 007: Distroless Base Images
- ADR 010: Helm Environment-Specific Values Files
- ADR 011: GitHub Actions Promotion Workflow