# Promotion Runbook

**Repository:** platform-infra  
**Last Updated:** 2026-01-15  
**Owner:** Platform Team

---

## Overview

This runbook covers promoting applications between environments (dev → staging → production) using the promotion workflows and CLI.

### Promotion Flow
```
dev (auto-sync) → staging (auto-sync) → production (manual)
     │                │                      │
     │                │                      └─ Requires approval
     │                └─ Auto-promote on main branch
     └─ Auto-sync on feature branch merge
```

### Promotion Methods
1. **GitHub Actions Workflow** (Recommended) - UI-driven, audited, gated
2. **CLI Script** (`./scripts/promote.sh`) - Interactive, flexible, local
3. **ArgoCD UI** - Direct sync (emergency only)

---

## GitHub Actions Promotion

### Workflow Structure
```
promote.yaml (platform-infra)           # Orchestrator
├── platform-services-go/.github/workflows/promote.yaml
├── platform-services-node/.github/workflows/promote.yaml
└── platform-frontend/.github/workflows/promote.yaml
```

### Triggering Promotion
```bash
# Via GitHub CLI
gh workflow run promote.yaml \
  -f environment=production \
  -f services=go-service,node-service,frontend \
  -f version=v1.2.3 \
  -f dry_run=false

# Via GitHub UI
# 1. Go to Actions → Promote to Production
# 2. Click "Run workflow"
# 3. Select environment, services, version
# 4. Run workflow
```

### Workflow Stages
| Stage | Description | Gates |
|-------|-------------|-------|
| `validate` | Check manifests, Helm render, policy | Must pass |
| `load-test` | Run k6 load tests (staging) | Thresholds must pass |
| `promote` | Update Helm values, commit, push | Manual approval (prod) |
| `verify` | Verify deployment, health checks | All checks pass |
| `notify` | Slack, GitHub release, metrics | Always runs |

### Promotion to Staging (Auto)
```yaml
# Triggered on: push to main branch
# Services: All changed services
# Approval: None (auto)
# Verification: Health checks only
```

### Promotion to Production (Manual)
```yaml
# Triggered on: workflow_dispatch
# Services: Selected via input
# Approval: Required (environment protection rules)
# Verification: Full health checks + load test gate
```

### Monitoring Promotion
```bash
# Watch workflow
gh run watch --workflow=promote.yaml

# Check specific service promotion
gh run view <run-id> --log | grep -A5 "go-service"

# View promotion status in ArgoCD
argocd app get go-service-production
```

---

## CLI Promotion Script

### Script Location
`platform-infra/scripts/promote.sh`

### Usage
```bash
# Interactive mode (recommended)
./scripts/promote.sh

# Non-interactive
./scripts/promote.sh \
  --environment production \
  --services go-service,frontend \
  --version v1.2.3 \
  --dry-run

# Rollback
./scripts/promote.sh --rollback --environment production --services go-service
```

### Interactive Flow
```
$ ./scripts/promote.sh

╔══════════════════════════════════════════════════════════════╗
║           Platform Promotion CLI v1.0.0                       ║
╚══════════════════════════════════════════════════════════════╝

Select environment:
  1) staging
  2) production
> 2

Select services (comma-separated, or 'all'):
  Available: go-service, node-service, frontend
> go-service,frontend

Enter version/tag (or 'latest'):
> v1.2.3

Dry run? [y/N]: y

══════════════════════════════════════════════════════════════
DRY RUN - No changes will be made
══════════════════════════════════════════════════════════════

[go-service] Would update values-production.yaml:
  - image.tag: v1.2.2 → v1.2.3
  - replicaCount: 3 → 3

[frontend] Would update values-production.yaml:
  - image.tag: v1.2.2 → v1.2.3
  - replicaCount: 5 → 5

Proceed with actual promotion? [y/N]: y

[INFO] Creating git branch: promote/go-service-frontend-v1.2.3-20260115
[INFO] Updating Helm values files...
[INFO] Committing changes...
[INFO] Pushing branch...
[INFO] Creating PR #247...
[INFO] Waiting for PR checks...
[INFO] PR #247 merged!
[INFO] Triggering ArgoCD sync...
[INFO] Verifying deployment...
[INFO] Promotion complete!
```

### Dry Run Output
```bash
$ ./scripts/promote.sh --environment production --services go-service --version v1.2.3 --dry-run

DRY RUN: Would promote go-service to production at v1.2.3

Changes to platform-infra/argocd/applications/go-service-production.yaml:
  - spec.source.helm.parameters[0].value: "v1.2.2" → "v1.2.3"

Helm values changes (platform-services-go/helm/go-service/values-production.yaml):
  - image.tag: "v1.2.2" → "v1.2.3"
  - replicaCount: 3 (unchanged)
  - resources.limits.cpu: "1000m" (unchanged)
```

### Rollback
```bash
# Rollback last promotion
./scripts/promote.sh --rollback --environment production --services go-service

# Rollback to specific version
./scripts/promote.sh --rollback --environment production --services go-service --version v1.2.2
```

---

## Pre-Promotion Checklist

### For Staging
- [ ] All PRs merged to main
- [ ] CI passes for all services
- [ ] No outstanding incidents

### For Production
- [ ] Staging deployed and healthy for ≥ 30 minutes
- [ ] Load tests pass in staging (last 24h)
- [ ] No critical/severe bugs in staging
- [ ] Change approved by Tech Lead
- [ ] On-call engineer notified
- [ ] Rollback plan documented
- [ ] Maintenance window confirmed (if required)

---

## Verification Procedures

### Automated Verification (Post-Promotion)
```bash
# Runs automatically via verify-promotion.sh
./scripts/verify-promotion.sh --environment production --services go-service,frontend
```

**Checks Performed:**
| Check | Description | Timeout |
|-------|-------------|---------|
| Deployment Ready | `readyReplicas == desiredReplicas` | 5m |
| Pods Healthy | All pods `Ready=True`, no restarts | 5m |
| Service Endpoints | Endpoints exist for all services | 2m |
| Ingress | Ingress has valid address, TLS cert | 3m |
| PDB | PodDisruptionBudget exists, healthy | 2m |
| NetworkPolicy | NetworkPolicy applied, allows traffic | 2m |
| HPA | HorizontalPodAutoscaler configured, active | 2m |
| ServiceMonitor | Prometheus scraping configured | 2m |
| ArgoCD Synced | App status `Synced` + `Healthy` | 5m |
| Application Health | Custom health endpoint returns 200 | 3m |

### Manual Verification
```bash
# 1. Check ArgoCD
argocd app list | grep production

# 2. Check pods
kubectl get pods -n production -l app.kubernetes.io/instance=go-service

# 3. Test endpoints
curl -f https://api.example.com/health
curl -f https://api.example.com/api/v1/orders

# 4. Check logs
kubectl logs -n production deployment/go-service --since=5m | grep -i error

# 5. Check metrics
# Grafana: production/overview dashboard
```

### Smoke Tests
```bash
# Run post-promotion smoke tests
./scripts/smoke-tests.sh --environment production

# Tests:
# - Create order → verify in DB
# - List orders → verify response
# - WebSocket connect → receive notification
# - Frontend loads → check critical paths
```

---

## Emergency Promotion

### Hotfix Promotion (Bypass Staging)
**Use only for:** Critical production bugs, security patches

```bash
# 1. Create hotfix branch from production tag
git checkout tags/v1.2.3 -b hotfix/security-patch

# 2. Apply fix, test locally

# 3. Promote directly to production
./scripts/promote.sh \
  --environment production \
  --services go-service \
  --version v1.2.4-hotfix1 \
  --skip-staging

# 4. Backport to main/staging after
git checkout main
git merge hotfix/security-patch
```

### ArgoCD Direct Sync (Last Resort)
```bash
# Only if promotion pipeline broken
argocd app sync go-service-production --prune --force

# Verify immediately
argocd app get go-service-production
kubectl get pods -n production -l app=go-service
```

---

## Troubleshooting

### Promotion Workflow Fails at Validation
```bash
# Check Helm render
cd platform-services-go
helm template go-service ./helm/go-service -f ./helm/go-service/values-production.yaml

# Check for policy violations
kubectl apply --dry-run=server -f <(helm template ...)
```

### Promotion Workflow Fails at Load Test
```bash
# View load test results
gh run view <run-id> --log | grep -A20 "load-test"

# Common issues:
# - Staging not at baseline (recent deploy?)
# - Test thresholds too strict
# - Infrastructure capacity (increase HPA maxReplicas)
```

### ArgoCD Not Syncing After Promotion
```bash
# Check ArgoCD application
argocd app get go-service-production

# Check repository connection
argocd repo list

# Force refresh
argocd app sync go-service-production --prune

# Check controller logs
kubectl logs -n argocd deployment/argocd-application-controller | grep go-service-production
```

### Verification Fails
```bash
# Run verification with debug
./scripts/verify-promotion.sh --environment production --services go-service --verbose

# Common failures:
# - Pods not ready: check events, resources, image pull
# - Ingress not ready: check cert-manager, DNS
# - PDB violation: wait for pods to stabilize
# - HPA not active: check metrics server
```

### Rollback Fails
```bash
# Manual rollback via Git
cd platform-infra
git revert <promotion-commit-sha>
git push origin main

# Or via ArgoCD
argocd app rollback go-service-production
```

---

## Post-Promotion

### Required Actions
- [ ] Update deployment tracker (Notion/Jira)
- [ ] Monitor error rates for 30 minutes
- [ ] Verify business metrics (orders, signups)
- [ ] Close related tickets
- [ ] Update runbook if new issues found

### Monitoring Window
| Period | Focus |
|--------|-------|
| 0-15 min | Error rates, latency, pod health |
| 15-60 min | Business metrics, user reports |
| 1-24 hours | SLO compliance, capacity |
| 24h+ | Normal monitoring |

---

## Related Runbooks
- [ArgoCD Operations](./argocd-operations.md) - Sync, rollback, troubleshooting
- [Load Testing](./load-testing.md) - Load test as promotion gate
- [Backup & Restore](./backup-restore.md) - Pre-promotion backup
- [Disaster Recovery](./disaster-recovery.md) - Failed promotion recovery

---

## Quick Reference

| Task | Command |
|------|---------|
| Interactive promote | `./scripts/promote.sh` |
| CLI promote (prod) | `./scripts/promote.sh -e production -s go-service -v v1.2.3` |
| Dry run | `./scripts/promote.sh -e production -s all -v v1.2.3 --dry-run` |
| Rollback | `./scripts/promote.sh --rollback -e production -s go-service` |
| GH Actions promote | `gh workflow run promote.yaml -f environment=production` |
| Verify promotion | `./scripts/verify-promotion.sh -e production -s all` |
| Smoke tests | `./scripts/smoke-tests.sh -e production` |
| View ArgoCD | `argocd app get <app>-production` |