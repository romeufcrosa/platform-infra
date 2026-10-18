# Secrets Management Runbook

**Repository:** platform-infra  
**Last Updated:** 2026-01-15  
**Owner:** Platform Team

---

## Overview

This runbook covers managing secrets using HashiCorp Vault with External Secrets Operator (ESO) for Kubernetes integration.

### Architecture
```
Vault (Source of Truth)
    │
    ▼
External Secrets Operator (Sync Controller)
    │
    ▼
Kubernetes Secrets (Consumed by Pods)
    │
    ▼
Applications (via env vars / mounted files)
```

### Secret Paths
| Path | Purpose | Consumers |
|------|---------|-----------|
| `secret/platform/database` | PostgreSQL credentials | All services |
| `secret/platform/redis` | Redis credentials | Node, Frontend |
| `secret/platform/sqs` | AWS/SQS credentials | Go, Node |
| `secret/platform/jwt` | JWT signing keys | All services |
| `secret/platform/oauth` | OAuth providers (GitHub, Google) | Frontend, Auth |
| `secret/platform/tls` | TLS certificates | Ingress, gRPC |
| `secret/platform/external` | 3rd party API keys | Various |

---

## Daily Operations

### Reading Secrets
```bash
# Via Vault CLI (requires auth)
vault kv get secret/platform/database

# Via kubectl (ESO synced)
kubectl get secret database-credentials -n production -o jsonpath='{.data.password}' | base64 -d

# Via Vault UI
# https://vault.example.com/ui/vault/secrets/secret/show/platform/database
```

### Creating/Updating Secrets
```bash
# Via Vault CLI
vault kv put secret/platform/database \
  host=postgres.database.svc \
  port=5432 \
  username=app_user \
  password="$(openssl rand -base64 32)" \
  database=platform

# Via Vault UI
# 1. Navigate to secret/platform/database
# 2. Click "Create secret" or "Edit"
# 3. Add key-value pairs
# 4. Save

# ESO automatically syncs within 10s (configurable)
```

### Deleting Secrets
```bash
# Soft delete (versioned)
vault kv delete secret/platform/old-service

# Hard delete (purge versions)
vault kv destroy -versions=1,2 secret/platform/old-service

# Metadata delete (remove all versions)
vault kv metadata delete secret/platform/old-service
```

---

## External Secrets Operator Management

### Check ESO Status
```bash
# Operator health
kubectl get pods -n external-secrets

# All ExternalSecrets resources
kubectl get externalsecrets -A

# Specific ExternalSecret status
kubectl describe externalsecret database-credentials -n production

# Check sync status
kubectl get externalsecret -A -o custom-columns="NAMESPACE:.metadata.name,NAME:.metadata.name,STATUS:.status.conditions[0].status,REASON:.status.conditions[0].reason,AGE:.metadata.creationTimestamp"
```

### Force Resync
```bash
# Annotate to trigger immediate sync
kubectl annotate externalsecret database-credentials -n production \
  force-sync=$(date +%s) --overwrite

# Or recreate the secret
kubectl delete secret database-credentials -n production
# ESO will recreate on next reconcile
```

### Debug Sync Issues
```bash
# 1. Check ESO logs
kubectl logs -n external-secrets deployment/external-secrets -f

# 2. Check SecretStore
kubectl get secretstore -n production
kubectl describe secretstore vault-backend -n production

# 3. Check ClusterSecretStore
kubectl get clustersecretstore
kubectl describe clustersecretstore vault-backend

# 4. Verify Vault connectivity
kubectl exec -n external-secrets deployment/external-secrets -- \
  vault status -address=https://vault.vault.svc

# 5. Check Vault auth
kubectl exec -n external-secrets deployment/external-secrets -- \
  vault token lookup
```

---

## Secret Rotation

### Automated Rotation (Database Passwords)
```bash
# Vault database secrets engine handles rotation
# Configuration in Vault (one-time setup)
vault write database/config/platform \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@postgres:5432/platform" \
  allowed_roles="platform-role" \
  username="vault_admin" \
  password="admin_password"

vault write database/roles/platform-role \
  db_name=platform \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

# Applications use dynamic credentials (short-lived)
# No manual rotation needed!
```

### Manual Rotation (Static Secrets)
```bash
# 1. Generate new value
NEW_JWT_SECRET=$(openssl rand -base64 64)

# 2. Update in Vault (creates new version)
vault kv put secret/platform/jwt signing_key="$NEW_JWT_SECRET"

# 3. Verify ESO sync
kubectl get secret jwt-secret -n production -o jsonpath='{.data.signing_key}' | base64 -d

# 4. Rollout dependent deployments
kubectl rollout restart deployment/go-service -n production
kubectl rollout restart deployment/node-service -n production
kubectl rollout restart deployment/frontend -n production

# 5. Verify applications healthy
kubectl get pods -n production -l app.kubernetes.io/name=go-service
```

### Rotation Checklist
- [ ] Generate new secret value
- [ ] Update in Vault
- [ ] Verify ESO sync (check Kubernetes secret)
- [ ] Rollout dependent deployments
- [ ] Verify application health
- [ ] Update documentation/runbooks if needed
- [ ] Notify team (Slack #platform-ops)

---

## Adding New Secrets

### Process
```bash
# 1. Determine path
# Service-specific: secret/platform/<service>/<name>
# Shared: secret/platform/<category>

# 2. Create in Vault
vault kv put secret/platform/new-service/api_key \
  key="sk_live_..." \
  created_by="platform-team" \
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 3. Create ExternalSecret manifest
cat > platform-infra/kubernetes/external-secrets/new-service-api-key.yaml <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: new-service-api-key
  namespace: production
spec:
  refreshInterval: 1m
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend
  target:
    name: new-service-api-key
    creationPolicy: Owner
  data:
    - secretKey: api_key
      remoteRef:
        key: secret/platform/new-service/api_key
        property: key
EOF

# 4. Apply via GitOps (ArgoCD)
git add platform-infra/kubernetes/external-secrets/new-service-api-key.yaml
git commit -m "feat: add external secret for new-service API key"
git push origin main

# 5. Verify
kubectl get secret new-service-api-key -n production
```

---

## TLS Certificate Management

### Certificate Sources
| Certificate | Source | Renewal |
|-------------|--------|---------|
| Ingress (public) | Let's Encrypt (cert-manager) | Auto (30d before expiry) |
| Internal gRPC/mTLS | Vault PKI | Auto (24h TTL) |
| Vault itself | Self-signed / CA | Manual (1y) |

### Check Certificate Expiry
```bash
# Kubernetes TLS secrets
kubectl get secrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.type}{"\n"}{end}' | grep kubernetes.io/tls

# Check expiry
kubectl get secret tls-cert -n production -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

# Cert-manager certificates
kubectl get certificate -A
kubectl describe certificate -n production frontend-tls
```

### Renew Certificate (Manual)
```bash
# Let's Encrypt (cert-manager)
kubectl delete secret frontend-tls -n production
# cert-manager will reissue

# Vault PKI (internal)
# Auto-rotated, but can force:
vault write -force pki/issue/internal-dot-svc common_name=go-service.production.svc ttl=24h
```

---

## Access Control

### Vault Policies
```hcl
# Platform team policy
path "secret/platform/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "database/creds/platform-role" {
  capabilities = ["read"]
}

path "pki/issue/*" {
  capabilities = ["create", "update"]
}

# Application policy (read-only, specific paths)
path "secret/platform/database" {
  capabilities = ["read"]
}

path "secret/platform/redis" {
  capabilities = ["read"]
}
```

### Kubernetes RBAC for ESO
```yaml
# ClusterSecretStore requires cluster-admin or specific permissions
# ServiceAccount: external-secrets in external-secrets namespace
# ClusterRole: external-secrets-secretstore-admin
```

---

## Disaster Recovery

### Vault Backup (See backup-restore.md)
```bash
# Automated daily via CronJob
./scripts/backup-vault.sh

# Manual
./scripts/backup-vault.sh --namespace vault --bucket s3://platform-backups/vault
```

### Vault Restore
```bash
# See backup-restore.md for full procedure
./scripts/restore-vault.sh --backup-file s3://platform-backups/vault/2026-01-15/secrets.json.gz
```

### Emergency: Vault Sealed
```bash
# 1. Check status
kubectl exec -n vault vault-0 -- vault status

# 2. If sealed, unseal (requires 3 of 5 keys)
kubectl exec -n vault vault-0 -- vault operator unseal $KEY1
kubectl exec -n vault vault-0 -- vault operator unseal $KEY2
kubectl exec -n vault vault-0 -- vault operator unseal $KEY3

# 3. Verify ESO reconnects
kubectl logs -n external-secrets deployment/external-secrets -f | grep -i vault

# 4. Force resync all ExternalSecrets
kubectl get externalsecrets -A -o name | xargs -I{} kubectl annotate {} force-sync=$(date +%s) --overwrite
```

---

## Audit & Compliance

### Audit Logging
```bash
# Enable audit device (one-time)
vault audit enable file file_path=/var/log/vault_audit.log

# View audit log
tail -f /var/log/vault_audit.log | jq '.'

# Query specific operations
jq 'select(.request.path | contains("secret/platform/database"))' /var/log/vault_audit.log
```

### Compliance Checks
```bash
# Check for stale secrets (>90 days no access)
vault kv metadata list secret/platform/ | while read path; do
  vault kv metadata get "secret/platform/$path" | grep -E "created_time|custom_metadata"
done

# Secrets without rotation policy
# Review: static secrets should have rotation schedule documented
```

---

## Troubleshooting

### ESO Not Syncing
```bash
# 1. Check SecretStore status
kubectl get secretstore -n production vault-backend -o yaml

# 2. Check Vault connection
kubectl exec -n external-secrets deployment/external-secrets -- \
  vault status -address=https://vault.vault.svc

# 3. Check authentication
# ESO uses Kubernetes auth - verify role exists
vault read auth/kubernetes/role/external-secrets

# 4. Check token reviewer permissions
kubectl auth can-i create tokenreviews --as=system:serviceaccount:external-secrets:external-secrets
```

### Secret Not Updating in Pods
```bash
# 1. Check secret updated
kubectl get secret <name> -n <ns> -o yaml

# 2. Check pod volume mount
kubectl describe pod <pod> -n <ns> | grep -A10 Volumes

# 3. Restart pod to pick up new secret
kubectl delete pod <pod> -n <ns>

# 4. Or use Reloader annotation (if configured)
kubectl annotate deployment <deployment> -n <ns> reloader.stakater.com/auto="true"
```

### Permission Denied
```bash
# Check Vault policy for token
vault token lookup

# Check Kubernetes auth role
vault read auth/kubernetes/role/external-secrets

# Verify service account
kubectl get sa external-secrets -n external-secrets -o yaml
```

---

## Related Runbooks
- [Backup & Restore](./backup-restore.md) - Vault backup/restore procedures
- [Disaster Recovery](./disaster-recovery.md) - Vault disaster scenarios
- [Promotion](./promotion.md) - Secrets in promotion pipeline

---

## Quick Reference

| Task | Command |
|------|---------|
| Read secret | `vault kv get secret/platform/database` |
| Write secret | `vault kv put secret/platform/database key=value` |
| Delete secret | `vault kv delete secret/platform/old` |
| List secrets | `vault kv list secret/platform/` |
| Check ESO sync | `kubectl get externalsecrets -A` |
| Force resync | `kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite` |
| Check cert expiry | `kubectl get secret <tls-secret> -o jsonpath='{.data.tls\.crt}' \| base64 -d \| openssl x509 -noout -dates` |
| Rotate static secret | `vault kv put secret/path key=new_value && kubectl rollout restart deploy/<app>` |
| View audit log | `tail -f /var/log/vault_audit.log \| jq '.'` |
| Unseal Vault | `vault operator unseal $KEY` (x3) |