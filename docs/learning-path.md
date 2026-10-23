# Learning Path: Platform Engineering with GitOps

A step-by-step guide to simulating realistic development scenarios using this platform learning ecosystem. Each phase builds on the previous one.

---

## Prerequisites

- Complete [Quick Start](README.md#quick-start) in platform-infra
- Read the [Architecture Design Spec](docs/specs/2026-09-23-platform-learning-ecosystem-design.md)
- Clone service repos: `make clone-services`

---

## Phase 1: Infrastructure Foundation (Week 1-2)

### Goal
Establish a production-like Kubernetes platform locally with all core components.

### Steps

#### 1.1 Bootstrap Everything
```bash
# Complete setup (toolchain + cluster + infra)
cd platform-infra
make dev-setup

# Verify
make verify
# Must print: PHASE 1 VERIFICATION PASSED
```

#### 1.2 Explore the Cluster
```bash
# Cluster overview
make cluster-status

# All namespaces
kubectl --context platform get ns

# System pods
kubectl --context platform get pods -n kube-system
kubectl --context platform get pods -n argocd
kubectl --context platform get pods -n monitoring
kubectl --context platform get pods -n vault
kubectl --context platform get pods -n ministack
kubectl --context platform get pods -n registry
```

#### 1.3 Access All UIs
```bash
# Start port forwards (keep running)
make port-forwards &

# Open in browser:
# ArgoCD:      http://localhost:8081  (admin / `make argocd-password`)
# Grafana:     http://localhost:3000  (admin / prom-operator)
# Prometheus:  http://localhost:9090
# Vault:       http://localhost:8200  (token: `make vault-token`)
# Ministack:   http://localhost:4566
# Atlantis:    http://localhost:8080
```

#### 1.4 Understand the Components

| Component | Purpose | Key Files |
|-----------|---------|-----------|
| **ArgoCD** | GitOps continuous delivery | `argocd/`, `tofu/modules/argocd/` |
| **Atlantis** | Terraform PR automation | `atlantis.yaml.tftpl`, `tofu/modules/atlantis/` |
| **Vault** | Secrets management | `tofu/modules/vault/`, `scripts/seed-vault.sh` |
| **External Secrets** | Vault → K8s secrets sync | `tofu/modules/external_secrets/` |
| **Ministack** | Local AWS APIs (SQS, S3, etc.) | `tofu/modules/ministack/`, `scripts/bootstrap-ministack-queues.sh` |
| **Prometheus Stack** | Observability | `tofu/modules/prometheus/`, `dashboards/` |
| **Registry** | Local Docker registry | `tofu/modules/registry/` |

#### 1.5 Test Atlantis Workflow
```bash
# Create a test PR with a Terraform change
cd platform-infra
git checkout -b test-atlantis
echo '# Test' >> tofu/environments/local/overrides.tf
git add tofu/environments/local/overrides.tf
git commit -m "test: trigger atlantis plan"
git push origin test-atlantis

# Create PR on GitHub, Atlantis will comment with plan
# Review plan → comment `/atlantis apply` to apply
```

#### 1.6 Test ArcoCD Sync
```bash
# Check ArgoCD applications
make argocd-apps

# Force sync all
make argocd-sync

# Check sync status in ArgoCD UI
```

### Learning Outcomes
- [ ] OpenTofu module structure and dependencies
- [ ] ArgoCD App-of-Apps pattern with ApplicationSet
- [ ] Vault + External Secrets Operator workflow
- [ ] Ministack as LocalStack alternative
- [ ] kube-prometheus-stack with custom dashboards
- [ ] Atlantis PR automation for Terraform

---

## Phase 2: Go Service - Orders API (Week 2-3)

### Goal
Deploy and operate a Go microservice with PostgreSQL, SQS publishing, and OpenTelemetry.

### Steps

#### 2.1 Local Development
```bash
cd ../platform-services-go

# Start local stack
make dev

# Test API
curl http://localhost:8080/health
curl http://localhost:8080/ready

# Create order
curl -X POST http://localhost:8080/api/v1/orders \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"learn-001","items":[{"name":"Learning Widget","quantity":1,"price":29.99}],"total_amount":29.99}'

# Verify in database
psql "postgres://postgres:postgres@localhost:5432/orders?sslmode=disable" -c "SELECT * FROM orders;"

# Check SQS message
awslocal sqs receive-message --queue-url http://localhost:4566/000000000000/order-events
```

#### 2.2 Deploy to Kubernetes
```bash
cd ../platform-infra
make deploy-service-go

# Watch deployment
kubectl --context platform -n dev get pods -l app.kubernetes.io/name=go-service -w

# Check ArcoCD sync
make argocd-sync-app APP=go-service-dev
```

#### 2.3 Test in Cluster
```bash
# Port-forward service
kubectl --context platform -n dev port-forward svc/go-service 8080:80

# Test
curl http://localhost:8080/health
curl -X POST http://localhost:8080/api/v1/orders \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"cluster-001","items":[{"name":"Cluster Widget","quantity":2,"price":15.00}],"total_amount":30.00}'

# Verify in cluster PostgreSQL
kubectl --context platform -n dev exec -it postgresql-0 -- psql -U postgres -d orders -c "SELECT * FROM orders;"

# Check SQS in Ministack
awslocal sqs receive-message --queue-url http://localhost:4566/000000000000/order-events
```

#### 2.4 Observe Metrics
```bash
# Prometheus metrics
curl http://localhost:9090/api/v1/query?query=go_service_orders_created_total

# Grafana dashboard
# Open http://localhost:3000 → Dashboards → Go Service Golden Signals
```

#### 2.5 Test HPA (Horizontal Pod Autoscaler)
```bash
# Generate load
hey -n 1000 -c 10 http://localhost:8080/api/v1/orders \
  -m POST -H "Content-Type: application/json" \
  -d '{"customer_id":"load","items":[{"name":"item","quantity":1,"price":10}],"total_amount":10}'

# Watch HPA scale
kubectl --context platform -n dev get hpa go-service -w
```

### Learning Outcomes
- [ ] Go service with Gin, pgx, AWS SDK v2
- [ ] PostgreSQL migrations with golang-migrate
- [ ] SQS event publishing (CloudEvents format)
- [ ] OpenTelemetry instrumentation
- [ ] Distroless Docker multi-stage build
- [ ] Helm chart with HPA, PgBouncer sidecar
- [ ] ArcoCD health checks for Go services

---

## Phase 3: Node.js Service - Notifications (Week 3-4)

### Goal
Deploy a Node.js service that consumes SQS events, provides WebSocket API, and uses Redis.

### Steps

#### 3.1 Local Development
```bash
cd ../platform-services-node

# Start local stack
make dev

# Test API
curl http://localhost:3000/health
curl http://localhost:3000/ready

# Test WebSocket
wscat -c "ws://localhost:3000/ws/notifications?orderId=test-123"
# Keep connection open
```

#### 3.2 Deploy to Kubernetes
```bash
cd ../platform-infra
make deploy-service-node

# Watch deployment
kubectl --context platform -n dev get pods -l app.kubernetes.io/name=node-service -w
```

#### 3.3 End-to-End Integration Test
```bash
# Terminal 1: Port-forward Go service
kubectl --context platform -n dev port-forward svc/go-service 8080:80

# Terminal 2: Port-forward Node service
kubectl --context platform -n dev port-forward svc/node-service 3000:80

# Terminal 3: Connect WebSocket to Node service
wscat -c "ws://localhost:3000/ws/notifications?orderId=integration-test"

# Terminal 4: Create order via Go service
curl -X POST http://localhost:8080/api/v1/orders \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"integration","items":[{"name":"Integration Widget","quantity":1,"price":99.99}],"total_amount":99.99}'

# Observe:
# 1. Go service saves order → publishes to SQS
# 2. Node service consumes SQS → creates notification
# 3. WebSocket receives real-time notification
# 4. Check Node service logs
kubectl --context platform -n dev logs -l app.kubernetes.io/name=node-service -f
```

#### 3.4 Verify Data Flow
```bash
# Check order in Go service DB
kubectl --context platform -n dev exec -it postgresql-0 -- psql -U postgres -d orders -c "SELECT * FROM orders;"

# Check notification in Node service DB
kubectl --context platform -n dev exec -it postgresql-0 -- psql -U postgres -d notifications -c "SELECT * FROM notifications;"

# Check Redis pub/sub
kubectl --context platform -n dev exec -it redis-0 -- redis-cli MONITOR
```

#### 3.5 Test Redis Caching
```bash
# First request (cache miss)
time curl http://localhost:3000/api/v1/notifications/integration-test

# Second request (cache hit - should be faster)
time curl http://localhost:3000/api/v1/notifications/integration-test

# Check Redis keys
kubectl --context platform -n dev exec -it redis-0 -- redis-cli KEYS "*"
```

### Learning Outcomes
- [ ] Fastify + TypeScript with Zod validation
- [ ] Kysely type-safe SQL queries
- [ ] SQS consumer with long polling
- [ ] WebSocket real-time communication
- [ ] Redis caching + pub/sub
- [ ] OpenTelemetry auto-instrumentation
- [ ] Distroless Node.js Docker build

---

## Phase 4: Frontend Dashboard (Week 4-5)

### Goal
Build a Next.js observability dashboard showing live data from all services.

### Steps

#### 4.1 Local Development
```bash
cd ../platform-frontend

# Start dev server
make dev

# Open http://localhost:3000
# Explore pages:
# - / (Platform overview)
# - /services/go (Orders + event stream)
# - /services/node (Notifications + WebSocket)
# - /infrastructure (ArgoCD, Atlantis, Terraform)
# - /observability (Grafana embed + custom panels)
# - /deployments (History + rollback)
```

#### 4.2 Connect to Cluster Services
```bash
# Port-forward all services
cd ../platform-infra
make port-forwards &

# Update frontend .env.local with cluster endpoints
cat > ../platform-frontend/.env.local <<EOF
NEXT_PUBLIC_API_GO=http://localhost:8080/api/v1
NEXT_PUBLIC_API_NODE=http://localhost:3000/api/v1
NEXT_PUBLIC_WS_GO=ws://localhost:8080/ws
NEXT_PUBLIC_WS_NODE=ws://localhost:3000/ws
NEXTAUTH_SECRET=dev-secret
NEXTAUTH_URL=http://localhost:3000
EOF

# Restart frontend dev server
cd ../platform-frontend && make dev
```

#### 4.3 Test Full Integration
```bash
# 1. Create order via dashboard UI (Services → Go)
# 2. Watch real-time event stream
# 3. Check notifications page for WebSocket updates
# 4. View infrastructure page for ArgoCD app status
# 5. Check observability page for Grafana embed
```

#### 4.4 Deploy to Kubernetes
```bash
cd ../platform-infra
make deploy-service-frontend

# Port-forward
kubectl --context platform -n dev port-forward svc/frontend 3000:80

# Access at http://localhost:3000
```

#### 4.4 Explore Grafana Integration
```bash
# Grafana iframe embed in frontend
# Check /observability page

# Direct Grafana access
make port-forward-grafana
# http://localhost:3000
# Dashboards: Platform Overview, Go Service Golden Signals, SLO Dashboard
```

### Learning Outcomes
- [ ] Next.js 14 App Router with TypeScript
- [ ] TanStack Query for server state
- [ ] WebSocket hooks for real-time updates
- [ ] shadcn/ui + Tailwind CSS
- [ ] NextAuth.js authentication
- [ ] Grafana iframe embedding
- [ ] Standalone Docker output for Next.js

---

## Phase 5: Production Workflows (Week 5-6)

### Goal
Master promotion, rollback, chaos engineering, and disaster recovery.

### Steps

#### 5.1 Environment Promotion
```bash
cd ../platform-infra

# Promote Go service to staging
make promote ENV=staging SERVICE=go-service

# Verify
make promote-verify

# Check ArgoCD UI for staging sync

# Promote to prod (requires approval in GitHub Actions)
make promote ENV=prod SERVICE=go-service
# Go to GitHub Actions → promote workflow → approve

# Verify production
make promote-verify
```

#### 5.2 Rollback Practice
```bash
# Via ArgoCD UI
# 1. Open ArgoCD: http://localhost:8081
# 2. Select go-service-prod application
# 3. Click "History" → "Rollback" to previous version

# Via CLI
argocd app rollback go-service-prod <revision>

# Verify rollback
make promote-verify
```

#### 5.2 Chaos Engineering
```bash
# Pod kill experiment
make chaos-pod-kill TARGET=go-service
# Observe: ArgoCD detects drift → auto-syncs (dev) or alerts (staging/prod)

# CPU stress
make chaos-cpu
# Observe: HPA scales up replicas

# Network latency
make chaos-network
# Observe: Increased latency in Grafana dashboards

# Clean up
kubectl --context platform delete -f chaos/
```

#### 5.3 Load Testing
```bash
# Run k6 load test
make load-test

# Or custom test
k6 run -vus=50 -duration=2m tests/load-test.js

# Check results in Grafana
# Dashboards → Go Service Golden Signals
```

#### 5.4 Backup & Restore
```bash
# Backup all critical data
make backup-all

# Simulate disaster
make cluster-reset

# Restore
make deploy-infra
make restore-all

# Verify data integrity
make verify
```

#### 5.5 Disaster Recovery Drill
```bash
# 1. Document current state
make tofu-outputs > /tmp/before-disaster.txt
kubectl --context platform get all -A > /tmp/k8s-before.txt

# 2. Destroy everything
make dev-teardown

# 3. Rebuild from scratch
make dev-setup

# 4. Verify recovery
make verify
diff /tmp/before-disaster.txt <(make tofu-outputs)
```

### Learning Outcomes
- [ ] Multi-environment promotion with approval gates
- [ ] ArcoCD rollback procedures
- [ ] Chaos engineering with LitmusChaos
- [ ] Load testing with k6
- [ ] Backup/restore procedures
- [ ] Disaster recovery RTO/RPO targets

---

## Advanced Scenarios

### Scenario 1: Secret Rotation
```bash
# 1. Rotate secret in Vault
kubectl --context platform -n vault exec -it vault-0 -- vault kv put secret/platform/go-service database-url="postgres://new:pass@postgres:5432/orders"

# 2. Watch ESO sync
kubectl --context platform -n dev get externalsecret go-service -w

# 3. Verify pod restart with new secret
kubectl --context platform -n dev get pods -l app.kubernetes.io/name=go-service -w
```

### Scenario 2: Terraform Change via Atlantis
```bash
# 1. Modify infrastructure (e.g., add resource)
cd platform-infra
git checkout -b tf-change
# Edit tofu/modules/ministack/main.tf
git add . && git commit -m "feat: add SQS dead letter queue"
git push origin tf-change

# 2. Create PR → Atlantis plans automatically
# 3. Review plan in PR comments
# 4. Comment `/atlantis apply`
# 4. Watch ArcoCD sync changes
```

### Scenario 3: Service Update Pipeline
```bash
# 1. Make code change in service repo
cd ../platform-services-go
# Modify internal/interfaces/http/order_handler.go
git add . && git commit -m "feat: add order validation"
git push origin main

# 2. GitHub Actions builds image → updates platform-infra manifests
# 3. ArgoCD detects manifest change → syncs dev namespace
# 4. Verify in ArgoCD UI and service logs
```

### Scenario 4: Multi-Service Feature
```bash
# 1. Add new event type in Go service
# 2. Update Node service consumer
# 3. Update frontend to display new event
# 4. Deploy all via ArcoCD
make deploy-services

# 5. Test end-to-end
```

---

## Learning Checklist

### Infrastructure (Phase 1)
- [ ] `make dev-setup` completes successfully
- [ ] `make verify` prints PASSED
- [ ] All UIs accessible via port-forwards
- [ ] Atlantis plan/apply works on test PR
- [ ] ArgoCD shows all platform-system apps Synced
- [ ] Grafana dashboards show data
- [ ] Vault unsealed, ESO syncing secrets

### Go Service (Phase 2)
- [ ] Local dev stack runs (`make dev`)
- [ ] Create order via API → stored in PostgreSQL
- [ ] SQS message visible in Ministack
- [ ] Service deployed to cluster via ArgoCD
- [ ] HPA scales under load
- [ ] Prometheus metrics exposed

### Node Service (Phase 3)
- [ ] Local dev stack runs
- [ ] WebSocket connects and receives events
- [ ] SQS consumer processes Go service events
- [ ] Notifications stored in PostgreSQL
- [ ] Redis caching works
- [ ] Deployed to cluster, integrates with Go service

### Frontend (Phase 4)
- [ ] Local dev server runs
- [ ] Dashboard shows live data from cluster services
- [ ] WebSocket real-time updates work
- [ ] Grafana iframe embeds correctly
- [ ] Deployed to cluster

### Production (Phase 5)
- [ ] Promotion dev→staging→prod works
- [ ] Rollback via ArcoCD UI works
- [ ] Chaos experiments run and self-heal
- [ ] Load test meets SLOs (p95<500ms, error<1%)
- [ ] Backup/restore completes
- [ ] Disaster recovery drill succeeds

---

## Resources

### Documentation
- [Architecture Design Spec](docs/specs/2026-09-23-platform-learning-ecosystem-design.md)
- [Phase 1 Plan](docs/plans/2026-09-26-phase1-infrastructure-foundation.md)
- [ADRs](docs/adr/)
- [Runbooks](docs/runbooks/)
- [Service Development Guide](docs/service-development-guide.md)

### External References
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Atlantis Documentation](https://www.runatlantis.io/docs/)
- [OpenTofu Documentation](https://opentofu.org/docs/)
- [Ministack Documentation](https://ministack.org/)
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [External Secrets Operator](https://external-secrets.io/)

### Tools Reference
```bash
# Kubernetes
kubectl --context platform --help
kubectl --context platform api-resources

# ArgoCD
argocd --help
argocd app --help

# Atlantis
atlantis --help

# Ministack / AWS
awslocal --help
awslocal sqs --help

# OpenTofu
tofu --help
tofu plan --help
```

---

## Next Steps

After completing all phases:

1. **Contribute back** - Add missing features, fix bugs, improve docs
2. **Extend the platform** - Add new services, databases, message queues
3. **Cloud deployment** - Adapt OpenTofu modules for AWS/GCP/Azure
4. **Team onboarding** - Use this as a training platform for new hires
5. **Customize** - Adapt to your organization's patterns and requirements

---

*This learning path is designed to be completed hands-on. Each phase assumes you've completed the previous ones. The platform is intentionally complex to mirror real-world platform engineering challenges.*