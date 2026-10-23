# Service Development Guide

Complete local development guides for each platform service. Each service is in its own GitHub repository and designed for independent development with docker-compose.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [platform-services-go (Orders API)](#platform-services-go-orders-api)
4. [platform-services-node (Notifications API)](#platform-services-node-notifications-api)
5. [platform-frontend (Dashboard)](#platform-frontend-dashboard)
6. [Cross-Service Integration](#cross-service-integration)
7. [Building & Pushing Images](#building--pushing-images)
8. [Testing](#testing)

---

## Overview

| Service | Repository | Language | Framework | Port |
|---------|------------|----------|-----------|------|
| Orders API | `platform-services-go` | Go 1.22 | Gin | 8080 |
| Notifications API | `platform-services-node` | Node.js 20 | Fastify + TS | 3000 |
| Dashboard | `platform-frontend` | TypeScript/React | Next.js 14 | 3000 |

All services share local dependencies:
- **PostgreSQL** (port 5432)
- **Ministack** (port 4566) - AWS SQS/S3/DynamoDB
- **Redis** (port 6379) - Node service only

---

## Prerequisites

```bash
# From platform-infra root
make clone-services

# Or manually:
git clone https://github.com/romeufcrosa/platform-services-go.git
git clone https://github.com/romeufcrosa/platform-services-node.git
git clone https://github.com/romeufcrosa/platform-frontend.git
```

Each service has its own `.tool-versions` and `Makefile` with standard targets:
- `dev` - Start local development stack
- `build` - Build Docker image
- `test` - Run tests
- `lint` - Run linters
- `push` - Push to registry

---

## platform-services-go (Orders API)

### Repository Structure

```
platform-services-go/
├── cmd/server/main.go           # Entry point
├── internal/
│   ├── config/                  # Viper config (env + YAML)
│   ├── domain/
│   │   ├── order/               # Order entity + repository
│   │   └── event/               # Event publishing (SQS)
│   ├── infrastructure/
│   │   ├── postgres/            # pgx + migrations
│   │   ├── sqs/                 # AWS SDK v2 SQS client
│   │   └── otel/                # OpenTelemetry setup
│   └── interfaces/http/         # Gin handlers + routes
├── migrations/                  # SQL migrations (golang-migrate)
├── Dockerfile                   # Multi-stage (build → distroless)
├── docker-compose.yml           # Local dev stack
├── go.mod / go.sum
├── Makefile
└── .tool-versions
```

### Local Development

```bash
cd ../platform-services-go

# Start full dev stack (postgres + ministack + service with hot reload)
make dev

# In another terminal, run tests
make test

# Run linter
make lint

# Build Docker image
make build
```

### docker-compose.yml Services

| Service | Port | Description |
|---------|------|-------------|
| postgres | 5432 | PostgreSQL 16 (orders schema) |
| ministack | 4566 | AWS SQS/S3/DynamoDB local |
| app | 8080 | Go service (hot reload via air) |

### Environment Variables

```bash
# .env (auto-loaded by Viper)
SERVER_PORT=8080
DATABASE_URL=postgres://postgres:postgres@localhost:5432/orders?sslmode=disable
SQS_ENDPOINT=http://localhost:4566
SQS_QUEUE_URL=http://localhost:4566/000000000000/order-events
AWS_REGION=us-east-1
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
LOG_LEVEL=debug
```

### API Endpoints

```bash
# Health checks
curl http://localhost:8080/health      # Liveness
curl http://localhost:8080/ready       # Readiness (DB + SQS)

# Orders
curl -X POST http://localhost:8080/api/v1/orders \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"cust-123","items":[{"name":"Widget","quantity":2,"price":25.00}],"total_amount":50.00}'

curl http://localhost:8080/api/v1/orders/{id}
curl http://localhost:8080/api/v1/orders?page=1&limit=20
```

### Database Access

```bash
# Connect to postgres
docker exec -it platform-services-go-postgres-1 psql -U postgres -d orders

# Or from host
psql "postgres://postgres:postgres@localhost:5432/orders?sslmode=disable"
```

### SQS Inspection

```bash
# List queues
awslocal sqs list-queues --endpoint-url http://localhost:4566

# Receive messages
awslocal sqs receive-message --queue-url http://localhost:4566/000000000000/order-events
```

### Running in Kubernetes (minikube)

```bash
# From platform-infra
make deploy-service-go

# Check status
kubectl --context platform -n dev get pods -l app.kubernetes.io/name=go-service

# View logs
kubectl --context platform -n dev logs -l app.kubernetes.io/name=go-service -f

# Port-forward to access
kubectl --context platform -n dev port-forward svc/go-service 8080:80
curl http://localhost:8080/health
```

---

## platform-services-node (Notifications API)

### Repository Structure

```
platform-services-node/
├── src/
│   ├── main.ts                  # Entry point (Fastify)
│   ├── config/                  # Zod-validated config
│   ├── modules/
│   │   ├── orders/              # SQS consumer (order.created)
│   │   ├── notifications/       # CRUD + WebSocket
│   │   └── health/              # Health/readiness endpoints
│   ├── infrastructure/
│   │   ├── database/            # Kysely + pg (type-safe SQL)
│   │   ├── redis/               # ioredis (cache + pub/sub)
│   │   ├── sqs/                 # AWS SDK v3 SQS consumer
│   │   └── otel/                # OpenTelemetry auto-instrumentation
│   └── shared/                  # Shared types, utilities
├── migrations/                  # SQL migrations
├── Dockerfile                   # Multi-stage (build → distroless)
├── docker-compose.yml           # Local dev stack
├── package.json / tsconfig.json
├── Makefile
└── .tool-versions
```

### Local Development

```bash
cd ../platform-services-node

# Start full dev stack (postgres + redis + ministack + service with hot reload)
make dev

# In another terminal
make test
make lint
make build
```

### docker-compose.yml Services

| Service | Port | Description |
|---------|------|-------------|
| postgres | 5432 | PostgreSQL 16 (notifications schema) |
| redis | 6379 | Redis 7 (cache + pub/sub) |
| ministack | 4566 | AWS SQS/S3/DynamoDB local |
| app | 3000 | Node service (hot reload via tsx watch) |

### Environment Variables

```bash
# .env
SERVER_PORT=3000
DATABASE_URL=postgres://postgres:postgres@localhost:5432/notifications?sslmode=disable
REDIS_URL=redis://localhost:6379
SQS_ENDPOINT=http://localhost:4566
SQS_QUEUE_URL=http://localhost:4566/000000000000/order-events
AWS_REGION=us-east-1
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
LOG_LEVEL=debug
```

### API Endpoints

```bash
# Health checks
curl http://localhost:3000/health      # Liveness
curl http://localhost:3000/ready       # Readiness (DB + Redis + SQS)

# Notifications
curl http://localhost:3000/api/v1/notifications/{orderId}
curl http://localhost:3000/api/v1/notifications?status=pending&limit=20

# WebSocket (real-time notifications)
# Connect: ws://localhost:3000/ws/notifications?orderId={orderId}
```

### WebSocket Test

```bash
# Install wscat
npm install -g wscat

# Connect to WebSocket
wscat -c "ws://localhost:3000/ws/notifications?orderId=<order-id>"

# You'll receive real-time notifications when orders are created
```

### Database Access

```bash
# Connect to postgres
docker exec -it platform-services-node-postgres-1 psql -U postgres -d notifications

# Or from host
psql "postgres://postgres:postgres@localhost:5432/notifications?sslmode=disable"
```

### Redis Inspection

```bash
# Connect to Redis
docker exec -it platform-services-node-redis-1 redis-cli

# Monitor pub/sub
redis-cli MONITOR
```

### SQS Consumer

The Node service polls the `order-events` queue and processes `order.created` messages:

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

On processing, it:
1. Creates in-app notification in PostgreSQL
2. Simulates email/push via async workers
3. Publishes to Redis pub/sub for WebSocket broadcast
4. Updates notification status

### Running in Kubernetes (minikube)

```bash
# From platform-infra
make deploy-service-node

# Check status
kubectl --context platform -n dev get pods -l app.kubernetes.io/name=node-service

# View logs
kubectl --context platform -n dev logs -l app.kubernetes.io/name=node-service -f

# Port-forward
kubectl --context platform -n dev port-forward svc/node-service 3000:80
curl http://localhost:3000/health
```

---

## platform-frontend (Dashboard)

### Repository Structure

```
platform-frontend/
├── src/
│   ├── app/                      # Next.js App Router
│   │   ├── (dashboard)/          # Dashboard layout group
│   │   │   ├── page.tsx          # Platform overview
│   │   │   ├── services/
│   │   │   │   ├── go/page.tsx   # Go service: orders + events
│   │   │   │   └── node/page.tsx # Node service: notifications
│   │   │   ├── infrastructure/   # ArgoCD, Atlantis, Terraform
│   │   │   ├── observability/    # Grafana embed + custom panels
│   │   │   └── deployments/      # Deployment history
│   │   ├── api/                  # API routes (if needed)
│   │   └── layout.tsx
│   ├── components/
│   │   ├── ui/                   # shadcn/ui components
│   │   ├── charts/               # Recharts visualizations
│   │   └── websocket/            # WebSocket hooks
│   ├── lib/
│   │   ├── api/                  # TanStack Query hooks
│   │   ├── auth/                 # NextAuth.js (GitHub OAuth)
│   │   └── ws/                   # WebSocket client
│   └── styles/
├── public/
├── Dockerfile                    # Multi-stage (standalone output)
├── next.config.js
├── tailwind.config.ts
├── package.json
├── Makefile
└── .tool-versions
```

### Local Development

```bash
cd ../platform-frontend

# Start Next.js dev server (hot reload)
make dev

# In another terminal
make test
make lint
make build
```

### Environment Variables

```bash
# .env.local
NEXT_PUBLIC_API_GO=http://localhost:8080/api/v1
NEXT_PUBLIC_API_NODE=http://localhost:3000/api/v1
NEXT_PUBLIC_WS_GO=ws://localhost:8080/ws
NEXT_PUBLIC_WS_NODE=ws://localhost:3000/ws
NEXTAUTH_SECRET=your-secret-here
NEXTAUTH_URL=http://localhost:3000
GITHUB_ID=your-github-oauth-id
GITHUB_SECRET=your-github-oauth-secret
```

### Pages & Features

| Route | Description |
|-------|-------------|
| `/` | Platform overview - cluster health, deploy status, key metrics |
| `/services/go` | Go service: order list, create order form, event stream |
| `/services/node` | Node service: notifications, processing status, WebSocket |
| `/infrastructure` | ArgoCD apps, Atlantis PRs, Terraform state |
| `/observability` | Grafana iframe embed + custom metrics panels |
| `/deployments` | Deployment history, rollback triggers |

### WebSocket Connections

The frontend maintains two WebSocket connections:
- `ws://localhost:8080/ws/orders` - Real-time order events from Go service
- `ws://localhost:3000/ws/notifications` - Real-time notifications from Node service

### Running in Kubernetes (minikube)

```bash
# From platform-infra
make deploy-service-frontend

# Check status
kubectl --context platform -n dev get pods -l app.kubernetes.io/name=frontend

# Port-forward
kubectl --context platform -n dev port-forward svc/frontend 3000:80
# Open http://localhost:3000
```

---

## Cross-Service Integration

### Full Local Integration Test

```bash
# Terminal 1: Start all services locally
cd ../platform-services-go && make dev &
cd ../platform-services-node && make dev &
cd ../platform-frontend && make dev &

# Terminal 2: Create order via Go API
curl -X POST http://localhost:8080/api/v1/orders \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"test","items":[{"name":"Test Item","quantity":1,"price":10.00}],"total_amount":10.00}'

# Terminal 3: Watch Node service process it
# Check Node logs for "Processing order.created event"

# Terminal 4: Open frontend
# http://localhost:3000/services/go - see new order
# http://localhost:3000/services/node - see notification via WebSocket
```

### Event Flow

```
1. POST /api/v1/orders (Go service)
       │
       ▼
2. Save to PostgreSQL (orders schema)
       │
       ▼
3. Publish to SQS (order-events queue)
       │
       ▼
4. Node service polls SQS (long polling, 20s wait)
       │
       ▼
5. Process order.created → create notification
       │
       ├──▶ Save to PostgreSQL (notifications schema)
       ├──▶ Publish to Redis pub/sub
       └──▶ Broadcast via WebSocket
       │
       ▼
6. Frontend receives via WebSocket → updates UI
```

### Ministack Queue Verification

```bash
# Check queue depth
awslocal sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/order-events \
  --attribute-names ApproximateNumberOfMessages

# Purge queue for clean test
awslocal sqs purge-queue \
  --queue-url http://localhost:4566/000000000000/order-events
```

---

## Building & Pushing Images

### Local Registry Setup

```bash
# From platform-infra (after make deploy-infra)
make port-forward-registry

# Get registry ClusterIP
REGISTRY_IP=$(kubectl --context platform -n registry get svc registry -o jsonpath='{.spec.clusterIP}')
echo "$REGISTRY_IP registry.registry.svc" | sudo tee -a /etc/hosts
```

### Build & Push Each Service

```bash
# Go service
cd ../platform-services-go
make build
# Tag for local registry
docker tag platform-services-go:latest $REGISTRY_IP:5000/platform-services-go:local-$(date +%s)
docker push $REGISTRY_IP:5000/platform-services-go:local-$(date +%s)

# Node service
cd ../platform-services-node
make build
docker tag platform-services-node:latest $REGISTRY_IP:5000/platform-services-node:local-$(date +%s)
docker push $REGISTRY_IP:5000/platform-services-node:local-$(date +%s)

# Frontend
cd ../platform-frontend
make build
docker tag platform-frontend:latest $REGISTRY_IP:5000/platform-frontend:local-$(date +%s)
docker push $REGISTRY_IP:5000/platform-frontend:local-$(date +%s)
```

### Or Use Make Targets (from platform-infra)

```bash
make local-build-go local-push-go
make local-build-node local-push-node
make local-build-frontend local-push-frontend
```

### Update ArgoCD to Use Local Images

```bash
# Patch ArgoCD application to use local image tag
kubectl --context platform -n argocd patch application go-service-dev \
  --type merge -p '{"spec":{"source":{"helm":{"parameters":[{"name":"image.tag","value":"local-<timestamp>"}]}}}}'
```

---

## Testing

### Unit Tests

```bash
# Go service
cd ../platform-services-go && make test

# Node service
cd ../platform-services-node && make test

# Frontend
cd ../platform-frontend && make test
```

### Integration Tests

```bash
# Go service (Testcontainers)
cd ../platform-services-go && make test-integration

# Node service (Testcontainers)
cd ../platform-services-node && make test-integration

# Frontend (Playwright)
cd ../platform-frontend && make test-e2e
```

### Contract Tests

```bash
# Verify OpenAPI contracts between services
cd ../platform-services-go && make test-contract
cd ../platform-services-node && make test-contract
```

### Load Testing

```bash
# From platform-infra (requires k6)
make load-test

# Or directly
k6 run tests/load-test.js
```

---

## Troubleshooting

### Port Conflicts

```bash
# Check what's using a port
lsof -i :8080
lsof -i :3000
lsof -i :5432

# Kill process
kill -9 <PID>
```

### Database Connection Issues

```bash
# Reset local databases
cd ../platform-services-go && docker-compose down -v && make dev
cd ../platform-services-node && docker-compose down -v && make dev
```

### Ministack Not Ready

```bash
# Check Ministack health
curl http://localhost:4566/_localstack/health

# Restart Ministack
docker-compose restart ministack
```

### Hot Reload Not Working

```bash
# Go: Ensure air is installed and watching
# Node: Ensure tsx watch is running
# Frontend: Next.js dev server auto-reloads

# Check file watching limits (Linux)
echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

## Quick Reference

| Task | Go Service | Node Service | Frontend |
|------|------------|--------------|----------|
| Start dev | `make dev` | `make dev` | `make dev` |
| Run tests | `make test` | `make test` | `make test` |
| Lint | `make lint` | `make lint` | `make lint` |
| Build image | `make build` | `make build` | `make build` |
| API port | 8080 | 3000 | 3000 |
| Health | `/health` | `/health` | N/A |
| Ready | `/ready` | `/ready` | N/A |
| WebSocket | N/A | `/ws/notifications` | Connects to both |
| DB | postgres:5432 (orders) | postgres:5432 (notifications) | N/A |
| Cache | N/A | redis:6379 | N/A |
| SQS | ministack:4566 | ministack:4566 | N/A |