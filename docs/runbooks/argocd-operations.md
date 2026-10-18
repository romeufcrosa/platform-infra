# ArgoCD Operations Runbook

**Repository:** platform-infra  
**Last Updated:** 2026-01-15  
**Owner:** Platform Team

---

## Overview

This runbook covers day-to-day ArgoCD operations for managing applications across staging and production environments.

### Architecture
- **ArgoCD Instance:** Single cluster (minikube dev, EKS prod)
- **Pattern:** App-of-Apps via ApplicationSet (matrix: 3 services × 3 environments)
- **Sync Policy:** Manual for production, automated for staging
- **Projects:** `platform` (all services)

---

## Common Operations

### 1. Check Application Status
```bash
# List all applications
argocd app list

# Get detailed status for specific app
argocd app get frontend-prod

# Check sync status across all apps
argocd app list -o wide | grep -E "(Synced|OutOfSync|Degraded)"
```

### 2. Manual Sync (Production)
```bash
# Dry-run first
argocd app sync frontend-prod --dry-run

# Sync with prune (removes resources not in Git)
argocd app sync frontend-prod --prune

# Sync specific resources only
argocd app sync frontend-prod --resources deployment/frontend
```

### 3. Automated Sync (Staging)
```bash
# Enable auto-sync for staging
argocd app set frontend-staging --sync-policy automated --auto-prune --allow-empty

# Disable auto-sync
argocd app set frontend-staging --sync-policy none
```

### 4. Rollback to Previous Version
```bash
# View history
argocd app history frontend-prod

# Rollback to specific revision
argocd app rollback frontend-prod 3

# Rollback to previous (revision - 1)
argocd app rollback frontend-prod
```

### 5. Diff Against Git
```bash
# Show differences between live and desired state
argocd app diff frontend-prod

# Diff with specific revision
argocd app diff frontend-prod --revision 5
```

---

## Troubleshooting

### Application Stuck in Progressing
**Symptoms:** App shows `Progressing` for >5 minutes

**Diagnosis:**
```bash
# Check pod status
kubectl get pods -n production -l app.kubernetes.io/name=frontend

# Check events
kubectl get events -n production --sort-by=.metadata.creationTimestamp

# Check ArgoCD application controller logs
kubectl logs -n argocd deployment/argocd-application-controller -f
```

**Resolution:**
1. Check for resource quotas/limits
2. Verify image exists in registry
3. Check for stuck finalizers: `kubectl patch <resource> -p '{"metadata":{"finalizers":[]}}' --type=merge`
4. Force terminate: `argocd app terminate-op frontend-prod`

### Application Degraded
**Symptoms:** App shows `Degraded` health

**Diagnosis:**
```bash
# Get health details
argocd app get frontend-prod --show-health

# Check pod conditions
kubectl describe pods -n production -l app.kubernetes.io/name=frontend
```

**Common Causes:**
- Pods not ready (CrashLoopBackOff, ImagePullBackOff)
- HPA not scaling
- NetworkPolicy blocking traffic
- PDB preventing disruption

### Sync Fails with "Resource Quota Exceeded"
**Resolution:**
```bash
# Check quota usage
kubectl describe quota -n production

# Increase quota or scale down other workloads
kubectl patch resourcequota compute-quota -n production -p '{"spec":{"hard":{"requests.cpu":"10"}}}'
```

### ApplicationSet Not Generating Apps
**Diagnosis:**
```bash
# Check ApplicationSet status
kubectl get applicationset -n argocd

# Check generator output
kubectl get applicationset services-applicationset -n argocd -o yaml

# Check controller logs
kubectl logs -n argocd deployment/argocd-applicationset-controller -f
```

**Resolution:**
- Verify Git repository access
- Check matrix generator syntax in `services-applicationset.yaml`
- Ensure target namespace exists

---

## Emergency Procedures

### Full Cluster Recovery
```bash
# 1. Restore ArgoCD from backup (see disaster-recovery.md)
./scripts/restore-argocd.sh s3://bucket/argocd-backup-20260115.tar.gz

# 2. Verify all applications synced
argocd app list

# 3. Force sync any OutOfSync apps
for app in $(argocd app list -o name | grep -E "prod$"); do
  argocd app sync "$app" --prune
done
```

### Nuclear Option: Delete and Recreate App
```bash
# Delete application (keeps resources)
argocd app delete frontend-prod --cascade=false

# Recreate from Git
argocd app create frontend-prod \
  --repo https://github.com/org/platform-infra \
  --path argocd/applications/frontend-prod.yaml \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace production \
  --project platform
```

---

## Monitoring & Alerts

### Key Metrics to Watch
| Metric | Alert Threshold | Action |
|--------|----------------|--------|
| `argocd_app_sync_status` | ≠ 1 (Synced) | Investigate drift |
| `argocd_app_health_status` | ≠ 1 (Healthy) | Check pod health |
| `argocd_application_controller_reconcile_duration_seconds` | >30s | Controller overload |
| `argocd_git_request_duration_seconds` | >10s | Git connectivity issues |

### Grafana Dashboards
- **ArgoCD Overview:** `argocd/overview`
- **Application Health:** `argocd/app-health`
- **Sync Performance:** `argocd/sync-performance`

---

## Maintenance Windows

### Weekly (Monday 09:00 UTC)
- Review OutOfSync applications
- Check for stale ApplicationSet generated apps
- Verify backup completion (see backup-restore.md)

### Monthly (First Sunday 02:00 UTC)
- Upgrade ArgoCD version (test in staging first)
- Review and update RBAC policies
- Clean up old Application revisions (`argocd app history` → keep last 10)

---

## Related Runbooks
- [Promotion Runbook](./promotion.md) - Promoting between environments
- [Disaster Recovery Runbook](./disaster-recovery.md) - Full cluster recovery
- [Backup & Restore Runbook](./backup-restore.md) - ArgoCD backup procedures
- [Chaos Engineering Runbook](./chaos-engineering.md) - ArgoCD chaos experiments

---

## Quick Reference Card

| Task | Command |
|------|---------|
| Login | `argocd login argocd.example.com --sso` |
| List apps | `argocd app list` |
| Get app details | `argocd app get <app-name>` |
| Sync app | `argocd app sync <app-name> --prune` |
| Rollback | `argocd app rollback <app-name> [revision]` |
| Diff | `argocd app diff <app-name>` |
| History | `argocd app history <app-name>` |
| Set auto-sync | `argocd app set <app-name> --sync-policy automated` |
| Terminate op | `argocd app terminate-op <app-name>` |
| Delete app | `argocd app delete <app-name> --cascade=false` |