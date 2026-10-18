# ADR 003: Ministack for Local AWS Services

**Status:** Accepted
**Date:** 2026-01-15

## Context

We need local replacements for AWS services (S3, SQS, DynamoDB, Secrets Manager) for development and testing. Options:
1. **LocalStack** - Full AWS mock (community edition limited)
2. **Ministack** - Lightweight Go-based AWS mock (S3, SQS, DynamoDB, Secrets Manager)
3. **Moto** - Python-based AWS mock
4. **Real AWS** - Use actual AWS accounts (dev/staging)
5. **WireMock/MockServer** - Generic HTTP mocking

## Decision

We will use **Ministack** for local AWS service simulation.

### Services Provided
| Service | Port | Use Case |
|---------|------|----------|
| S3 | 9000 | Object storage (backups, static assets) |
| SQS | 9324 | Message queues (event processing) |
| DynamoDB | 8000 | NoSQL database (session store) |
| Secrets Manager | 8080 | Secret storage (API keys, passwords) |

## Consequences

### Positive
- **Lightweight** - Single Go binary, ~10MB, minimal resources
- **API compatible** - Uses AWS SDKs directly, no code changes
- **Fast startup** - Sub-second initialization
- **No JVM** - Unlike LocalStack, no Java runtime needed
- **Open source** - MIT license, no feature gating
- **Kubernetes native** - Runs as Deployment in cluster

### Negative
- **Limited service coverage** - Only 4 core services
- **No IAM simulation** - Permissions not enforced
- **No CloudFormation** - Infrastructure-as-code testing limited
- **Less mature** - Smaller community than LocalStack

### Mitigation
- Use **real AWS** for integration testing in CI/staging
- Document Ministack limitations in service READMEs
- Fallback to LocalStack for services not covered (Lambda, SNS, etc.)

## Configuration
```yaml
# Helm values for Ministack
ministack:
  enabled: true
  s3:
    bucket: platform-local
  sqs:
    queues:
      - platform-events
      - order-events
  dynamodb:
    tables:
      - sessions
  secretsmanager:
    secrets:
      - platform-secrets
```

## Related
- ADR 006: External Secrets with Vault