# platform-infra

Infrastructure for the platform learning ecosystem: OpenTofu, ArgoCD, Atlantis, Vault,
External Secrets, kube-prometheus-stack, Ministack, and a local registry on minikube.

## Quick Start

```bash
# 1. Toolchain. `mise install` puts the tools in mise's shims, but on macOS it
#    does NOT shadow /usr/bin/make, so `make` would still resolve to Apple's
#    BSD Make 3.81 — and GNU Make 4 is a hard requirement (the heredoc recipes
#    in later tasks need it). Either activate mise in your shell...
mise trust && mise install
eval "$(mise activate bash)"     # or: mise activate zsh
make --version                   # must report GNU Make 4.4.1

# ...or skip the shell setup and call make through mise explicitly:
mise exec -- make cluster-up
```

```bash
make cluster-up
make deploy-infra
make port-forwards
make verify        # must print: PHASE 1 VERIFICATION PASSED
```

> **Quick start note:** The whole point of `.tool-versions` is that a shell which has mise active resolves `make` to the pinned 4.4.1. The two `mise exec --` lines are the escape hatch for a shell where it does not — documented rather than assumed, because a reader who hits BSD Make 3.81 on their first `make deploy-infra` will otherwise conclude the pin is broken.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Cluster Lifecycle](#cluster-lifecycle)
- [Infrastructure Deployment](#infrastructure-deployment)
- [Service Deployment](#service-deployment)
- [Port Forwarding (macOS/Linux)](#port-forwarding-macoslinux)
- [Accessing UIs](#accessing-uis)
- [Local Service Development](#local-service-development)
- [ArgoCD Operations](#argocd-operations)
- [Atlantis Operations](#atlantis-operations)
- [Promotion Workflows](#promotion-workflows)
- [Verification & Testing](#verification--testing)
- [Cross-Platform Notes](#cross-platform-notes)
- [Troubleshooting](#troubleshooting)
- [Learning Path](#learning-path)

---

## Prerequisites

### Required Tools (pinned in `.tool-versions`)

| Tool | Version | Purpose |
|------|---------|---------|
| mise | 2026.9.14+ | Toolchain manager |
| make | 4.4.1 | Build orchestration (GNU Make required) |
| minikube | 1.34.0 | Local Kubernetes |
| kubectl | 1.30.2 | K8s CLI |
| helm | 3.15.3 | Package manager |
| opentofu | 1.7.0 | Infrastructure as Code |
| docker-cli | 27.1.0 | Container CLI |
| argocd-cli | 2.10.5 | ArgoCD CLI |
| aws-cli | 2.17.0 | AWS CLI (for Ministack) |
| jq | 1.8.2 | JSON processor |

### Platform-Specific Requirements

| Platform | Requirement |
|----------|-------------|
| **macOS** | Docker Desktop ≥ 8GB RAM (Settings → Resources → Advanced) |
| **Linux** | KVM/libvirt for minikube driver; `sudo usermod -aG kvm,libvirt $USER` |

### Install Toolchain

```bash
# Install mise (if not present)
curl https://mise.run | sh

# Trust and install pinned versions
mise trust && mise install

# Activate in your shell (add to ~/.bashrc or ~/.zshrc)
eval "$(mise activate bash)"   # bash
mise activate zsh              # zsh

# Verify
make toolchain-verify
```

---

## Cluster Lifecycle

### Create/Start Cluster

```bash
# Standard (idempotent - safe to re-run)
make cluster-up

# With custom resources
MINIKUBE_CPUS=6 MINIKUBE_MEMORY=12000mb make cluster-up

# Background start (no wait for addons)
make cluster-up-bg
```

**What `cluster-up` does:**
- Creates/start minikube profile `platform` (configurable via `MINIKUBE_PROFILE`)
- Kubernetes v1.30.2 on Docker driver
- Enables `ingress` and `metrics-server` addons
- Configures node for local registry access (insecure-registry + /etc/hosts)
- Waits for API server `/readyz` endpoint
- Re-enables default addons with validation skipped

### Cluster Management

```bash
# Show status
make cluster-status

# Get cluster IP
make cluster-ip

# SSH into node
make cluster-shell

# View logs
make cluster-logs

# Delete cluster (destructive)
make cluster-down

# Full reset (delete + recreate)
make cluster-reset
```

---

## Infrastructure Deployment

### Deploy All Infrastructure

```bash
# Full deployment (ArgoCD, Vault, Ministack, Prometheus, Registry, etc.)
make deploy-infra

# Show plan without applying
make deploy-infra-plan

# Deploy specific module only
make deploy-infra-target MODULE=argocd
make deploy-infra-target MODULE=vault
make deploy-infra-target MODULE=ministack
```

### OpenTofu Modules

| Module | Purpose |
|--------|---------|
| `namespace` | Platform namespaces (argocd, atlantis, ministack, vault, monitoring, registry, dev, staging, prod) |
| `argocd` | ArgoCD Helm release + bootstrap Application |
| `atlantis` | Atlantis Helm release + repo creds + tunnel job |
| `ministack` | Ministack Helm release + queue bootstrap Job |
| `vault` | Vault Helm release (dev mode) + policies |
| `external_secrets` | ESO Helm release + ClusterSecretStore |
| `prometheus` | kube-prometheus-stack Helm release |
| `registry` | Local Docker registry + image pull secret |
| `postgresql` | PostgreSQL (CloudNativePG) |

### Infrastructure State

```bash
# Show outputs (endpoints, namespaces)
make tofu-outputs

# Format and validate
make tofu-fmt
```

---

## Service Deployment

The platform uses **ArgoCD ApplicationSet** to deploy services from separate GitHub repositories:

- `platform-services-go` (Orders API)
- `platform-services-node` (Notifications API + WebSocket)
- `platform-frontend` (Next.js Dashboard)

### Deploy via ArgoCD (GitOps)

```bash
# Deploy all services to dev namespace
make deploy-services

# Deploy individual services
make deploy-service-go
make deploy-service-node
make deploy-service-frontend

# Check status
make service-status
```

### Local Service Development

For active development on services, clone the repos and run locally with docker-compose:

```bash
# Clone all service repos
make clone-services

# Start Go service locally (hot reload)
make service-dev-go

# Start Node service locally (hot reload)
make service-dev-node

# Start Frontend locally (hot reload)
make service-dev-frontend
```

Each service repo has its own `Makefile` with `dev`, `build`, `test`, `push` targets.

### Build & Push to Local Registry

```bash
# Build and push Go service image
make local-build-go
make local-push-go

# Build and push Node service image
make local-build-node
make local-push-node

# Build and push Frontend image
make local-build-frontend
make local-push-frontend
```

---

## Port Forwarding (macOS/Linux)

**Important:** On macOS with Docker Desktop, minikube's IP is inside the Docker VM and not directly accessible from the host. Use `kubectl port-forward` instead of `minikube tunnel` for NodePort services (like ingress-nginx).

### Forward All Services

```bash
# Runs in foreground (Ctrl+C to stop)
make port-forwards
```

This forwards:
- ArgoCD: `localhost:8081`
- Grafana: `localhost:3000`
- Prometheus: `localhost:9090`
- Vault: `localhost:8200`
- Ministack: `localhost:4566`
- Registry: `localhost:5000`
- Atlantis: `localhost:8080`

### Forward Individual Services

```bash
# ArgoCD UI
make port-forward-argocd

# Grafana
make port-forward-grafana

# Prometheus
make port-forward-prometheus

# Vault
make port-forward-vault

# Ministack (AWS APIs)
make port-forward-ministack

# Local Registry
make port-forward-registry

# Atlantis
make port-forward-atlantis

# Ingress (nginx) - use port-forward on macOS, NOT tunnel
make port-forward-ingress
```

### Accessing Ingress on macOS

```bash
# Terminal 1: Start port-forward (keep running)
make port-forward-ingress

# Terminal 2: Test
curl http://localhost:8080
# Returns 404 (expected - no Ingress resources yet)
```

---

## Accessing UIs

### ArgoCD
- URL: `http://localhost:8081` (after `make port-forward-argocd`)
- Username: `admin`
- Password: `make argocd-password`

### Grafana
- URL: `http://localhost:3000` (after `make port-forward-grafana`)
- Username: `admin`
- Password: `prom-operator` (default for kube-prometheus-stack)

### Prometheus
- URL: `http://localhost:9090` (after `make port-forward-prometheus`)

### Vault
- URL: `http://localhost:8200` (after `make port-forward-vault`)
- Token: `make vault-token` (dev mode root token)

### Ministack (AWS APIs)
- URL: `http://localhost:4566` (after `make port-forward-ministack`)
- Test: `awslocal sqs list-queues` (requires aws-cli + awslocal)

### Atlantis
- URL: `http://localhost:8080` (after `make port-forward-atlantis`)

---

## Local Service Development

Each service repository is designed for local development with docker-compose:

### platform-services-go

```bash
cd ../platform-services-go
make dev          # Starts postgres, ministack, runs service with hot reload
make test         # Unit + integration tests
make build        # Build Docker image
make lint         # golangci-lint
```

**Local stack:** PostgreSQL (5432), Ministack (4566)

### platform-services-node

```bash
cd ../platform-services-node
make dev          # Starts postgres, redis, ministack, runs service with hot reload
make test         # Vitest + Testcontainers
make build        # Build Docker image
make lint         # eslint + prettier
```

**Local stack:** PostgreSQL (5432), Redis (6379), Ministack (4566)

### platform-frontend

```bash
cd ../platform-frontend
make dev          # Starts Next.js dev server with hot reload
make test         # Vitest + Playwright
make build        # Build standalone Docker image
make lint         # eslint + prettier + typecheck
```

---

## ArgoCD Operations

### Sync Applications

```bash
# Sync all applications
make argocd-sync

# Sync specific application
make argocd-sync-app APP=go-service-dev
```

### CLI Access

```bash
# Login to ArgoCD CLI
make argocd-login

# List applications
make argocd-apps

# Get password
make argocd-password
```

### Application Structure

```
argocd/
├── projects/
│   ├── platform-system.yaml  # Platform components
│   ├── dev.yaml              # Dev environment
│   ├── staging.yaml          # Staging environment
│   └── prod.yaml             # Prod environment (protected)
├── applications/
│   ├── platform-system.yaml  # Self-manages platform
│   ├── go-service-dev.yaml
│   ├── node-service-dev.yaml
│   ├── frontend-dev.yaml
│   └── ...staging/prod variants
└── applicationset/
    └── services-applicationset.yaml  # Matrix generator for multi-env
```

---

## Atlantis Operations

Atlantis automates Terraform/OpenTofu plan/apply on PRs.

### Webhook Setup

```bash
# Test webhook connectivity
make atlantis-webhook

# Trigger plan on PR (requires gh CLI + GITHUB_PAT)
make atlantis-plan PR_NUMBER=123

# Trigger apply on PR (requires gh CLI + GITHUB_PAT)
make atlantis-apply PR_NUMBER=123
```

### Configuration

- Server config: `atlantis.yaml.tftpl` (templated by OpenTofu)
- Runs in minikube via Helm chart
- Uses cloudflared tunnel for GitHub webhook (no ngrok needed)
- OpenTofu 1.7.0 (not Terraform)

---

## Promotion Workflows

Services are promoted across environments: **dev → staging → prod**

```bash
# Promote to staging
make promote ENV=staging SERVICE=go-service

# Promote to prod (requires approval)
make promote ENV=prod SERVICE=go-service

# Verify promotion health
make promote-verify
```

### Promotion Process

1. **GitHub Actions workflow** (`.github/workflows/promote.yaml`) with `workflow_dispatch`
2. **Manual approval gates** for staging → prod
3. **ArgoCD ApplicationSet** updates target revision
4. **Verification script** checks health post-promotion
5. **Rollback** via ArgoCD UI or `argocd app rollback`

---

## Verification & Testing

### Phase Gates

```bash
# Phase 1: Infrastructure verification
make verify

# Service health check
make verify-services

# Smoke tests
make smoke-test

# Load test (requires k6)
make load-test
```

### Health Checks

```bash
# Comprehensive health check
make doctor

# Verify toolchain
make toolchain-verify
```

---

## Cross-Platform Notes

### macOS (Docker Desktop)

| Issue | Solution |
|-------|----------|
| Docker Desktop memory limit | Increase to ≥8GB in Settings → Resources |
| minikube IP not accessible | Use `kubectl port-forward` (not `minikube tunnel`) |
| BSD Make 3.81 | Use `mise exec -- make` or activate mise in shell |
| Port conflicts | Override ports via env vars (e.g., `ARGOCD_PORT=8082`) |

```bash
# Fix memory limit issue
make fix-macos-docker-memory
```

### Linux (KVM/libvirt)

```bash
# Fix KVM permissions
make fix-linux-kvm
# Then log out and back in
```

### Port Conflicts

All ports are overridable via environment variables or `.env` file:

```bash
# Override specific ports
ARGOCD_PORT=8082 GRAFANA_PORT=3001 make port-forwards

# Or create .env file
cat > .env <<EOF
ARGOCD_PORT=8082
GRAFANA_PORT=3001
VAULT_PORT=8201
EOF
```

---

## Troubleshooting

### Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `make: *** missing separator` | BSD Make 3.81 on macOS | Use `mise exec -- make` or activate mise |
| `minikube tunnel` fails | NodePort service, not LoadBalancer | Use `make port-forward-ingress` |
| `registry-proxy` ImagePullBackOff | minikube registry addon broken | Don't enable it; use Helm registry from `tofu/modules/registry/` |
| `tofu validate` fails on `type` arg | OpenTofu 1.7 doesn't support `type` on outputs | Remove `type = ...` from output blocks |
| ArgoCD apps stuck `Progressing` | Health checks failing | Check pod logs, verify readiness probes |
| Atlantis plan fails | Webhook not configured | Run `make atlantis-webhook` to debug |

### Runbooks

- [Cluster Reset](docs/runbooks/cluster-reset.md)
- [ArgoCD Out-of-Sync](docs/runbooks/argocd-out-of-sync.md)
- [Atlantis Webhook Debug](docs/runbooks/atlantis-webhook-debug.md)
- [Vault & Secrets](docs/runbooks/vault-secrets.md)
- [Secrets Management](docs/runbooks/secrets-management.md)
- [Backup & Restore](docs/runbooks/backup-restore.md)
- [Disaster Recovery](docs/runbooks/disaster-recovery.md)

### Health Check

```bash
# Run comprehensive health check
make doctor
```

---

## Learning Path

This platform is designed for **learning by doing**. Follow this progression:

### Phase 1: Infrastructure Foundation (Week 1-2)

```bash
# 1. Complete setup
make dev-setup

# 2. Explore infrastructure
make cluster-status
make service-status
make port-forwards

# 3. Access UIs
# ArcoCD: http://localhost:8081
# Grafana: http://localhost:3000
# Prometheus: http://localhost:9090
# Vault: http://localhost:8200
# Ministack: http://localhost:4566
# Atlantis: http://localhost:8080

# 4. Verify
make verify
```

**Learn:** OpenTofu modules, ArcoCD App-of-Apps, Vault + ESO, Ministack, Prometheus stack

### Phase 2: Service Deployment & GitOps (Week 2-3)

```bash
# 1. Clone service repos
make clone-services

# 2. Deploy services via ArgoCD
make deploy-services
make service-status

# 3. Test Go service
make port-forward-ingress
# In another terminal:
curl -X POST http://localhost:8080/api/v1/orders \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"test","items":[{"name":"item1","qty":1}],"total_amount":10.00}'

# 4. Check SQS message in Ministack
awslocal sqs receive-message --queue-url http://localhost:4566/000000000000/order-events
```

**Learn:** ArgoCD sync, health checks, service-to-service via SQS, OpenTelemetry

### Phase 3: Cross-Service Integration (Week 3-4)

```bash
# 1. Deploy Node service (consumes Go service events)
make deploy-service-node

# 2. Create order → watch Node service process it
# Check Node service logs
make service-logs SERVICE=node-service NAMESPACE=dev

# 3. Test WebSocket real-time updates
# Open frontend or use wscat
```

**Learn:** Event-driven architecture, SQS consumers, WebSocket, Redis pub/sub

### Phase 4: Frontend & Observability (Week 4-5)

```bash
# 1. Deploy frontend
make deploy-service-frontend

# 2. Access dashboard
make port-forward-ingress
# Open http://localhost:8080

# 3. Explore Grafana dashboards
make port-forward-grafana
# Open http://localhost:3000
# Dashboards: Platform Overview, Golden Signals, SLO
```

**Learn:** Next.js + TanStack Query, WebSocket real-time, Grafana embedding

### Phase 5: Production Workflows (Week 5-6)

```bash
# 1. Promote to staging
make promote ENV=staging SERVICE=go-service
make promote-verify

# 2. Promote to prod (with approval)
make promote ENV=prod SERVICE=go-service

# 3. Test rollback
# In ArgoCD UI: Actions → Rollback

# 4. Chaos engineering
make chaos-pod-kill TARGET=go-service
make chaos-cpu
make chaos-network

# 5. Load testing
make load-test
```

**Learn:** Multi-environment promotion, rollback, chaos engineering, load testing

---

## Architecture

The design this repo implements:
- [`docs/specs/2026-09-23-platform-learning-ecosystem-design.md`](docs/specs/2026-09-23-platform-learning-ecosystem-design.md)
- Plan: [`docs/plans/2026-09-26-phase1-infrastructure-foundation.md`](docs/plans/2026-09-26-phase1-infrastructure-foundation.md)

### Architecture Decision Records (ADRs)

| ADR | Decision |
|-----|----------|
| [0001](docs/adr/0001-record-architecture-decisions.md) | Record architecture decisions |
| [0002](docs/adr/0002-single-minikube-cluster.md) | Single minikube cluster |
| [0003](docs/adr/0003-opentofu-over-terraform.md) | OpenTofu over Terraform |
| [0004](docs/adr/0004-ministack-over-localstack.md) | Ministack over LocalStack |
| [0005](docs/adr/0005-argocd-applicationset-matrix-generator.md) | ArcoCD ApplicationSet with matrix generator |
| [0006](docs/adr/0006-helm-environment-specific-values.md) | Helm environment-specific values files |
| [0007](docs/adr/0007-github-actions-promotion-workflow.md) | GitHub Actions promotion workflow |
| [0008](docs/adr/0008-production-hardening-standards.md) | Production hardening standards |

---

## Repository Layout

```
platform-infra/
├── .github/workflows/          # CI/CD pipelines
├── argocd/                     # ArgoCD Application definitions
│   ├── applications/           # Per-service, per-environment Apps
│   ├── applicationset/         # ApplicationSet matrix generator
│   └── projects/               # AppProjects (dev/staging/prod isolation)
├── chaos/                      # LitmusChaos experiments
├── dashboards/                 # Grafana dashboard JSON
├── docs/
│   ├── adr/                    # Architecture Decision Records
│   ├── plans/                  # Implementation plans
│   ├── runbooks/               # Operational runbooks
│   └── specs/                  # Design specifications
├── helm/values/                # Helm values files
├── kubernetes/platform-system/ # Kustomize base for platform components
├── scripts/                    # Operational scripts
├── tofu/                       # OpenTofu root module
│   ├── modules/                # Reusable modules
│   └── environments/local/     # Local environment overrides
├── Makefile                    # This file - all commands
├── README.md                   # This file
└── .tool-versions              # Pinned tool versions
```

---

## Make Targets Reference

### Setup & Toolchain
| Target | Description |
|--------|-------------|
| `toolchain-install` | Install all pinned tools via mise |
| `toolchain-verify` | Verify tool versions |
| `toolchain-update` | Update tools to latest |

### Cluster
| Target | Description |
|--------|-------------|
| `cluster-up` | Create/start minikube cluster |
| `cluster-down` | Delete cluster |
| `cluster-reset` | Full reset |
| `cluster-status` | Show cluster health |
| `cluster-logs` | View minikube logs |
| `cluster-shell` | SSH to node |
| `cluster-ip` | Get cluster IP |

### Infrastructure
| Target | Description |
|--------|-------------|
| `deploy-infra` | Apply all infrastructure |
| `deploy-infra-plan` | Show plan |
| `deploy-infra-target` | Apply specific module |
| `destroy-infra` | Destroy all |
| `tofu-fmt` | Format & validate |
| `tofu-outputs` | Show outputs |

### Services
| Target | Description |
|--------|-------------|
| `deploy-services` | Deploy all services via ArgoCD |
| `deploy-service-go` | Deploy Go service |
| `deploy-service-node` | Deploy Node service |
| `deploy-service-frontend` | Deploy Frontend |
| `service-status` | Show all service status |
| `service-logs` | View service logs |

### Port Forwarding
| Target | Description |
|--------|-------------|
| `port-forwards` | Forward all services |
| `port-forward-argocd` | ArcoCD UI |
| `port-forward-grafana` | Grafana |
| `port-forward-prometheus` | Prometheus |
| `port-forward-vault` | Vault |
| `port-forward-ministack` | Ministack |
| `port-forward-registry` | Registry |
| `port-forward-atlantis` | Atlantis |
| `port-forward-ingress` | Ingress (nginx) |

### Credentials
| Target | Description |
|--------|-------------|
| `argocd-password` | Get ArgoCD admin password |
| `vault-token` | Get Vault root token |
| `registry-login` | Configure docker for local registry |

### Verification
| Target | Description |
|--------|-------------|
| `verify` | Phase 1 gate |
| `verify-services` | Service health |
| `smoke-test` | Smoke tests |
| `load-test` | k6 load test |
| `doctor` | Comprehensive health check |

### Development
| Target | Description |
|--------|-------------|
| `dev-setup` | Complete local setup |
| `dev-teardown` | Complete teardown |
| `dev-restart` | Quick restart |
| `clone-services` | Clone service repos |
| `service-dev-go` | Run Go service locally |
| `service-dev-node` | Run Node service locally |
| `service-dev-frontend` | Run Frontend locally |

### Local Build & Push
| Target | Description |
|--------|-------------|
| `local-build-go` | Build Go image |
| `local-push-go` | Push Go image to local registry |
| `local-build-node` | Build Node image |
| `local-push-node` | Push Node image |
| `local-build-frontend` | Build Frontend image |
| `local-push-frontend` | Push Frontend image |

### ArgoCD
| Target | Description |
|--------|-------------|
| `argocd-sync` | Sync all apps |
| `argocd-sync-app` | Sync specific app |
| `argocd-login` | Login to CLI |
| `argocd-apps` | List apps |

### Atlantis
| Target | Description |
|--------|-------------|
| `atlantis-webhook` | Test webhook |
| `atlantis-plan` | Trigger plan |
| `atlantis-apply` | Trigger apply |

### Promotion
| Target | Description |
|--------|-------------|
| `promote` | Promote service |
| `promote-verify` | Verify promotion |

### Chaos
| Target | Description |
|--------|-------------|
| `chaos-pod-kill` | Pod kill experiment |
| `chaos-cpu` | CPU stress |
| `chaos-network` | Network latency |

### Backup
| Target | Description |
|--------|-------------|
| `backup-all` | Backup all data |
| `restore-all` | Restore all data |

### Platform Fixes
| Target | Description |
|--------|-------------|
| `fix-macos-docker-memory` | Fix Docker Desktop memory (macOS) |
| `fix-linux-kvm` | Fix KVM permissions (Linux) |

### Cleanup
| Target | Description |
|--------|-------------|
| `clean` | Clean local artifacts |
| `clean-all` | Cluster down + clean |

---

## Contributing

1. All infrastructure changes via OpenTofu (`tofu/` directory)
2. Service manifests managed by ArgoCD (in service repos)
3. Run `make fmt` before committing (formats OpenTofu, validates overrides)
4. Follow ADR process for architectural decisions

---

## License

Internal learning project - not for production use.