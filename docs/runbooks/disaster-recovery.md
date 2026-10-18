# Disaster Recovery Runbook

**Repository:** platform-infra  
**Last Updated:** 2026-01-15  
**Owner:** Platform Team

---

## Overview

This runbook covers disaster recovery procedures for the entire platform.

### Recovery Objectives
| Scenario | RTO | RPO | Priority |
|----------|-----|-----|----------|
| Single service outage | 15 min | 0 | P1 |
| Database corruption | 30 min | 24h | P1 |
| Vault data loss | 30 min | 24h | P1 |
| ArgoCD cluster loss | 1 hour | 24h | P1 |
| Full cluster loss | 2 hours | 24h | P1 |
| Region outage (DR) | 4 hours | 24h | P2 |

### Backup Locations
| Component | Location | Frequency |
|-----------|----------|-----------|
| PostgreSQL | `s3://platform-backups/postgres/` | Daily 02:00 UTC |
| Vault | `s3://platform-backups/vault/` | Daily 02:30 UTC |
| ArgoCD | `s3://platform-backups/argocd/` | Daily 03:00 UTC |
| Kubernetes | `s3://platform-backups/kubernetes/` | On-demand |

---

## Incident Response Process

### 1. Detection
- Alert fires (PagerDuty, Slack, Grafana)
- Manual report (user, team member)

### 2. Triage
```bash
# Quick health check
./scripts/health-check.sh --all

# Check status page
# https://status.example.com

# Determine severity
# SEV-1: Customer-facing outage, data loss risk
# SEV-2: Degraded performance, non-critical feature down
# SEV-3: Minor issue, workaround exists
```

### 3. Communication
```bash
# Create incident channel
# Slack: #incident-<date>-<service>

# Notify stakeholders
# - On-call engineer
- Tech Lead
- Engineering Manager (if SEV-1)
- Customer Support (if customer impact)
```

### 4. Resolution
- Follow specific scenario runbook below
- Document actions in incident channel
- Update status page

### 5. Post-Incident
- Blameless postmortem within 48h
- Action items tracked in Jira
- Runbook updated if needed

---

## Scenario 1: Single Service Outage

### Symptoms
- ArgoCD shows `Degraded` for one service
- Pods in `CrashLoopBackOff` or `ImagePullBackOff`
- Health endpoint returns 5xx

### Diagnosis
```bash
# 1. Check ArgoCD
argocd app get go-service-production

# 2. Check pods
kubectl get pods -n production -l app=go-service
kubectl describe pod go-service-xxx -n production
kubectl logs go-service-xxx -n production --previous

# 3. Check events
kubectl get events -n production --sort-by=.metadata.creationTimestamp | grep go-service
```

### Common Causes & Fixes

| Cause | Fix |
|-------|-----|
| ImagePullBackOff | Fix image tag, check registry auth, retry |
| CrashLoopBackOff | Check logs, fix config/bug, rollback if needed |
| OOMKilled | Increase memory limit, fix memory leak |
| Pending (no nodes) | Scale cluster, check node affinity/taints |
| ConfigMap/Secret missing | Restore from Vault/ESO, check ESO sync |

### Rollback Procedure
```bash
# Option 1: ArgoCD rollback (preferred)
argocd app rollback go-service-production

# Option 2: Git revert + ArgoCD sync
cd platform-infra
git revert <bad-commit>
git push origin main
argocd app sync go-service-production --prune

# Option 3: Direct image rollback
kubectl set image deployment/go-service go-service=ghcr.io/org/go-service:v1.2.2 -n production
```

---

## Scenario 2: Database Corruption / Loss

### Symptoms
- Application errors: connection refused, query failed
- pg_dump fails
- Data inconsistency detected

### Diagnosis
```bash
# Check database connectivity
kubectl exec -n database postgres-0 -- pg_isready

# Check replication status
kubectl exec -n database postgres-0 -- psql -c "SELECT * FROM pg_stat_replication;"

# Check disk space
kubectl exec -n database postgres-0 -- df -h /var/lib/postgresql/data

# Check PostgreSQL logs
kubectl logs -n database postgres-0 | tail -100
```

### Recovery Procedure
```bash
# 1. STOP writes to affected database
kubectl scale deployment go-service -n production --replicas=0
kubectl scale deployment node-service -n production --replicas=0

# 2. Identify latest good backup
aws s3 ls s3://platform-backups/postgres/ --recursive | tail -5

# 3. Restore from backup
./scripts/restore-postgres.sh \
  --namespace database \
  --postgres-cluster platform-postgres \
  --backup-file s3://platform-backups/postgres/2026-01-15/all-databases.sql.gz

# 4. Verify restore
kubectl exec -n database postgres-0 -- psql -c "SELECT count(*) FROM orders;"

# 5. Run migrations if needed
kubectl run migrate --image=ghcr.io/org/go-service:v1.2.3 --rm -it -- \
  migrate -path /migrations -database "postgres://user:pass@postgres:5432/platform?sslmode=disable" up

# 6. Restore services
kubectl scale deployment go-service -n production --replicas=3
kubectl scale deployment node-service -n production --replicas=3

# 7. Verify application health
./scripts/health-check.sh --service go-service --environment production
```

### Point-in-Time Recovery (If WAL archiving enabled)
```bash
# Stop writes
kubectl scale deployment go-service -n production --replicas=0

# Restore base backup + replay WAL to target time
# Using wal-g or pgBackRest
wal-g backup-fetch LATEST --target-time "2026-01-15 14:30:00"

# Verify
# Resume writes
```

---

## Scenario 3: Vault Data Loss / Seal

### Symptoms
- Applications fail to start (secrets missing)
- ESO logs show Vault connection errors
- Vault UI shows "Sealed"

### Diagnosis
```bash
# Check Vault status
kubectl exec -n vault vault-0 -- vault status

# Check ESO
kubectl logs -n external-secrets deployment/external-secrets | grep -i vault

# Check Kubernetes secrets
kubectl get secrets -n production | grep -v "default-token"
```

### Recovery: Vault Sealed
```bash
# 1. Unseal (requires 3 of 5 unseal keys)
# Key holders: Platform Lead, Security Lead, DevOps Lead, CTO, Backup
kubectl exec -n vault vault-0 -- vault operator unseal $KEY1
kubectl exec -n vault vault-0 -- vault operator unseal $KEY2
kubectl exec -n vault vault-0 -- vault operator unseal $KEY3

# 2. Verify unsealed
kubectl exec -n vault vault-0 -- vault status

# 3. Force ESO resync
kubectl get externalsecrets -A -o name | xargs -I{} kubectl annotate {} force-sync=$(date +%s) --overwrite

# 4. Verify Kubernetes secrets populated
kubectl get secrets -n production
```

### Recovery: Vault Data Loss
```bash
# 1. Restore from backup
./scripts/restore-vault.sh \
  --namespace vault \
  --vault-address https://vault.vault.svc \
  --backup-file s3://platform-backups/vault/2026-01-15/secrets.json.gz

# 2. Unseal if needed (see above)

# 3. Restart ESO to force re-read
kubectl rollout restart deployment/external-secrets -n external-secrets

# 4. Restart all deployments to pick up secrets
kubectl rollout restart deployment -n production
kubectl rollout restart deployment -n staging

# 5. Verify all services healthy
./scripts/health-check.sh --all
```

---

## Scenario 4: ArgoCD Cluster Loss

### Symptoms
- ArgoCD UI inaccessible
- Applications not syncing
- `argocd` CLI fails to connect

### Diagnosis
```bash
# Check ArgoCD pods
kubectl get pods -n argocd

# Check ArgoCD server
kubectl logs -n argocd deployment/argocd-server

# Check application controller
kubectl logs -n argocd deployment/argocd-application-controller
```

### Recovery
```bash
# 1. Restore ArgoCD from backup
./scripts/restore-argocd.sh \
  --namespace argocd \
  --backup-file s3://platform-backups/argocd/2026-01-15/argocd-backup.tar.gz

# 2. Wait for ArgoCD to start
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# 3. Verify applications
argocd app list

# 4. Force sync all OutOfSync apps
for app in $(argocd app list -o json | jq -r '.[] | select(.status.sync.status=="OutOfSync") | .name'); do
  echo "Syncing $app..."
  argocd app sync "$app" --prune
done

# 5. Verify all healthy
argocd app list | grep -v "Synced.*Healthy"
```

---

## Scenario 5: Full Cluster Loss

### Prerequisites
- Terraform/OpenTofu state for infrastructure
- Access to AWS/GCP console
- Backup files in S3
- DNS management access

### Recovery Procedure

#### Phase 1: Infrastructure (30-60 min)
```bash
# 1. Provision new cluster
cd infrastructure/terraform
tofu init
tofu apply -target=module.eks_cluster -target=module.vpc -target=module.iam

# 2. Configure kubectl
aws eks update-kubeconfig --name platform-prod --region us-east-1

# 3. Install core components
# ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# External Secrets Operator
kubectl apply -f https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/crds/bundle.yaml
kubectl apply -f https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/values.yaml
```

#### Phase 2: Restore State (30 min)
```bash
# 1. Restore Vault (secrets needed for other restores)
./scripts/restore-vault.sh --backup-file s3://platform-backups/vault/latest/secrets.json.gz
# Unseal Vault (3 keys)

# 2. Restart ESO
kubectl rollout restart deployment/external-secrets -n external-secrets

# 3. Restore ArgoCD
./scripts/restore-argocd.sh --backup-file s3://platform-backups/argocd/latest/argocd-backup.tar.gz

# 4. Wait for ArgoCD
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
```

#### Phase 3: Application Recovery (30-60 min)
```bash
# ArgoCD will automatically reconcile all applications
# Monitor progress
watch -n 10 'argocd app list | grep -E "Progressing|OutOfSync"'

# Force sync any stuck
for app in $(argocd app list -o json | jq -r '.[] | select(.status.sync.status=="OutOfSync") | .name'); do
  argocd app sync "$app" --prune
done

# 5. Restore PostgreSQL (if not using managed RDS)
./scripts/restore-postgres.sh --backup-file s3://platform-backups/postgres/latest/all-databases.sql.gz
```

#### Phase 4: DNS & Verification (15 min)
```bash
# 1. Update DNS to new cluster ALB/ingress
# Route53: Update ALB target
aws route53 change-resource-record-sets --hosted-zone-id Z123 --change-batch file://dns-change.json

# 2. Verify all services
./scripts/health-check.sh --all

# 3. Run smoke tests
./scripts/smoke-tests.sh --environment production

# 4. Notify team
# Slack: #platform-ops "DR recovery complete. All services restored."
```

---

## Scenario 6: Region Outage (Multi-Region DR)

### Architecture
- Primary: us-east-1
- DR: us-west-2 (warm standby)

### Failover Procedure
```bash
# 1. Declare region failover
# Incident commander decision

# 2. Promote DR database
# If using Aurora Global Database:
aws rds failover-db-cluster --db-cluster-identifier platform-aurora-global --target-db-cluster-identifier platform-aurora-dr

# 3. Scale DR cluster
# Update ASG desired capacity
aws autoscaling set-desired-capacity --auto-scaling-group-name platform-dr-workers --desired-capacity 10

# 4. Update DNS (Route53 failover)
aws route53 change-resource-record-sets --hosted-zone-id Z123 --change-batch file://dr-failover.json

# 5. Verify DR cluster
kubectl config use-context platform-dr
./scripts/health-check.sh --all

# 6. Notify stakeholders
# Status page: "Operating from DR region"
```

### Failback Procedure
```bash
# 1. Verify primary region healthy
# 2. Sync data back (if async replication)
# 3. Reverse DNS changes
# 4. Scale down DR
# 5. Post-incident review
```

---

## Backup Verification

### Automated Verification (Daily)
```bash
# Runs via CronJob after backups
./scripts/verify-backup.sh --all

# Checks:
# - Files exist in S3
# - File sizes > expected minimum
# - Gzip integrity
# - SQL syntax valid
# - JSON valid
# - Tar integrity
```

### Manual Verification (Weekly)
```bash
# Test restore to isolated namespace
kubectl create namespace dr-verify

# Restore PostgreSQL
./scripts/restore-postgres.sh --namespace dr-verify --backup-file s3://.../latest.sql.gz

# Restore Vault
./scripts/restore-vault.sh --namespace dr-verify --backup-file s3://.../latest.json.gz

# Verify data
kubectl exec -n dr-verify postgres-0 -- psql -c "SELECT count(*) FROM orders;"
# Check Vault secrets

# Cleanup
kubectl delete namespace dr-verify
```

---

## DR Testing Schedule

| Test | Frequency | Scope |
|------|-----------|-------|
| Backup verification | Daily (automated) | All backups |
| Single service restore | Weekly | Rotate services |
| Full DR drill | Quarterly | Full cluster loss scenario |
| Region failover | Semi-annually | Multi-region DR |

### Quarterly DR Drill Checklist
- [ ] Provision test cluster (separate AWS account)
- [ ] Execute Scenario 5 (Full Cluster Loss)
- [ ] Measure actual RTO/RPO
- [ ] Document gaps
- [ ] Update runbooks
- [ ] Cleanup test resources

---

## Contact Information

| Role | Primary | Backup |
|------|---------|--------|
| Incident Commander | Platform Lead | Senior Engineer |
| Database Admin | DevOps Lead | Platform Engineer |
| Vault Admin | Security Lead | DevOps Lead |
| ArgoCD Admin | Platform Engineer | DevOps Lead |
| Infrastructure | Cloud Engineer | Platform Lead |
| Communications | Engineering Manager | Tech Lead |

### Emergency Contacts
- **PagerDuty:** Platform On-Call
- **Slack:** #platform-oncall, #incident-*
- **Status Page:** https://status.example.com
- **AWS Support:** Business/Enterprise support case

---

## Related Runbooks
- [Backup & Restore](./backup-restore.md) - Detailed backup/restore procedures
- [ArgoCD Operations](./argocd-operations.md) - ArgoCD-specific recovery
- [Secrets Management](./secrets-management.md) - Vault recovery
- [Promotion](./promotion.md) - Rollback procedures

---

## Quick Reference

| Scenario | Key Command |
|----------|-------------|
| Service rollback | `argocd app rollback <app>-production` |
| DB restore | `./scripts/restore-postgres.sh --backup-file s3://...` |
| Vault restore | `./scripts/restore-vault.sh --backup-file s3://...` |
| ArgoCD restore | `./scripts/restore-argocd.sh --backup-file s3://...` |
| Full cluster DR | See Scenario 5 procedure |
| Region failover | `aws rds failover-db-cluster...` + DNS update |
| Verify backups | `./scripts/verify-backup.sh --all` |
| Health check | `./scripts/health-check.sh --all` |