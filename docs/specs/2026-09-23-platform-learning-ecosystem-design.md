# Platform Learning Ecosystem - Architectural Design Spec

**Date:** 2026-09-23  
**Status:** Draft - Awaiting Review  
**Author:** Platform Team EM Learning Project

---

## 1. Executive Summary

This document specifies a **multi-repository platform learning ecosystem** that mimics a real company's application landscape. The platform consists of four independently owned repositories managed by a platform team, demonstrating infrastructure-as-code, GitOps, CI/CD, container orchestration, and event-driven microservices patterns.

### Learning Objectives
- **Infrastructure & GitOps**: Terraform/OpenTofu, ArgoCD, Atlantis automation
- **Kubernetes Operations**: minikube cluster management, multi-environment namespaces, scaling
- **Event-Driven Architecture**: SQS (via Ministack), async service communication
- **Full CI/CD**: GitHub Actions → local registry → ArgoCD → minikube
- **Platform Tooling**: Base images (Distroless), secrets (External Secrets + Vault), observability (kube-prometheus-stack)

---

## 2. Repository Structure (Multi-Repo)

| Repository | Owner | Purpose | Key Technologies |
|------------|-------|---------|------------------|
| `platform-infra` | Platform Team | All infrastructure: Terraform, ArgoCD, Atlantis, K8s manifests | OpenTofu, ArgoCD, Atlantis, Helm/Kustomize |
| `platform-services-go` | Platform Team | Go microservice (Orders/Events API) | Go 1.22+, Gin/Fiber, PostgreSQL client |
| `platform-services-node` | Platform Team | Node.js microservice (Notifications/Processing) | Node.js 20+, Fastify, TypeScript |
| `platform-frontend` | Platform Team | Next.js observability dashboard | Next.js 14+, React 18, Tailwind, WebSocket |

### Repository Independence
- Each repo has its own CI/CD pipeline
- ArgoCD watches all repos via ApplicationSet
- Atlantis only manages `platform-infra` (Terraform)
- Shared contracts via OpenAPI specs in a `platform-contracts` subfolder (or separate repo later)

---

## 3. Infrastructure Architecture (platform-infra)

### 3.1 Local AWS Simulation: Ministack
**Decision:** Use [Ministack](https://ministack.org) - modern, fully free LocalStack alternative
- Runs as containers in minikube (or standalone Docker)
- Provides: SQS, S3, DynamoDB, SNS, EventBridge, Secrets Manager, SSM Parameter Store
- API-compatible with AWS SDKs
- Lightweight, fast startup

### 3.2 Kubernetes: minikube (Single Cluster)
**Decision:** Single minikube cluster hosting:
- Application workloads (3 namespaces: dev, staging, prod)
- ArgoCD (argocd namespace)
- Atlantis (atlantis namespace)
- Ministack (ministack namespace)
- kube-prometheus-stack (monitoring namespace)
- Vault (vault namespace)
- Local Docker registry (registry namespace)

**minikube Configuration:**
```yaml
# ~/.minikube/profiles/minikube/config.json
{
  "cpus": 4,
  "memory": "8192mb",
  "disk-size": "50g",
  "driver": "docker",
  "addons": ["ingress", "metrics-server"]
}
```

### 3.3 Multi-Environment Strategy
Three namespaces in single cluster:
- **dev** - Continuous deployment from `main` branch
- **staging** - Manual promotion via ArgoCD CLI/UI
- **prod** - Protected, requires approval, separate ArgoCD AppProject

**ArgoCD App-of-Apps Pattern:**
```
argocd/
├── applications/
│   ├── platform-infra.yaml       # Manages infra components
│   ├── platform-services-go.yaml # Go service across envs
│   ├── platform-services-node.yaml
│   └── platform-frontend.yaml
├── projects/
│   ├── dev-project.yaml
│   ├── staging-project.yaml
│   └── prod-project.yaml
└── applicationset/
    └── services-applicationset.yaml  # Generates per-env apps
```

### 3.4 GitOps: ArgoCD
- **Installation:** Helm chart in `platform-infra/argocd/`
- **Auth:** Dex + GitHub OAuth (local) or static admin for learning
- **Sync Policy:** Automated for dev, manual for staging/prod
- **Health Checks:** Custom Lua scripts for service readiness

### 3.5 Terraform Automation: Atlantis + OpenTofu
- **OpenTofu** (v1.7+) as Terraform drop-in replacement
- **Atlantis** deployed in minikube via Helm
- **Webhook:** ngrok/cloudflared tunnel to GitHub for PR events
- **Workflow:**
  1. PR opened in `platform-infra` → Atlantis `plan` comment
  2. Review → `atlantis apply` comment → apply
  3. ArgoCD detects manifest changes → syncs to cluster

**Atlantis Server Config (atlantis.yaml):**
```yaml
version: 3
automerge: true
delete_source_branch_on_merge: true
parallel_plan: true
parallel_apply: false
projects:
  - name: platform-infra
    dir: .
    workspace: default
    terraform_version: v1.7.0  # OpenTofu version
    apply_requirements: [approved, mergeable]
    import_requirements: [approved]
```

### 3.6 Secrets Management: External Secrets Operator + Vault
- **Vault:** HashiCorp Vault in dev mode (minikube)
- **External Secrets Operator:** Syncs Vault secrets → K8s secrets
- **SecretStore:** ClusterSecretStore pointing to Vault
- **ExternalSecret:** Per-service, per-environment

```
Vault KV v2
└── secret/
    ├── platform/
    │   ├── go-service/
    │   │   ├── database-url
    │   │   └── jwt-secret
    │   ├── node-service/
    │   │   ├── database-url
    │   │   └── redis-url
    │   └── frontend/
    │       └── nextauth-secret
    └── ministack/
        └── aws-credentials
```

### 3.7 Observability: kube-prometheus-stack
**Components:**
- **Prometheus** - Metrics collection (30d retention)
- **Grafana** - Dashboards (pre-built + custom)
- **Alertmanager** - Alert routing
- **Node Exporter** - Host metrics
- **kube-state-metrics** - K8s object metrics

**Custom Dashboards (Grafana):**
- Platform Overview (cluster health, deploy frequency)
- Service Golden Signals (latency, traffic, errors, saturation)
- Business Metrics (orders created, notifications sent)
- Infrastructure (minikube resources, Ministack queue depths)

### 3.8 Container Registry
- **Local:** Helm-installed registry in the `registry` namespace (port 5000), deployed by
  `tofu/modules/registry/` — **not** the minikube `registry` addon. That addon's proxy
  image (`gcr.io/k8s-minikube/kube-registry-proxy:0.0.6`) was deleted upstream, and the
  addon has no configuration override; it was also redundant with the Helm registry this
  design already specifies. See the Task 2 rationale in the Phase 1 plan.
- **Image Tagging:** `{service}:{git-sha}-{short-branch}`
- **Base Images:** Built separately, pushed to registry
- **SBOM:** Syft/Grype scanning in CI

---

## 4. Service Specifications

### 4.1 platform-services-go (Orders API)

**Responsibility:** Order ingestion, validation, persistence, event publishing

**Tech Stack:**
- Go 1.22+
- **Framework:** Gin (lightweight, performant)
- **Database:** PostgreSQL (pgx driver)
- **Messaging:** AWS SDK v2 for SQS (Ministack endpoint)
- **Observability:** OpenTelemetry (OTel) Go SDK → Prometheus
- **Config:** Viper (env + config file)
- **Migration:** golang-migrate

**API Endpoints:**
```
POST   /api/v1/orders           # Create order
GET    /api/v1/orders/:id       # Get order
GET    /api/v1/orders           # List orders (pagination)
GET    /health                  # Liveness
GET    /ready                   # Readiness (DB + SQS check)
```

**Data Model (PostgreSQL - schema: orders):**
```sql
CREATE TABLE orders (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id     VARCHAR(255) NOT NULL,
    items           JSONB NOT NULL,
    total_amount    DECIMAL(10,2) NOT NULL,
    status          VARCHAR(50) NOT NULL DEFAULT 'pending',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_orders_customer_id ON orders(customer_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_created_at ON orders(created_at DESC);
```

**Event Publishing (SQS):**
- Queue: `order-events` (Ministack SQS)
- Message Format (CloudEvents v1.0):
```json
{
  "specversion": "1.0",
  "id": "<uuid>",
  "source": "platform.orders",
  "type": "order.created",
  "time": "2026-09-23T10:00:00Z",
  "datacontenttype": "application/json",
  "data": {
    "orderId": "<uuid>",
    "customerId": "cust-123",
    "totalAmount": 99.99,
    "items": [...]
  }
}
```

**K8s Deployment (Helm Chart):**
```yaml
# values.yaml
replicaCount: 2
resources:
  limits:
    cpu: 500m
    memory: 256Mi
  requests:
    cpu: 100m
    memory: 128Mi
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilization: 70
```

### 4.2 platform-services-node (Notifications API)

**Responsibility:** Consume order events, process notifications, provide query API

**Tech Stack:**
- Node.js 20+ (LTS)
- **Framework:** Fastify (fast, schema-based)
- **Language:** TypeScript (strict mode)
- **Database:** PostgreSQL (pg + Kysely for type-safe queries)
- **Cache/Queue:** Redis (ioredis) - caching, sessions, pub/sub
- **Messaging:** AWS SDK v3 SQS consumer (polling)
- **Observability:** @opentelemetry/api + auto-instrumentation
- **Validation:** Zod schemas
- **Testing:** Vitest + Testcontainers

**API Endpoints:**
```
GET    /api/v1/notifications/:orderId    # Get notifications for order
GET    /api/v1/notifications             # List (with filters)
WS     /ws/notifications                 # Real-time updates
GET    /health                           # Liveness
GET    /ready                            # Readiness (DB + Redis + SQS)
```

**Data Model (PostgreSQL - schema: notifications):**
```sql
CREATE TABLE notifications (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id        UUID NOT NULL REFERENCES orders.orders(id),
    type            VARCHAR(50) NOT NULL,  -- 'email', 'push', 'sms', 'in_app'
    recipient       VARCHAR(255) NOT NULL,
    subject         VARCHAR(500),
    body            TEXT NOT NULL,
    status          VARCHAR(50) NOT NULL DEFAULT 'pending', -- pending, sent, failed
    provider_id     VARCHAR(255),          -- External provider reference
    sent_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_notifications_order_id ON notifications(order_id);
CREATE INDEX idx_notifications_status ON notifications(status);
```

**SQS Consumer:**
- Polls `order-events` queue (long polling, 20s wait)
- Processes `order.created` → creates in-app notification
- Simulates email/push via async workers
- Updates status in DB, publishes to Redis pub/sub for WebSocket

**Redis Usage:**
- **Caching:** Notification lists (TTL 60s)
- **Sessions:** WebSocket connection mapping
- **Pub/Sub:** Real-time notification broadcast

**K8s Deployment:**
```yaml
replicaCount: 2
resources:
  limits:
    cpu: 500m
    memory: 512Mi  # Node.js needs more memory
  requests:
    cpu: 100m
    memory: 256Mi
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
```

### 4.3 Shared Database: PostgreSQL
- **Single instance** in minikube (CloudNativePG operator or Helm)
- **Separate schemas:** `orders` (Go service), `notifications` (Node service)
- **Connection Pooling:** PgBouncer sidecar per service
- **Backups:** CronJob with pg_dump to S3 (Ministack)
- **Migrations:** Applied via initContainers on deploy

---

## 5. Frontend Specification (platform-frontend)

### 5.1 Next.js Dashboard
**Purpose:** Platform observability dashboard - shows service health, events, deployments

**Tech Stack:**
- Next.js 14 (App Router)
- React 18 + TypeScript
- **Styling:** Tailwind CSS + shadcn/ui components
- **State:** TanStack Query (server state) + Zustand (client state)
- **Real-time:** WebSocket (native) + SWR for polling fallback
- **Charts:** Recharts (metrics visualization)
- **Auth:** NextAuth.js (GitHub OAuth for ArgoCD SSO simulation)

### 5.2 Pages / Features
| Route | Description |
|-------|-------------|
| `/` | Platform overview - cluster health, deploy status, key metrics |
| `/services/go` | Go service: order list, create order form, event stream |
| `/services/node` | Node service: notifications, processing status |
| `/infrastructure` | ArgoCD apps, Atlantis PRs, Terraform state |
| `/observability` | Grafana iframe embed + custom metrics panels |
| `/deployments` | Deployment history, rollback triggers |

### 5.3 Real-Time Architecture
```
Frontend (Next.js)          Go Service           Node Service
     │                          │                     │
     ├── WS /ws/orders ────────▶│                     │
     │                          │                     │
     │                    SQS: order.created          │
     │                          │────────────────────▶│
     │                          │                     ├── WS /ws/notifications
     │                          │                     │
     │◀──── REST /api/orders ───│                     │
     │◀──── REST /api/notif ────│────────────────────▶│
```

---

## 6. CI/CD Pipeline Design

### 6.1 Per-Repository GitHub Actions

**Common Workflow Template (`.github/workflows/ci.yaml`):**
```yaml
name: CI
on: [push, pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Lint (golangci-lint / eslint / prettier)
  
  test:
    runs-on: ubuntu-latest
    services:
      postgres: { image: postgres:16, env: ... }
      redis: { image: redis:7 }
      ministack: { image: ghcr.io/ministack/ministack:v0.9.0 }
    steps:
      - uses: actions/checkout@v4
      - name: Unit + Integration tests
  
  build:
    needs: [lint, test]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build multi-arch image (docker buildx)
      - name: Scan (Trivy/Grype)
      - name: Push to local registry (minikube IP)
      - name: Update K8s manifests (Kustomize/Helm)
      - name: Commit manifest changes (if main branch)
```

### 6.2 Platform-Infra Specific Pipeline
```yaml
# Additional jobs for platform-infra
atlantis-plan:
  needs: build
  if: github.event_name == 'pull_request'
  steps:
    - name: Trigger Atlantis plan via webhook
    - name: Wait for plan comment
    - name: Post plan summary

atlantis-apply:
  needs: atlantis-plan
  if: github.event_name == 'pull_request' && github.event.pull_request.merged == true
  steps:
    - name: Trigger Atlantis apply
    - name: Verify ArgoCD sync
```

### 6.3 Image Promotion Flow
```
main branch push
      │
      ▼
┌─────────────┐
│ Build Image │──▶ platform-services-go:sha-abc123
│ (multi-arch)│
└─────────────┘
      │
      ▼
┌─────────────┐
│ Update      │──▶ Kustomize: set new image tag in
│ Manifests   │     platform-infra/overlays/dev/go-service/
└─────────────┘
      │
      ▼
┌─────────────┐
│ Commit &    │──▶ platform-infra repo: "chore: update go-service to sha-abc123"
│ Push        │
└─────────────┘
      │
      ▼
┌─────────────┐
│ ArgoCD      │──▶ Detects change → Syncs dev namespace
│ Auto-Sync   │
└─────────────┘
```

### 6.4 Base Images (Platform Team Provides)
**Location:** `platform-tooling/base-images/` (subfolder in platform-infra or separate repo)

| Image | Base | Purpose |
|-------|------|---------|
| `platform/go-base:1.22` | `gcr.io/distroless/base-debian12` | Go runtime |
| `platform/go-build:1.22` | `golang:1.22-alpine` | Go build (multi-stage) |
| `platform/node-base:20` | `gcr.io/distroless/nodejs20-debian12` | Node runtime |
| `platform/node-build:20` | `node:20-alpine` | Node build |

**Build Process:**
```dockerfile
# Go build stage
FROM platform/go-build:1.22 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /app/server .

# Runtime stage
FROM platform/go-base:1.22
COPY --from=builder /app/server /server
USER nonroot:nonroot
ENTRYPOINT ["/server"]
```

---

## 7. Implementation Phases (Approach 1: Incremental Vertical Slices)

### Phase 1: Foundation - Infrastructure Only (Week 1-2)
**Goal:** Working minikube + Ministack + ArgoCD + Atlantis + Vault + Prometheus

**Deliverables:**
- [ ] `platform-infra` repo initialized
- [ ] minikube cluster with all addons
- [ ] Ministack deployed (Helm/manifests)
- [ ] ArgoCD installed, GitHub OAuth configured
- [ ] Atlantis deployed, ngrok webhook working
- [ ] Vault + External Secrets Operator
- [ ] kube-prometheus-stack with custom dashboards
- [ ] Local registry + image pull secrets
- [ ] Terraform/OpenTofu modules for all above
- [ ] Atlantis plan/apply working on PR
- [ ] **README.md** with setup instructions

**Validation:** `atlantis plan` on PR → `atlantis apply` → ArgoCD syncs → all pods healthy

---

### Phase 2: Go Service - Orders API (Week 2-3)
**Goal:** Go service deployed via ArgoCD, writing to PostgreSQL, publishing to SQS

**Deliverables:**
- [ ] `platform-services-go` repo initialized
- [ ] Go service with Gin, PostgreSQL, SQS publisher
- [ ] Health/readiness endpoints
- [ ] OpenTelemetry instrumentation
- [ ] Unit + integration tests (Testcontainers)
- [ ] Multi-stage Dockerfile (Distroless runtime)
- [ ] Helm chart with HPA, PgBouncer sidecar
- [ ] PostgreSQL + PgBouncer deployed (CloudNativePG)
- [ ] CI pipeline: lint → test → build → push → update manifests
- [ ] ArgoCD Application for dev namespace
- [ ] **README.md** with API docs, local dev guide

**Validation:** Create order via API → verify in PostgreSQL → verify SQS message in Ministack

---

### Phase 3: Node.js Service - Notifications (Week 3-4)
**Goal:** Node.js service consuming SQS, writing notifications, WebSocket API

**Deliverables:**
- [ ] `platform-services-node` repo initialized
- [ ] Fastify + TypeScript service
- [ ] SQS consumer (order.created → create notification)
- [ ] Redis for caching + pub/sub
- [ ] WebSocket endpoint for real-time updates
- [ ] PostgreSQL (notifications schema) + Kysely
- [ ] Unit + integration tests
- [ ] Multi-stage Dockerfile (Distroless Node.js)
- [ ] Helm chart with HPA
- [ ] CI pipeline
- [ ] ArgoCD Application for dev namespace
- [ ] **README.md**

**Validation:** Create order via Go API → Node service consumes → notification appears via WebSocket

---

### Phase 4: Frontend Dashboard (Week 4-5)
**Goal:** Next.js dashboard showing live data from both services

**Deliverables:**
- [ ] `platform-frontend` repo initialized
- [ ] Next.js 14 App Router + Tailwind + shadcn/ui
- [ ] Dashboard pages (overview, services, infra, observability)
- [ ] WebSocket connections to both services
- [ ] TanStack Query for REST APIs
- [ ] NextAuth.js (GitHub OAuth)
- [ ] Grafana iframe embed (iframe-resizer)
- [ ] Multi-stage Dockerfile (Standalone output)
- [ ] Helm chart
- [ ] CI pipeline
- [ ] ArgoCD Application
- [ ] **README.md**

**Validation:** Open dashboard → see real-time orders + notifications

---

### Phase 5: Production Hardening & Documentation (Week 5-6)
**Goal:** Multi-env promotion, full CI/CD, comprehensive docs

**Deliverables:**
- [ ] Staging/prod ArgoCD Applications + AppProjects
- [ ] Promotion workflow (ArgoCD CLI + GitHub Actions)
- [ ] Atlantis automation for all Terraform changes
- [ ] Disaster recovery: backup/restore procedures
- [ ] Load testing (k6 scripts)
- [ ] Chaos engineering basics (LitmusChaos or manual)
- [ ] **Comprehensive README per repo**
- [ ] **Architecture decision records (ADRs)** in each repo
- [ ] **Runbooks** for common operations
- [ ] **Developer onboarding guide** (single doc linking all repos)

---

## 8. Directory Structure (Per Repository)

### platform-infra/
```
platform-infra/
├── .github/workflows/
│   ├── ci.yaml
│   └── atlantis.yaml
├── atlantis.yaml                 # Atlantis server config
├── terraform/
│   ├── modules/
│   │   ├── minikube-cluster/     # Not used locally, for cloud reference
│   │   ├── ministack/
│   │   ├── argocd/
│   │   ├── atlantis/
│   │   ├── vault/
│   │   ├── external-secrets/
│   │   ├── prometheus-stack/
│   │   ├── postgresql/
│   │   └── registry/
│   ├── environments/
│   │   ├── dev/
│   │   ├── staging/
│   │   └── prod/
│   └── main.tf
├── argocd/
│   ├── applications/
│   ├── projects/
│   └── applicationset/
├── kubernetes/
│   ├── base/                     # Common Kustomize bases
│   └── overlays/
│       ├── dev/
│       ├── staging/
│       └── prod/
├── helm/                         # Custom Helm charts if needed
├── scripts/
│   ├── setup-minikube.sh
│   ├── setup-ngrok.sh
│   └── seed-vault.sh
├── docs/
│   ├── adr/
│   └── runbooks/
├── Makefile
├── README.md
└── .tool-versions                # mise/asdf versions
```

### platform-services-go/
```
platform-services-go/
├── .github/workflows/ci.yaml
├── cmd/server/main.go
├── internal/
│   ├── config/
│   ├── domain/
│   │   ├── order/
│   │   └── event/
│   ├── infrastructure/
│   │   ├── postgres/
│   │   ├── sqs/
│   │   └── otel/
│   └── interfaces/
│       └── http/
├── migrations/
├── Dockerfile
├── docker-compose.yml            # Local dev (postgres, ministack)
├── helm/
│   └── go-service/
├── kustomize/
│   ├── base/
│   └── overlays/dev/
├── go.mod / go.sum
├── Makefile
├── README.md
└── .tool-versions
```

### platform-services-node/
```
platform-services-node/
├── .github/workflows/ci.yaml
├── src/
│   ├── main.ts
│   ├── config/
│   ├── modules/
│   │   ├── orders/               # SQS consumer
│   │   ├── notifications/        # CRUD + WebSocket
│   │   └── health/
│   ├── infrastructure/
│   │   ├── database/             # Kysely + pg
│   │   ├── redis/
│   │   ├── sqs/
│   │   └── otel/
│   └── shared/
├── prisma/ or migrations/        # SQL migrations
├── Dockerfile
├── docker-compose.yml
├── helm/
│   └── node-service/
├── kustomize/
├── package.json / tsconfig.json
├── Makefile
├── README.md
└── .tool-versions
```

### platform-frontend/
```
platform-frontend/
├── .github/workflows/ci.yaml
├── src/
│   ├── app/                      # Next.js App Router
│   │   ├── (dashboard)/
│   │   ├── api/                  # API routes if needed
│   │   └── layout.tsx
│   ├── components/
│   │   ├── ui/                   # shadcn/ui
│   │   ├── charts/
│   │   └── websocket/
│   ├── lib/
│   │   ├── api/                  # TanStack Query hooks
│   │   ├── auth/
│   │   └── ws/
│   └── styles/
├── public/
├── Dockerfile
├── next.config.js
├── tailwind.config.ts
├── package.json
├── Makefile
├── README.md
└── .tool-versions
```

---

## 9. Development Workflow

### 9.1 Local Development (Per Service)
```bash
# In each service repo
make dev          # Starts docker-compose (postgres, redis, ministack)
make test         # Runs tests against local stack
make build        # Builds Docker image locally
```

### 9.2 Full Platform Local Development
```bash
# In platform-infra
make cluster-up       # Starts minikube, enables addons
make deploy-infra     # Applies Terraform → deploys ArgoCD, Vault, etc.
make deploy-services  # Deploys all services via ArgoCD (or Helm directly)
make port-forwards    # Forwards ArgoCD, Grafana, services to localhost
```

### 9.3 Making Changes
1. **Service change:** Push to service repo → CI builds image → updates platform-infra manifests → ArgoCD syncs
2. **Infra change:** PR to platform-infra → Atlantis plan → approve → apply → ArgoCD syncs
3. **Base image change:** Update platform-infra/base-images → rebuild → update all service Dockerfiles

---

## 10. Key Decisions & Trade-offs

| Decision | Rationale | Alternative Considered |
|----------|-----------|------------------------|
| Multi-repo | Platform team ownership boundaries | Monorepo (easier dev, less realistic) |
| minikube single cluster | Production-like, supports all components | kind/k3d (lighter but less features) |
| Ministack | Free, modern, full AWS API | LocalStack (licensing), SAM CLI (limited) |
| OpenTofu + Atlantis | GitOps-native Terraform automation | GitHub Actions only (less realistic) |
| External Secrets + Vault | Industry standard for platform teams | Sealed Secrets (simpler, less flexible) |
| kube-prometheus-stack | Platform team owns observability | Datadog/New Relic (cost), lightweight (incomplete) |
| Distroless base images | Security best practice, platform standard | Alpine/Debian (more CVEs), Wolfi (newer) |
| Separate schemas in shared PG | Operational simplicity for platform team | Separate instances (more realistic isolation) |
| App-of-Apps ArgoCD | Scales to many services, env promotion | Single Application per service (doesn't scale) |

---

## 11. Success Criteria

### Phase 1 (Infra)
- [ ] `make cluster-up && make deploy-infra` → all pods Running in 5 min
- [ ] Atlantis plan/apply works on sample PR
- [ ] ArgoCD UI accessible, shows all apps Synced
- [ ] Grafana dashboards show cluster metrics
- [ ] Vault unsealed, External Secrets syncing

### Phase 2 (Go Service)
- [ ] `curl POST /api/v1/orders` → 201 + order in PostgreSQL
- [ ] SQS message visible in Ministack console
- [ ] HPA scales on load test
- [ ] Prometheus metrics exposed (`/metrics`)

### Phase 3 (Node Service)
- [ ] Order created → notification appears in Node service DB
- [ ] WebSocket receives real-time notification
- [ ] Redis caching works (check TTL, invalidation)

### Phase 4 (Frontend)
- [ ] Dashboard loads, shows live order count
- [ ] Create order form works end-to-end
- [ ] Real-time updates via WebSocket
- [ ] Grafana iframe embedded

### Phase 5 (Hardening)
- [ ] Promotion dev → staging → prod works
- [ ] Rollback via ArgoCD UI works
- [ ] All repos have complete README + ADRs
- [ ] New developer can onboard in < 30 min using docs

---

## 12. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| minikube resource exhaustion | High | Medium | Start with 8GB RAM, monitor, add swap |
| Ministack AWS API gaps | Medium | Low | Document limitations, use mock for missing |
| Atlantis webhook flakiness | Medium | High | Use cloudflared tunnel, document troubleshooting |
| ArgoCD sync loops | Low | High | Proper health checks, sync waves |
| OpenTofu vs Terraform drift | Low | Medium | Pin versions, test upgrades in staging |
| Distroless debugging difficulty | Medium | Low | Include busybox in build stage, use `kubectl debug` |

---

## 13. Next Steps

1. **Review this spec** - Confirm approach, suggest modifications
2. **Invoke writing-plans skill** - Create detailed implementation plan with tasks
3. **Initialize platform-infra repo** - Start with Phase 1 foundation
4. **Set up GitHub repositories** - Create 4 repos, configure secrets, branch protection

---

## Appendix: Tool Versions (pinned in `.tool-versions`)

| Tool | Version |
|------|---------|
| go | 1.22.5 |
| nodejs | 20.17.0 |
| python | 3.12.5 (for ansible/scripts) |
| terraform | 1.9.5 (OpenTofu 1.7.0) |
| kubectl | 1.30.2 |
| helm | 3.15.3 |
| argocd-cli | 2.10.5 |
| atlantis | 0.28.0 |
| minikube | 1.34.0 |
| docker | 27.1.0 |
| mise | 2024.10.0 |

---

*This spec will be committed to `platform-infra/docs/specs/` and referenced by all repositories.*