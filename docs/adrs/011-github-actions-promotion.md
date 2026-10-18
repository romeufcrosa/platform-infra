# ADR 011: GitHub Actions Promotion Workflow

**Status:** Accepted
**Date:** 2026-01-15

## Context

We need a controlled promotion process to move images from dev → staging → production. Options:

1. **Manual tag update** - Edit values-production.yaml manually
2. **GitHub Actions workflow_dispatch** - Trigger promotion via UI/API with environment gates
3. **ArgoCD CLI promotion** - Use `argocd app set` to update image tag
4. **Custom promotion CLI** - Dedicated tool (promote.sh) wrapping ArgoCD/Git operations
5. **GitOps promotion PR** - Bot creates PR updating values files

## Decision

We will use **GitHub Actions workflow_dispatch with environment protection rules** as the primary promotion mechanism, supplemented by a **promote.sh CLI script** for local/automated use.

### Promotion Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│    dev      │────▶│  staging    │────▶│ production  │
│  (auto)     │     │ (workflow_  │     │ (workflow_  │
│             │     │  dispatch + │     │  dispatch + │
│             │     │  approval)  │     │  approval)  │
└─────────────┘     └─────────────┘     └─────────────┘
```

### GitHub Actions Workflow (.github/workflows/promote.yaml)

```yaml
name: Promote
on:
  workflow_dispatch:
    inputs:
      service:
        type: choice
        description: Service to promote
        options: [go-service, node-service, frontend, all]
        required: true
      from_env:
        type: choice
        description: Source environment
        options: [dev, staging]
        required: true
      to_env:
        type: choice
        description: Target environment
        options: [staging, production]
        required: true
      image_tag:
        type: string
        description: Image tag to promote (empty = latest from source)
        required: false
      dry_run:
        type: boolean
        description: Show changes without applying
        default: true

permissions:
  contents: write
  pull-requests: write

jobs:
  promote:
    runs-on: ubuntu-latest
    environment: ${{ inputs.to_env }}  # Environment protection rules apply
    steps:
      - uses: actions/checkout@v4
      
      - name: Determine image tag
        id: tag
        run: |
          if [[ -z "${{ inputs.image_tag }}" ]]; then
            # Get latest tag from source environment
            TAG=$(gh api repos/romeufcrosa/${{ inputs.service }}/releases/latest --jq .tag_name)
          else
            TAG="${{ inputs.image_tag }}"
          fi
          echo "tag=$TAG" >> $GITHUB_OUTPUT
      
      - name: Update values file
        run: |
          ./scripts/promote.sh \
            --service ${{ inputs.service }} \
            --from ${{ inputs.from_env }} \
            --to ${{ inputs.to_env }} \
            --tag ${{ steps.tag.outputs.tag }} \
            --dry-run ${{ inputs.dry_run }}
      
      - name: Create PR (if not dry-run)
        if: ${{ !inputs.dry_run }}
        run: |
          gh pr create \
            --title "Promote ${{ inputs.service }} ${{ steps.tag.outputs.tag }} to ${{ inputs.to_env }}" \
            --body "Automated promotion from ${{ inputs.from_env }}" \
            --base main
```

### Environment Protection Rules

Configure in GitHub repository settings → Environments:

| Environment | Protection Rules |
|-------------|------------------|
| **staging** | Required reviewers: 1 (platform team), Wait timer: 0 min |
| **production** | Required reviewers: 2 (platform lead + SRE), Wait timer: 30 min, Deployment branches: main only |

### promote.sh CLI Script

Location: `platform-infra/scripts/promote.sh`

Features:
- `--dry-run` - Show diff without applying
- `--auto-approve` - Skip confirmation prompts
- `--verify` - Run post-promotion verification
- `--rollback` - Rollback to previous version

```bash
# Promote go-service from staging to production
./scripts/promote.sh --service go-service --from staging --to production --tag v1.2.3

# Promote all services from dev to staging (dry run)
./scripts/promote.sh --service all --from dev --to staging --dry-run

# Rollback production
./scripts/promote.sh --service go-service --to production --rollback
```

### Post-Promotion Verification

After promotion, `verify-promotion.sh` runs:
1. ArgoCD sync status check
2. Pod readiness verification
3. Health endpoint checks
4. Smoke test critical paths
5. Metrics baseline comparison

## Consequences

### Positive
- **Audit trail** - Every promotion logged in GitHub Actions
- **Approval gates** - Production requires multiple approvals
- **Rollback capability** - One-click rollback via workflow re-run
- **Traceability** - PR links promotion to image tag and source
- **Automation friendly** - CLI script for CI/CD integration

### Negative
- **GitHub dependency** - Tied to GitHub Actions and Environments
- **Delay** - Wait timers and approvals add latency
- **Manual trigger** - Not fully automatic (intentional for production)
- **Secret management** - Requires GH_TOKEN with repo write access

### Mitigation
- Document emergency bypass procedure
- Keep promote.sh as fallback for GitHub outages
- Regular disaster recovery drills
- Monitor promotion metrics (lead time, failure rate)

## Related
- ADR 009: ArgoCD ApplicationSet with Matrix Generator
- ADR 010: Helm Environment-Specific Values Files
- ADR 012: Production Hardening Standards