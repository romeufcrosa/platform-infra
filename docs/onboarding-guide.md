# Cross-Repository Onboarding Guide

**Platform:** FullStack Platform  
**Version:** 1.0  
**Last Updated:** 2026-01-15  
**Maintained by:** Platform Team

---

## Welcome!

Welcome to the FullStack Platform team! This guide will help you understand our platform architecture, set up your development environment, and learn our key workflows.

### What You'll Learn
- Platform architecture and repository structure
- Local development environment setup
- How to deploy and promote changes
- Key operational procedures
- Where to find detailed documentation

---

## Platform Overview

### High-Level Architecture
```
┌─────────────────────────────────────────────────────────────────────────┐
                           EXTERNAL USERS
└─────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
                        INGRESS (NGINX / ALB)
                    TLS Termination, Rate Limiting
└─────────────────────────────────────────────────────────────────────────┘
                                      │
              ┌───────────────────────┼───────────────────────┐
              ▼                       ▼                       ▼
    ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
    │  Frontend       │    │  Go Service     │    │  Node Service   │
    │  (Next.js 14)   │    │  (Gin)          │    │  (Fastify)      │
    │  Port 3000      │    │  Port 8080      │    │  Port 3000/3001 │
    └─────────────────┘    └─────────────────┘    └─────────────────┘
              │                       │                       │
              │              ┌────────┴────────┐              │
              │              ▼                 ▼              │
              │    ┌─────────────┐      ┌─────────────┐      │
              │    │ PostgreSQL  │      │    Redis    │      │
              │    │ (Per-schema)│      │  (Pub/Sub)  │      │
              │    └─────────────┘      └─────────────┘      │
              │              │                       │         │
              └──────────────┼───────────────────────┼────────┘
                             ▼                       ▼
                    ┌─────────────────┐    ┌─────────────────┐
                    │     SQS         │    │    Vault        │
                    │  (Ministack)    │    │  (Secrets)      │
                    └─────────────────┘    └─────────────────┘
```

### Repository Structure (4 Repos)

| Repository | Purpose | Language | Key Tech |
|------------|---------|----------|----------|
| **platform-infra** | Infrastructure, GitOps, CI/CD | YAML, HCL, Bash | ArgoCD, OpenTofu, Helm, k6, LitmusChaos |
| **platform-services-go** | Orders API | Go 1.21 | Gin, GORM, golang-migrate, SQS |
| **platform-services-node** | Notifications API + WebSocket | Node.js 20 | Fastify, ioredis, @fastify/websocket |
| **platform-frontend** | Web Application | TypeScript/React | Next.js 14 (App Router), TanStack Query, shadcn/ui |

### Environments
| Environment | Purpose | Sync Policy | Access |
|-------------|---------|-------------|--------|
| **dev** | Feature branches | Auto | All developers |
| **staging** | Main branch | Auto | All developers |
| **production** | Manual promotion | Manual | Platform team only |

---

## Quick Start

### Prerequisites
- **macOS/Linux** (Windows via WSL2)
- **Docker Desktop** ≥ 4.25
- **kubectl** ≥ 1.28
- **helm** ≥ 3.13
- **argocd CLI** ≥ 2.9
- **gh CLI** ≥ 2.45
- **Node.js** ≥ 20 (for frontend)
- **Go** ≥ 1.21 (for go-service)
- **Minikube** ≥ 1.32 (for local dev)

### One-Command Setup
```bash
# Clone all repos (run from your workspace directory)
git clone https://github.com/org/platform-infra.git
git clone https://github.com/org/platform-services-go.git
git clone https://github.com/org/platform-services-node.git
git clone https://github.com/org/platform-frontend.git

# Run platform setup script
cd platform-infra
./scripts/setup-dev-environment.sh
```

### Manual Setup Steps

#### 1. Start Minikube
```bash
minikube start --cpus=4 --memory=8192 --disk-size=50g \
  --addons=ingress,metrics-server,registry
eval $(minikube docker-env)
```

#### 2. Install Core Platform Components
```bash
cd platform-infra

# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Install External Secrets Operator
kubectl apply -f https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/crds/bundle.yaml

# Deploy platform applications
kubectl apply -k argocd/applications/
```

#### 3. Start Ministack (Local AWS Services)
```bash
cd platform-infra
docker compose -f docker-compose.ministack.yml up -d
# Provides: S3, SQS, DynamoDB, Secrets Manager on localhost:9324
```

#### 4. Verify Installation
```bash
# Check ArgoCD
argocd login localhost:8080 --username admin --password $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Check all apps synced
argocd app list

# Check services
kubectl get pods -A
```

---

## Repository Deep Dives

### platform-infra
**Location:** `/platform-infra`

**Key Directories:**
```
platform-infra/
├── argocd/
│   ├── applications/          # Individual ArgoCD Applications
│   ├── applicationset/        # ApplicationSet for matrix generation
│   └── projects/              # ArgoCD Projects
├── helm/                      # Shared Helm charts (if any)
├── kubernetes/                # Cluster-scoped resources
├── scripts/                   # Operational scripts
│   ├── promote.sh             # Promotion CLI
│   ├── verify-promotion.sh    # Post-promotion verification
│   ├── backup-*.sh            # Backup scripts
│   └── restore-*.sh           # Restore scripts
├── tests/                     # k6 load tests
├── chaos/                     # LitmusChaos experiments
├── docs/
│   ├── adrs/                  # Architecture Decision Records
│   └── runbooks/              # Operational runbooks
└── .github/workflows/         # CI/CD pipelines
```

**Key Workflows:**
- **Promotion:** `gh workflow run promote.yaml` or `./scripts/promote.sh`
- **Load Testing:** `gh workflow run load-test.yaml` or `k6 run tests/*.js`
- **Chaos Engineering:** `gh workflow run chaos.yaml` or `kubectl apply -f chaos/experiments/*.yaml`
- **Backup/Restore:** `./scripts/backup-*.sh` / `./scripts/restore-*.sh`

### platform-services-go
**Location:** `/platform-services-go`

**Key Directories:**
```
platform-services-go/
├── cmd/
│   └── server/                # Main entry point
├── internal/
│   ├── handlers/              # HTTP handlers (Gin)
│   ├── services/              # Business logic
│   ├── repository/            # Database layer (GORM)
│   ├── messaging/             # SQS publisher
│   └── middleware/            # Auth, logging, metrics
├── migrations/                # SQL migrations (golang-migrate)
├── helm/
│   └── go-service/            # Helm chart
└── docs/
    ├── adrs/                  # ADR 001: Gin, ADR 002: SQS
    └── runbooks/              # Deployment, Debugging, Scaling, DB Migrations
```

**Local Development:**
```bash
cd platform-services-go
go mod download
go run cmd/server/main.go
# Server starts on :8080
```

**Key Commands:**
```bash
# Run tests
go test ./...

# Run migration
migrate -path migrations -database "postgres://..." up

# Build Docker image
docker build -t ghcr.io/org/go-service:local .

# Run load test
k6 run ../platform-infra/tests/go-service-load.js
```

### platform-services-node
**Location:** `/platform-services-node`

**Key Directories:**
```
platform-services-node/
├── src/
│   ├── routes/                # Fastify routes
│   ├── services/              # Business logic
│   ├── plugins/               # Fastify plugins (DB, Redis, Auth)
│   ├── websocket/             # WebSocket server
│   └── consumers/             # SQS consumers
├── prisma/                    # Database schema (if using Prisma)
├── helm/
│   └── node-service/          # Helm chart
└── docs/
    ├── adrs/                  # ADR 001: Fastify, ADR 002: Redis PubSub
    └── runbooks/              # Deployment, Debugging, WS, Redis
```

**Local Development:**
```bash
cd platform-services-node
npm install
npm run dev
# HTTP on :3000, WebSocket on :3001
```

**Key Commands:**
```bash
# Run tests
npm test
npm run test:e2e

# Run with debugger
npm run dev:debug

# Build Docker image
docker build -t ghcr.io/org/node-service:local .
```

### platform-frontend
**Location:** `/platform-frontend`

**Key Directories:**
```
platform-frontend/
├── src/
│   ├── app/                   # Next.js App Router pages
│   │   ├── (auth)/            # Auth route group
│   │   ├── (dashboard)/       # Dashboard route group
│   │   ├── api/               # API routes (minimal)
│   │   └── actions/           # Server Actions
│   ├── components/
│   │   ├── ui/                # shadcn/ui components
│   │   ├── forms/             # Form composites
│   │   ├── tables/            # Table composites
│   │   └── layout/            # Layout components
│   ├── lib/                   # Utilities, API client, query keys
│   ├── hooks/                 # Custom React hooks
│   └── providers/             # Context providers
├── public/                    # Static assets
├── helm/
│   └── frontend/              # Helm chart
└── docs/
    ├── adrs/                  # ADR 001: Next.js, ADR 002: TanStack Query, ADR 003: shadcn/ui
    └── runbooks/              # Deployment, Debugging, Performance, Feature Flags
```

**Local Development:**
```bash
cd platform-frontend
npm install
npm run dev
# App on http://localhost:3000
```

**Key Commands:**
```bash
# Type check
npm run type-check

# Lint
npm run lint

# Run tests
npm test
npm run test:e2e

# Analyze bundle
ANALYZE=true npm run build

# Build Docker image
docker build -t ghcr.io/org/frontend:local .
```

---

## Development Workflow

### Feature Development

#### 1. Create Feature Branch
```bash
# In the relevant repository
git checkout main
git pull origin main
git checkout -b feature/your-feature-name
```

#### 2. Make Changes
- Write code
- Add tests
- Update documentation if needed
- Follow repository conventions

#### 3. Local Testing
```bash
# Run tests
npm test          # frontend, node-service
go test ./...     # go-service

# Type check / lint
npm run type-check
npm run lint

# Build locally
docker build -t ghcr.io/org/<service>:local .
```

#### 4. Open Pull Request
```bash
git push origin feature/your-feature-name
gh pr create --title "feat: your feature" --body "Description..."
```

#### 5. CI Pipeline Runs
- **All repos:** Unit tests, lint, type check, build
- **platform-infra:** Also runs Helm lint, kubeval
- **Required:** All checks must pass

#### 6. Code Review
- At least 1 approval required
- Platform team reviews infra changes
- Service teams review their service changes

#### 7. Merge to Main
- Squash merge preferred
- Deletes branch after merge
- Triggers staging deployment

---

## Deployment & Promotion

### How It Works

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Feature   │───▶│   Main      │───▶│  Staging    │
│   Branch    │    │   (merge)   │    │  (auto)     │
└─────────────┘    └─────────────┘    └─────────────┘
                                            │
                                            ▼
                                   ┌─────────────┐
                                   │  Load Test  │
                                   │  (staging)  │
                                   └─────────────┘
                                            │
                                            ▼
                                   ┌─────────────┐
                                   │ Promotion   │
                                   │  (manual)   │
                                   └─────────────┘
                                            │
                                            ▼
                                   ┌─────────────┐
                                   │ Production  │
                                   │  (manual)   │
                                   └─────────────┘
```

### Staging Deployment (Automatic)
- Triggered on merge to `main`
- GitHub Actions builds & pushes Docker image
- ArgoCD detects new image tag
- Auto-syncs to staging namespace
- Runs smoke tests

### Production Promotion (Manual)

#### Option A: GitHub Actions (Recommended)
```bash
gh workflow run promote.yaml \
  -f environment=production \
  -f services=go-service,frontend \
  -f version=v1.2.3
```

#### Option B: CLI Script
```bash
cd platform-infra
./scripts/promote.sh
# Interactive prompts for environment, services, version
```

#### Option C: ArgoCD Direct (Emergency Only)
```bash
argocd app sync go-service-production --prune
```

### Promotion Stages
| Stage | Description | Gate |
|-------|-------------|------|
| **Validate** | Helm render, policy check | Must pass |
| **Load Test** | k6 tests on staging | Thresholds: p95<500ms, error<1% |
| **Promote** | Update Helm values, commit, push | Manual approval (prod) |
| **Verify** | Deployment health checks | All checks pass |
| **Notify** | Slack, GitHub release | Always runs |

### Rollback
```bash
# Via ArgoCD (instant)
argocd app rollback go-service-production

# Via Git revert
cd platform-infra
git revert <promotion-commit>
git push origin main

# Via CLI
./scripts/promote.sh --rollback --environment production --services go-service
```

---

## Key Operational Procedures

### Daily Operations
- **Check ArgoCD:** `argocd app list` - verify all Synced/Healthy
- **Check Logs:** `kubectl logs -n production deploy/<service> --since=1h | grep -i error`
- **Check Metrics:** Grafana dashboards (see below)

### Incident Response
1. **Detect** - Alert (PagerDuty/Slack) or manual report
2. **Triage** - `./scripts/health-check.sh --all`, determine severity
3. **Communicate** - Create `#incident-<date>-<service>` Slack channel
4. **Resolve** - Follow relevant runbook
5. **Postmortem** - Blameless postmortem within 48h

### Key Runbooks (platform-infra/docs/runbooks/)
- **argocd-operations.md** - ArgoCD sync, rollback, troubleshooting
- **promotion.md** - Promotion procedures, verification
- **backup-restore.md** - PostgreSQL, Vault, ArgoCD backup/restore
- **disaster-recovery.md** - 6 disaster scenarios with RTO/RPO
- **chaos-engineering.md** - LitmusChaos experiments
- **load-testing.md** - k6 test execution
- **secrets-management.md** - Vault + ESO operations

### Service Runbooks (each service repo/docs/runbooks/)
- **deployment.md** - Deploy, configure, verify
- **debugging.md** - Logs, metrics, profiling, common issues
- **scaling.md** - HPA, manual scaling, capacity planning
- **database-migrations.md** - Migration procedures (go-service)
- **websocket-management.md** - WS connections, Pub/Sub (node-service)
- **redis-operations.md** - Redis cluster ops (node-service)
- **performance.md** - Core Web Vitals, bundle optimization (frontend)
- **feature-flags.md** - LaunchDarkly management (frontend)

---

## Monitoring & Observability

### Grafana Dashboards
| Dashboard | Purpose |
|-----------|---------|
| `platform/overview` | Cluster-level health |
| `argocd/overview` | ArgoCD sync status |
| `go-service/overview` | Orders API metrics |
| `node-service/overview` | Notifications + WS metrics |
| `frontend/overview` | Frontend performance |
| `redis/overview` | Redis cluster health |
| `database/overview` | PostgreSQL metrics |

### Key Alerts (PagerDuty)
| Alert | Condition | Severity |
|-------|-----------|----------|
| `ServiceDown` | No ready pods | P1 |
| `HighErrorRate` | 5xx > 1% for 5m | P1 |
| `HighLatency` | p99 > 1s for 5m | P2 |
| `HPAMaxed` | Replicas at max for 10m | P2 |
| `BackupFailed` | Backup job failed | P2 |
| `ArgoCDOutOfSync` | App OutOfSync > 10m | P2 |

### Distributed Tracing
- **Backend:** Tempo/Jaeger
- **Search:** `service.name="go-service" AND error=true`
- **Frontend:** Browser RUM (Vercel Analytics)

---

## Security

### Secrets Management
- **Vault** is the source of truth
- **External Secrets Operator** syncs to Kubernetes secrets
- **Never** commit secrets to Git
- **Rotate** credentials per schedule (see secrets-management runbook)

### Access Control
| Resource | Access Method |
|----------|---------------|
| **Kubernetes** | kubectl with RBAC (GitHub Teams) |
| **ArgoCD** | SSO (GitHub) + RBAC |
| **Vault** | OIDC (GitHub) + Policies |
| **AWS** | IAM roles via Atlantis |
| **Grafana** | SSO (GitHub) |

### Compliance
- All changes via GitOps (audit trail)
- ArgoCD provides deployment history
- Vault audit logging enabled
- SOC 2 Type II certified

---

## Common Tasks

### Add New Service
1. Create new repository from template
2. Add Helm chart in `helm/<service>/`
3. Add ArgoCD Application in `argocd/applications/`
4. Add to ApplicationSet matrix
5. Configure CI/CD workflows
6. Add monitoring (ServiceMonitor, dashboards)
7. Document in ADRs and runbooks

### Update Kubernetes Version
1. Test in dev cluster
2. Update OpenTofu modules
3. Run `atlantis plan` in PR
4. Apply via Atlantis
4. Verify all workloads

### Rotate Credentials
```bash
# Database passwords (auto via Vault)
# JWT secrets
vault kv put secret/platform/jwt signing_key="$(openssl rand -base64 64)"
kubectl rollout restart deployment -n production

# TLS certificates (auto via cert-manager)
```

### Scale for Event
```bash
# Pre-scale
kubectl patch hpa go-service -n production -p '{"spec":{"minReplicas":20}}'

# Monitor
watch kubectl get hpa -n production

# Restore
kubectl patch hpa go-service -n production -p '{"spec":{"minReplicas":5}}'
```

---

## Troubleshooting Quick Reference

| Issue | First Check |
|-------|-------------|
| Pod not starting | `kubectl describe pod` - events |
| ImagePullBackOff | GHCR credentials, image tag exists |
| CrashLoopBackOff | `kubectl logs --previous` |
| Service 503 | Endpoints exist? `kubectl get ep` |
| Ingress 502 | Backend service ready? TLS cert valid? |
| ArgoCD OutOfSync | `argocd app diff`, check Git |
| High latency | `kubectl top pods`, check HPA |
| DB connections | PgBouncer pools, max_connections |
| WS disconnects | Ingress timeouts, sticky sessions |

---

## Useful Commands Cheatsheet

### Kubernetes
```bash
# Get all resources
kubectl get all -n production

# Watch pods
kubectl get pods -n production -w

# Port forward
kubectl port-forward -n production svc/go-service 8080:80

# Exec into pod
kubectl exec -it -n production deploy/go-service -- sh

# View logs
kubectl logs -n production deploy/go-service -f --since=1h

# Resource usage
kubectl top pods -n production
kubectl top nodes
```

### ArgoCD
```bash
# Login
argocd login argocd.example.com --sso

# List apps
argocd app list

# Get app details
argocd app get go-service-production

# Sync
argocd app sync go-service-production --prune

# Rollback
argocd app rollback go-service-production

# History
argocd app history go-service-production
```

### Helm
```bash
# Render chart
helm template go-service ./helm/go-service -f values-production.yaml

# Lint
helm lint ./helm/go-service

# Install/upgrade
helm upgrade --install go-service ./helm/go-service -n production -f values-production.yaml

# Get values
helm get values go-service -n production
```

### GitHub Actions
```bash
# List runs
gh run list --workflow=promote.yaml --limit=10

# Watch run
gh run watch --workflow=promote.yaml

# View logs
gh run view <run-id> --log

# Re-run failed
gh run rerun <run-id> --failed
```

---

## Learning Resources

### Internal Documentation
- **ADRs:** `platform-infra/docs/adrs/`, `platform-services-*/docs/adrs/`, `platform-frontend/docs/adrs/`
- **Runbooks:** `*/docs/runbooks/`
- **Architecture Diagrams:** `platform-infra/docs/architecture/`

### External References
- [ArgoCD Docs](https://argo-cd.readthedocs.io/)
- [Helm Docs](https://helm.sh/docs/)
- [Next.js App Router](https://nextjs.org/docs/app)
- [Fastify Docs](https://fastify.dev/docs/)
- [Gin Docs](https://gin-gonic.com/docs/)
- [TanStack Query](https://tanstack.com/query/latest)
- [shadcn/ui](https://ui.shadcn.com/)
- [LitmusChaos](https://litmuschaos.io/docs/)

---

## Getting Help

### Team Contacts
| Area | Primary | Backup |
|------|---------|--------|
| Platform/Infra | Platform Lead | Senior Engineer |
| Go Service | Go Service Owner | Platform Engineer |
| Node Service | Node Service Owner | Platform Engineer |
| Frontend | Frontend Lead | Senior Engineer |
| Security | Security Lead | DevOps Lead |

### Communication Channels
- **Slack:** `#platform-team`, `#platform-oncall`, `#platform-ops`
- **Incidents:** `#incident-<date>-<service>`
- **Email:** platform-team@company.com
- **Office Hours:** Tuesdays 10:00-11:00 UTC

### Escalation Path
1. Check runbooks and ADRs
2. Ask in `#platform-team` Slack
3. Page on-call via PagerDuty
4. Escalate to Platform Lead

---

## Appendix: Glossary

| Term | Definition |
|------|------------|
| **App-of-Apps** | ArgoCD pattern: root app manages child apps |
| **ApplicationSet** | ArgoCD controller for generating apps from template |
| **ESO** | External Secrets Operator - syncs Vault to K8s secrets |
| **HPA** | Horizontal Pod Autoscaler |
| **ISR** | Incremental Static Regeneration (Next.js) |
| **Ministack** | Local AWS service mocks (S3, SQS, etc.) |
| **PDB** | PodDisruptionBudget |
| **RTO/RPO** | Recovery Time/Point Objective |
| **SQS** | Simple Queue Service (AWS/Ministack) |
| **SSOT** | Single Source of Truth |

---

## Next Steps

1. ✅ Complete this onboarding guide
2. 🔄 Set up your local environment (follow Quick Start)
3. 🔄 Deploy a test change to dev environment
4. 🔄 Shadow a production promotion
5. 🔄 Participate in a chaos engineering experiment
6. 🔄 Review ADRs for your service area
7. 🔄 Join on-call rotation after 30 days

---

**Welcome to the team! 🎉**

*Questions? Improvements? Update this guide and open a PR!*