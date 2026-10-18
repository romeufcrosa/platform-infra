# Backup & Restore Runbook

**Repository:** platform-infra  
**Last Updated:** 2026-01-15  
**Owner:** Platform Team

---

## Overview

This runbook covers backup and restore procedures for all critical platform components.

### Backup Schedule
| Component | Frequency | Retention | Storage |
|-----------|-----------|-----------|---------|
| PostgreSQL | Daily 02:00 UTC | 30 days | S3 (versioned) |
| Vault | Daily 02:30 UTC | 90 days | S3 (versioned) |
| ArgoCD | Daily 03:00 UTC | 30 days | S3 (versioned) |
| Kubernetes Resources | On-demand | 7 days | S3 |

### S3 Bucket Structure
```
s3://platform-backups/
├── postgres/
│   ├── 2026-01-15/
│   │   ├── all-databases.sql.gz
│   │   └── manifest.json
├── vault/
│   ├── 2026-01-15/
│   │   ├── secrets.json.gz
│   │   └── manifest.json
├── argocd/
│   ├── 2026-01-15/
│   │   ├── argocd-backup.tar.gz
│   │   └── manifest.json
└── kubernetes/
    └── 2026-01-15/
        ├── resources.yaml
        └── manifest.json
```

---

## PostgreSQL Backup & Restore

### Automated Backup (CronJob)
```bash
# Check CronJob status
kubectl get cronjob -n database postgres-backup

# View last run
kubectl get jobs -n database -l cronjob-name=postgres-backup --sort-by=.metadata.creationTimestamp

# View logs
kubectl logs -n database job/postgres-backup-20260115
```

### Manual Backup
```bash
# Run backup script directly
./scripts/backup-postgres.sh

# Or with custom parameters
./scripts/backup-postgres.sh \
  --namespace database \
  --postgres-cluster platform-postgres \
  --bucket s3://platform-backups/postgres \
  --retention-days 30
```

### Restore PostgreSQL
```bash
# List available backups
aws s3 ls s3://platform-backups/postgres/ --recursive

# Restore specific backup
./scripts/restore-postgres.sh \
  --namespace database \
  --postgres-cluster platform-postgres \
  --backup-file s3://platform-backups/postgres/2026-01-15/all-databases.sql.gz

# Restore specific database only
./scripts/restore-postgres.sh \
  --namespace database \
  --postgres-cluster platform-postgres \
  --backup-file s3://platform-backups/postgres/2026-01-15/all-databases.sql.gz \
  --database orders_db
```

### Point-in-Time Recovery (PITR)
```bash
# If using WAL-G or pgBackRest for PITR
# Stop writes to database
kubectl scale deployment orders-api -n production --replicas=0

# Restore to specific timestamp
wal-g backup-fetch LATEST --target-time "2026-01-15 14:30:00"

# Verify data integrity
psql -h postgres.database.svc -U postgres -c "SELECT count(*) FROM orders;"

# Resume writes
kubectl scale deployment orders-api -n production --replicas=3
```

---

## Vault Backup & Restore

### Automated Backup (CronJob)
```bash
# Check CronJob status
kubectl get cronjob -n vault vault-backup

# View last run logs
kubectl logs -n vault job/vault-backup-20260115
```

### Manual Backup
```bash
# Run backup script
./scripts/backup-vault.sh

# With custom path filter
./scripts/backup-vault.sh \
  --namespace vault \
  --vault-address https://vault.vault.svc \
  --path secret/platform \
  --bucket s3://platform-backups/vault
```

### Restore Vault
```bash
# List available backups
aws s3 ls s3://platform-backups/vault/ --recursive

# Restore (DRY RUN first!)
./scripts/restore-vault.sh \
  --namespace vault \
  --vault-address https://vault.vault.svc \
  --backup-file s3://platform-backups/vault/2026-01-15/secrets.json.gz \
  --dry-run

# Actual restore
./scripts/restore-vault.sh \
  --namespace vault \
  --vault-address https://vault.vault.svc \
  --backup-file s3://platform-backups/vault/2026-01-15/secrets.json.gz
```

### Emergency: Seal/Unseal Vault
```bash
# Check seal status
kubectl exec -n vault vault-0 -- vault status

# Seal (emergency lockdown)
kubectl exec -n vault vault-0 -- vault operator seal

# Unseal (requires threshold keys)
kubectl exec -n vault vault-0 -- vault operator unseal $KEY1
kubectl exec -n vault vault-0 -- vault operator unseal $KEY2
kubectl exec -n vault vault-0 -- vault operator unseal $KEY3
```

---

## ArgoCD Backup & Restore

### Automated Backup (CronJob)
```bash
# Check CronJob
kubectl get cronjob -n argocd argocd-backup

# Trigger manual run
kubectl create job --from=cronjob/argocd-backup argocd-backup-manual-$(date +%s) -n argocd
```

### Manual Backup
```bash
# Run backup script
./scripts/backup-argocd.sh

# The script backs up:
# 1. All ArgoCD resources (applications, projects, repositories, clusters)
# 2. Git repository manifests (platform-infra repo)
# 3. Creates tar.gz archive with manifest
```

### Restore ArgoCD
```bash
# List backups
aws s3 ls s3://platform-backups/argocd/ --recursive

# DRY RUN first
./scripts/restore-argocd.sh \
  --namespace argocd \
  --backup-file s3://platform-backups/argocd/2026-01-15/argocd-backup.tar.gz \
  --dry-run

# Actual restore
./scripts/restore-argocd.sh \
  --namespace argocd \
  --backup-file s3://platform-backups/argocd/2026-01-15/argocd-backup.tar.gz

# Verify restore
argocd app list
kubectl get applications -n argocd
```

---

## Kubernetes Resources Backup

### Backup All Cluster Resources
```bash
# Using kubectl-neat for clean output
kubectl get all --all-namespaces -o yaml | kubectl neat > k8s-backup-$(date +%Y%m%d).yaml

# Backup specific resource types
kubectl get deployments,services,configmaps,secrets,pvc,ingress -A -o yaml > k8s-core-backup.yaml

# Backup with labels
kubectl get all -A -l platform=fullstack -o yaml > platform-backup.yaml
```

### Restore Kubernetes Resources
```bash
# Apply backup
kubectl apply -f k8s-backup-20260115.yaml

# Or with server-side apply for conflicts
kubectl apply -f k8s-backup-20260115.yaml --server-side --force-conflicts
```

---

## Disaster Recovery Scenarios

### Scenario 1: Single Database Corruption
**Impact:** One service database corrupted
**RTO:** 15 minutes | **RPO:** 24 hours

```bash
# 1. Identify affected database
# 2. Scale down affected service
kubectl scale deployment go-service -n production --replicas=0

# 3. Restore specific database
./scripts/restore-postgres.sh --database go_service_db --backup-file s3://.../latest.sql.gz

# 4. Run migrations if needed
kubectl run migrate --image=go-service:migrate --rm -it -- migrate up

# 5. Scale up service
kubectl scale deployment go-service -n production --replicas=3
```

### Scenario 2: Vault Data Loss
**Impact:** All secrets lost
**RTO:** 30 minutes | **RPO:** 24 hours

```bash
# 1. Seal Vault immediately
kubectl exec -n vault vault-0 -- vault operator seal

# 2. Restore from backup
./scripts/restore-vault.sh --backup-file s3://platform-backups/vault/latest/secrets.json.gz

# 3. Unseal Vault
# (requires 3 of 5 unseal keys from key holders)

# 4. Restart External Secrets Operator
kubectl rollout restart deployment/external-secrets -n external-secrets

# 5. Verify secrets synced
kubectl get externalsecrets -A
```

### Scenario 3: ArgoCD Cluster Corruption
**Impact:** All application definitions lost
**RTO:** 20 minutes | **RPO:** 24 hours

```bash
# 1. Restore ArgoCD resources
./scripts/restore-argocd.sh --backup-file s3://platform-backups/argocd/latest/argocd-backup.tar.gz

# 2. Force sync all applications
for app in $(argocd app list -o name); do
  argocd app sync "$app" --prune
done

# 3. Verify all synced
argocd app list | grep -v Synced
```

### Scenario 4: Full Cluster Loss
**Impact:** Entire Kubernetes cluster gone
**RTO:** 2 hours | **RPO:** 24 hours

```bash
# 1. Provision new cluster (Terraform/OpenTofu)
cd infrastructure/terraform
tofu apply -target=module.eks_cluster

# 2. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Restore ArgoCD
./scripts/restore-argocd.sh --backup-file s3://platform-backups/argocd/latest/argocd-backup.tar.gz

# 4. ArgoCD will reconcile all applications
# 5. Verify all services healthy
argocd app list
```

---

## Verification Procedures

### Post-Backup Verification
```bash
# Run after each backup
./scripts/verify-backup.sh --all

# Checks:
# - File exists in S3
# - File size > 0
# - Gzip integrity (gzip -t)
# - SQL syntax (for postgres)
# - JSON validity (for vault)
# - Tar integrity (for argocd)
```

### Post-Restore Verification
```bash
# Run after each restore
./scripts/verify-restore.sh --all

# Checks:
# - PostgreSQL: Connection, row counts, schema version
# - Vault: Seal status, secret count, key paths
# - ArgoCD: App count, sync status, health status
# - Kubernetes: Core pods running, services have endpoints
```

---

## Monitoring & Alerts

### Backup Success Alerts
```yaml
# Prometheus alerts
- alert: BackupFailed
  expr: increase(backup_job_success_total[1h]) == 0
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Backup job failed for {{ $labels.component }}"

- alert: BackupStale
  expr: time() - backup_last_success_timestamp > 86400
  for: 1h
  labels:
    severity: warning
  annotations:
    summary: "Backup for {{ $labels.component }} is older than 24h"
```

### Key Metrics
| Metric | Description |
|--------|-------------|
| `backup_job_success_total` | Counter of successful backups |
| `backup_job_duration_seconds` | Backup duration histogram |
| `backup_size_bytes` | Backup file size |
| `restore_job_success_total` | Counter of successful restores |
| `restore_duration_seconds` | Restore duration histogram |

---

## Runbook Testing

### Monthly DR Drill (First Saturday 10:00 UTC)
```bash
# 1. Create test namespace
kubectl create namespace dr-test

# 2. Restore to test namespace
./scripts/restore-postgres.sh --namespace dr-test --backup-file s3://.../latest.sql.gz
./scripts/restore-vault.sh --namespace dr-test --backup-file s3://.../latest.json.gz

# 3. Deploy test applications
argocd app create test-app --repo ... --path ... --dest-namespace dr-test

# 4. Verify functionality
# - Run integration tests
# - Check data integrity
# - Verify secrets work

# 5. Cleanup
kubectl delete namespace dr-test
argocd app delete test-app
```

### Quarterly Full DR Test
- Provision new cluster in separate AWS account
- Execute Scenario 4 (Full Cluster Loss)
- Document RTO/RPO actuals
- Update runbooks based on findings

---

## Related Runbooks
- [ArgoCD Operations](./argocd-operations.md)
- [Disaster Recovery](./disaster-recovery.md)
- [Promotion](./promotion.md)

---

## Quick Reference

| Task | Command |
|------|---------|
| Manual PG backup | `./scripts/backup-postgres.sh` |
| Manual Vault backup | `./scripts/backup-vault.sh` |
| Manual ArgoCD backup | `./scripts/backup-argocd.sh` |
| Restore PG | `./scripts/restore-postgres.sh --backup-file <s3-path>` |
| Restore Vault | `./scripts/restore-vault.sh --backup-file <s3-path>` |
| Restore ArgoCD | `./scripts/restore-argocd.sh --backup-file <s3-path>` |
| Verify backup | `./scripts/verify-backup.sh --all` |
| Verify restore | `./scripts/verify-restore.sh --all` |
| List S3 backups | `aws s3 ls s3://platform-backups/ --recursive` |