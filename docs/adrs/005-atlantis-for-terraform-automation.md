# ADR 005: Atlantis for Terraform/OpenTofu Automation

**Status:** Accepted
**Date:** 2026-01-15

## Context

We need to automate Terraform/OpenTofu plan/apply workflows with PR-based review. Options:
1. **Atlantis** - PR-based Terraform automation
2. **GitHub Actions** - Native CI/CD for Terraform
3. **Spacelift** - SaaS Terraform management
4. **Terraform Cloud** - HashiCorp SaaS
5. **Custom scripts** - Wrapper scripts in CI

## Decision

We will use **Atlantis** for OpenTofu automation.

### Configuration
- **Server**: Runs in-cluster (Deployment in `atlantis` namespace)
- **Webhook**: GitHub webhook for PR events
- **Workflow**: `plan` on PR, `apply` on approved PR with `atlantis apply` comment
- **Projects**: Per-directory configuration in `atlantis.yaml`
- **Locking**: Automatic per-directory locking

### atlantis.yaml Structure
```yaml
version: 3
projects:
  - name: platform-infra
    dir: .
    workflow: default
    apply_requirements: [approved, mergeable]
    autoplan:
      when_modified: ["*.tf", "*.tfvars"]
      enabled: true
```

## Consequences

### Positive
- **PR-native workflow** - Plan visible in PR comments
- **Approval gates** - Requires approved + mergeable before apply
- **Drift detection** - Can run periodic plans
- **OpenTofu support** - Drop-in replacement for Terraform
- **Self-hosted** - Runs in our cluster, no SaaS dependency
- **Concurrency control** - Prevents conflicting applies

### Negative
- **Additional component** - Requires running server, webhook config
- **State management** - Still need remote state backend (S3 + DynamoDB)
- **Single-threaded** - One apply at a time per project
- **GitHub App** - Requires GitHub App for webhook (not just OAuth)

### Mitigation
- Use Ministack S3 + DynamoDB for local state backend
- Document Atlantis setup in runbook
- Use `atlantis.yaml` for project-specific workflows
- Consider Terraform Cloud for production if scale demands

## Related
- ADR 001: Multi-Repository Architecture
- ADR 003: Ministack for Local AWS Services