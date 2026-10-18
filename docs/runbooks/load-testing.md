# Load Testing Runbook

**Repository:** platform-infra  
**Last Updated:** 2026-01-15  
**Owner:** Platform Team

---

## Overview

This runbook covers executing k6 load tests for performance validation and regression detection.

### Test Suite
| Test | Target | Duration | RPS Profile | Purpose |
|------|--------|----------|-------------|---------|
| `go-service-load.js` | Orders API | 15 min | Ramp 10→100→10 | Service baseline |
| `node-service-load.js` | Notifications API + WS | 15 min | Ramp 5→50→5 | WebSocket + REST |
| `frontend-load.js` | Next.js Frontend | 20 min | Ramp 20→200→20 | Full page loads |
| `combined-load.js` | All services | 30 min | Realistic journey | End-to-end flow |

### Thresholds (Must Pass)
| Metric | Threshold | Failure Action |
|--------|-----------|----------------|
| `http_req_duration{p95}` | < 500ms | Block promotion |
| `http_req_failed` | < 1% | Block promotion |
| `ws_connecting` | < 100ms | Alert |
| `ws_messages_received` | > 95% sent | Alert |
| `checks` | 100% pass | Block promotion |

---

## Prerequisites

### Local Development
```bash
# Install k6
brew install k6  # macOS
# or: sudo apt install k6  # Ubuntu

# Verify
k6 version
```

### Required Environment Variables
```bash
export K6_API_BASE_URL=https://api.staging.example.com
export K6_FRONTEND_URL=https://staging.example.com
export K6_WS_URL=wss://api.staging.example.com/ws
export K6_VUS=50
export K6_DURATION=5m
```

---

## Running Tests

### Via GitHub Actions (CI/CD)
```bash
# Scheduled: Daily 03:00 UTC (staging)
# Manual trigger:
gh workflow run load-test.yaml \
  -f test_suite=combined \
  -f environment=staging \
  -f vus=100 \
  -f duration=15m

# View results
gh run list --workflow=load-test.yaml --limit=5
gh run view <run-id> --log
```

### Local Execution
```bash
# Single service test
k6 run tests/go-service-load.js \
  -e BASE_URL=https://api.staging.example.com \
  -e VUS=50 \
  -e DURATION=5m

# Combined journey test
k6 run tests/combined-load.js \
  -e API_BASE_URL=https://api.staging.example.com \
  -e FRONTEND_URL=https://staging.example.com \
  -e WS_URL=wss://api.staging.example.com/ws \
  -e VUS=30 \
  -e DURATION=10m

# With JSON output for CI
k6 run tests/go-service-load.js \
  --out json=results.json \
  --summary-export=summary.json
```

### Production Load Test (Careful!)
```bash
# REQUIRES: Explicit approval, maintenance window, on-call
# Use reduced load: 10% of production capacity

k6 run tests/combined-load.js \
  -e API_BASE_URL=https://api.example.com \
  -e FRONTEND_URL=https://example.com \
  -e WS_URL=wss://api.example.com/ws \
  -e VUS=20 \
  -e DURATION=5m \
  --tag environment=production
```

---

## Test Scripts Reference

### go-service-load.js
**Location:** `platform-infra/tests/go-service-load.js`

**Scenarios:**
1. **Create Order** - POST `/api/v1/orders` (20%)
2. **List Orders** - GET `/api/v1/orders` (50%)
3. **Get Order** - GET `/api/v1/orders/{id}` (30%)

**Stages:**
```javascript
export const options = {
  stages: [
    { duration: '2m', target: 10 },   // Warmup
    { duration: '5m', target: 50 },   // Ramp up
    { duration: '10m', target: 100 }, // Peak load
    { duration: '5m', target: 50 },   // Ramp down
    { duration: '2m', target: 0 },    // Cooldown
  ],
  thresholds: {
    'http_req_duration{type:create}': ['p(95)<500'],
    'http_req_duration{type:list}': ['p(95)<300'],
    'http_req_duration{type:get}': ['p(95)<200'],
    'http_req_failed': ['rate<0.01'],
    'checks': ['rate>0.99'],
  },
};
```

### node-service-load.js
**Location:** `platform-infra/tests/node-service-load.js`

**Scenarios:**
1. **REST Notifications** - GET/POST `/api/v1/notifications` (60%)
2. **WebSocket** - Connect, subscribe, receive (40%)

**WebSocket Metrics:**
- `ws_connecting` - Connection time
- `ws_session_duration` - Session length
- `ws_messages_sent` - Messages sent
- `ws_messages_received` - Messages received

### frontend-load.js
**Location:** `platform-infra/tests/frontend-load.js`

**Scenarios:**
1. **Page Loads** - `/`, `/dashboard`, `/orders`, `/notifications` (40%)
2. **API Calls** - Via frontend BFF (30%)
3. **Static Assets** - JS, CSS, images (20%)
4. **WebSocket** - Real-time updates (10%)

### combined-load.js
**Location:** `platform-infra/tests/combined-load.js`

**User Journey:**
```
1. User visits homepage (frontend)
2. User logs in (auth)
3. User creates order (go-service)
4. Order event → SQS → node-service
5. Notification appears via WebSocket (node-service)
6. User views order in dashboard (frontend)
7. User checks notifications (frontend)
```

---

## Interpreting Results

### k6 Summary Output
```
          /\      |‾‾| /‾‾/   /‾‾/
     /\  /  \     |  |/  /   /  /
    /  \/    \    |     /   /  /
   /          \   |  |  \  /  /
  /            \  |__|   \/__/

  execution: local
     script: go-service-load.js
     output: -

  scenarios: (100.00%) 1 scenario, 100 max VUs, 15m0s max duration
           * default: Up to 100 looping VUs for 15m0s over 5 stages

running (15m00.0s), 00/100 VUs, 12500 complete, 0 interrupted
✓ checks ........................................... 100.00%
✓ http_req_duration{p95} < 500ms ................. p(95)=245ms
✓ http_req_failed < 1% ........................... 0.00%
```

### Key Metrics to Review

| Metric | Good | Warning | Critical |
|--------|------|---------|----------|
| `http_req_duration` p95 | < 200ms | 200-500ms | > 500ms |
| `http_req_duration` p99 | < 500ms | 500-1000ms | > 1000ms |
| `http_req_failed` | < 0.1% | 0.1-1% | > 1% |
| `vus_max` | Reached target | < 80% target | < 50% target |
| `iterations` | Steady rate | Declining | Spikes |

### JSON Output Analysis
```bash
# Extract key metrics
cat summary.json | jq '.metrics'

# Check specific thresholds
cat summary.json | jq '.metrics.http_req_duration.values.p95'

# Compare with baseline
./scripts/compare-results.sh baseline.json summary.json
```

---

## CI/CD Integration

### GitHub Actions Workflow
**File:** `.github/workflows/load-test.yaml`

**Triggers:**
- Schedule: Daily 03:00 UTC (staging)
- Manual: `workflow_dispatch`
- On promotion: `workflow_run` (after promote to staging)

**Artifacts:**
- `k6-results.json` - Raw metrics
- `k6-summary.json` - Threshold results
- `k6-report.html` - HTML report

**Notifications:**
- Slack on failure: `#platform-alerts`
- Grafana Cloud: Push metrics for trending

### Promotion Gate
```yaml
# In promotion workflow
- name: Run Load Tests
  if: github.event.inputs.environment == 'production'
  run: |
    gh workflow run load-test.yaml \
      -f test_suite=combined \
      -f environment=staging \
      -f vus=100 \
      -f duration=15m
    # Wait and check results
    # Block promotion if thresholds fail
```

---

## Performance Baselines

### Current Baselines (Staging)
| Endpoint | p50 | p95 | p99 | Max RPS |
|----------|-----|-----|-----|---------|
| POST /orders | 45ms | 120ms | 280ms | 200 |
| GET /orders | 12ms | 35ms | 80ms | 500 |
| GET /orders/:id | 8ms | 22ms | 55ms | 800 |
| GET /notifications | 15ms | 40ms | 95ms | 400 |
| WS Connect | 25ms | 60ms | 120ms | 100 |
| Frontend /dashboard | 180ms | 450ms | 800ms | 100 |

### Baseline Updates
```bash
# Update baseline after confirmed improvement
cp summary.json baselines/go-service-baseline.json

# Commit with message
git add baselines/
git commit -m "perf: update go-service baseline after optimization"
```

---

## Troubleshooting

### Test Fails Thresholds

**High Latency (p95 > 500ms):**
```bash
# 1. Check if service is scaled
kubectl get hpa -n staging

# 2. Check resource limits
kubectl describe deployment go-service -n staging | grep -A5 Limits

# 3. Check database connections
kubectl exec -n database pgpool-0 -- pgpool -c "show pool_pools"

# 4. Profile application
# Go: pprof, Node: clinic.js
```

**High Error Rate (> 1%):**
```bash
# 1. Check error types
k6 run --out json=results.json tests/go-service-load.js
jq '.metrics.http_req_failed.values' results.json

# 2. Check application logs
kubectl logs -n staging deployment/go-service --since=10m | grep -i error

# 3. Check downstream dependencies
# - Database: connection pool exhaustion
# - SQS: throttling
# - Redis: connection limits
```

**WebSocket Failures:**
```bash
# 1. Check WS server logs
kubectl logs -n staging deployment/node-service --since=10m | grep -i websocket

# 2. Check connection limits
kubectl get pods -n staging -l app=node-service -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].resources.limits}{"\n"}{end}'

# 3. Verify sticky sessions / affinity
kubectl get svc node-service -n staging -o yaml | grep sessionAffinity
```

### Test Execution Issues

**k6 Cannot Connect:**
```bash
# Check DNS resolution
nslookup api.staging.example.com

# Check network policies
kubectl get networkpolicy -n staging

# Check ingress
kubectl get ingress -n staging
```

**Test Times Out:**
```bash
# Increase k6 timeout
k6 run --timeout=30m tests/combined-load.js

# Check for stuck VUs
# Look for "interrupted" in k6 output
```

---

## Reporting

### HTML Report Generation
```bash
# Generate HTML report from JSON
k6 run --out json=results.json tests/go-service-load.js
k6 report results.json --output report.html

# Open in browser
open report.html
```

### Grafana Dashboard
**Import:** `dashboards/k6-load-testing.json`

**Panels:**
- RPS over time
- Latency percentiles (p50, p95, p99)
- Error rate
- VU count
- Threshold pass/fail

### Trending
```bash
# Push to Grafana Cloud (configured in workflow)
# Query in Grafana:
# k6_http_req_duration_p95{test="go-service",env="staging"}
```

---

## Capacity Planning

### Scaling Decisions Based on Load Tests

| Observation | Action |
|-------------|--------|
| p95 < 200ms at 2x expected peak | Current capacity sufficient |
| p95 200-500ms at peak | Consider HPA maxReplicas increase |
| p95 > 500ms at peak | Investigate bottlenecks, optimize, or scale |
| Error rate > 0.1% at 50% peak | Urgent: fix before production |

### HPA Tuning from Load Test Data
```yaml
# From load test: at 100 RPS, avg CPU 45%, memory 60%
# Target: 70% CPU utilization
# Replicas needed at peak (200 RPS): 200/100 * 45/70 * current_replicas

# Update HPA
kubectl patch hpa go-service -n production -p '{"spec":{"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":70}}}]}}'
```

---

## Related Runbooks
- [Chaos Engineering](./chaos-engineering.md) - Resilience testing
- [Promotion](./promotion.md) - Load tests as promotion gate
- [ArgoCD Operations](./argocd-operations.md) - Post-load test sync verification

---

## Quick Reference

| Task | Command |
|------|---------|
| Run single test | `k6 run tests/go-service-load.js -e BASE_URL=...` |
| Run combined | `k6 run tests/combined-load.js -e API_BASE_URL=...` |
| JSON output | `k6 run --out json=results.json --summary-export=summary.json` |
| HTML report | `k6 report results.json --output report.html` |
| CI trigger | `gh workflow run load-test.yaml -f test_suite=combined` |
| View CI results | `gh run view <run-id> --log` |
| Compare baselines | `./scripts/compare-results.sh baseline.json summary.json` |