# ADR 006: External Secrets Operator with Vault

**Status:** Accepted
**Date:** 2026-01-15

## Context

We need to manage secrets securely across environments without storing them in Git. Options:
1. **Sealed Secrets** - Encrypt secrets in Git, decrypt in-cluster
2. **External Secrets Operator (ESO)** - Sync secrets from external store (Vault, AWS Secrets Manager)
3. **Vault Agent Injector** - Sidecar injects secrets into pods
4. **GitOps with SOPS** - Encrypted files in Git, decrypted at deploy
5. **Manual kubectl** - Create secrets manually per environment

## Decision

We will use **External Secrets Operator (ESO) with HashiCorp Vault** as the secret backend.

### Architecture
```
Git (ExternalSecret CR) → ESO Controller → Vault → Kubernetes Secrets → Pods
```

### Components
| Component | Purpose |
|-----------|---------|
| **ClusterSecretStore** | Cluster-scoped Vault connection config |
| **ExternalSecret** | Namespace-scoped secret sync definition |
| **Vault** | Secret storage (KV v2 engine) |
| **ESO Controller** | Reconciles ExternalSecret → Kubernetes Secret |

### Secret Structure in Vault
```
secret/
├── platform-infra/
│   ├── postgres-credentials
│   ├── minio-credentials
│   └── argocd-credentials
├── platform-services-go/
│   ├── postgres-credentials
│   ├── sqs-credentials
│   └── oauth-credentials
├── platform-services-node/
│   ├── postgres-credentials
│   ├── redis-credentials
│   └── aws-credentials
└── platform-frontend/
    ├── oauth-credentials
    └── nextauth-secret
```

## Consequences

### Positive
- **No secrets in Git** - ExternalSecret CRs reference paths, not values
- **Centralized management** - Single Vault for all environments
- **Rotation support** - ESO can periodically re-sync (configurable)
- **RBAC integration** - Vault policies control access per service/environment
- **Audit trail** - Vault logs all secret access
- **Multi-tenancy** - ClusterSecretStore per environment with different auth

### Negative
- **Additional infrastructure** - Vault cluster required
- **Complexity** - ESO + Vault + Kubernetes secrets chain
- **Bootstrap problem** - Initial Vault unseal/token distribution
- **Latency** - Extra hop for secret retrieval at pod start
- **Failure mode** - If Vault down, new pods can't start

### Mitigation
- Run Vault in HA mode (3+ nodes) with integrated storage
- Use `spec.refreshInterval` for periodic sync (1h default)
- Cache secrets in Kubernetes Secrets (ESO default)
- Document unseal procedure in runbook
- Use Vault Agent Injector for critical workloads needing real-time updates

## Related
- ADR 004: ArgoCD App-of-Apps Pattern
- ADR 007: Distroless Base Images