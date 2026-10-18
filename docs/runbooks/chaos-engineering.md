# Chaos Engineering Runbook

**Repository:** platform-infra  
**Last Updated:** 2026-01-15  
**Owner:** Platform Team

---

## Overview

This runbook covers executing and managing LitmusChaos experiments to validate system resilience.

### Experiment Catalog
| Experiment | Target | Duration | Purpose |
|------------|--------|----------|---------|
| `pod-kill-go-service` | go-service pods | 2 min | Verify HPA + ArgoCD self-heal |
| `pod-kill-node-service` | node-service pods | 2 min | Verify HPA + ArgoCD self-heal |
| `pod-kill-frontend` | frontend pods | 2 min | Verify HPA + ArgoCD self-heal |
| `network-latency` | All services | 5 min | Verify latency tolerance |
| `cpu-stress` | All services | 5 min | Verify CPU scaling + throttling |

### Steady State Definition
**System is healthy when:**
- All deployments: `readyReplicas == desiredReplicas`
- All pods: `Ready == True`, `RestartCount == 0`
- HPA: `currentReplicas` within `minReplicas`..`maxReplicas`
- ArgoCD: All apps `Synced` + `Healthy`
- Error rate: `< 1%` (5xx responses)
- Latency p99: `< 1000ms`

---

## Prerequisites

### Install LitmusChaos (One-time)
```bash
# Install LitmusChaos operator
kubectl apply -f https://litmuschaos.github.io/litmus/litmus-operator-v3.0.0.yaml

# Verify installation
kubectl get pods -n litmus
kubectl get crd | grep chaos
```

### Create Service Account for Experiments
```bash
# Already created via platform-infra GitOps
# Verify exists:
kubectl get sa litmus-admin -n litmus
kubectl get clusterrolebinding litmus-admin
```

---

## Running Experiments

### Via GitHub Actions (Recommended)
```bash
# Trigger workflow manually
gh workflow run chaos.yaml \
  -f experiment=pod-kill-go-service \
  -f environment=staging \
  -f dry_run=false
```

### Via kubectl (Manual)
```bash
# 1. Apply experiment manifest
kubectl apply -f chaos/experiments/pod-kill-go-service.yaml

# 2. Monitor experiment
kubectl get chaosengine -n litmus -w

# 3. View experiment details
kubectl describe chaosengine pod-kill-go-service -n litmus

# 4. View chaos results
kubectl get chaosresult -n litmus
kubectl describe chaosresult pod-kill-go-service -n litmus
```

### Via Litmus Portal (UI)
1. Access portal: `https://litmus.example.com`
2. Navigate to **Chaos Experiments**
3. Select experiment → **Schedule**
4. Choose target namespace → **Run**

---

## Experiment Details

### 1. Pod Kill Experiments
**Files:** `chaos/experiments/pod-kill-{go-service,node-service,frontend}.yaml`

**Parameters:**
```yaml
spec:
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: "30"        # Seconds
            - name: CHAOS_INTERVAL
              value: "10"        # Seconds between kills
            - name: FORCE
              value: "false"     # Graceful termination
            - name: PODS_AFFECTED_PERC
              value: "50"        # Kill 50% of pods
            - name: TARGET_PODS
              value: "go-service-xxx,go-service-yyy"  # Optional specific pods
```

**Expected Behavior:**
- 50% of pods terminated over 30 seconds
- HPA scales up new pods within 60s
- ArgoCD detects drift and re-syncs within 3m
- Zero downtime (rolling kill)
- Error rate < 1% during experiment

**Verification:**
```bash
# Watch pods during experiment
kubectl get pods -n production -l app=go-service -w

# Check HPA
kubectl get hpa go-service -n production -w

# Check ArgoCD sync
argocd app get go-service-production -w
```

### 2. Network Latency Experiment
**File:** `chaos/experiments/network-latency.yaml`

**Parameters:**
```yaml
spec:
  experiments:
    - name: network-latency
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: "300"       # 5 minutes
            - name: LATENCY
              value: "500"       # ms base latency
            - name: JITTER
              value: "100"       # ms random jitter
            - name: TOXICITY
              value: "100"       # % packets affected
            - name: NETWORK_INTERFACE
              value: "eth0"
            - name: TARGET_CONTAINER
              value: ""          # All containers
```

**Expected Behavior:**
- 500ms ±100ms latency added to all pod traffic
- Services handle gracefully (timeouts, retries)
- Circuit breakers activate if configured
- No cascade failures

**Verification:**
```bash
# Test latency from within cluster
kubectl run -i --rm --restart=Never curl-test --image=curlimages/curl -- \
  curl -w "time_total: %{time_total}\n" -o /dev/null -s http://go-service.production.svc/health

# Check application metrics
# Grafana: latency percentiles, error rates, circuit breaker state
```

### 3. CPU Stress Experiment
**File:** `chaos/experiments/cpu-stress.yaml`

**Parameters:**
```yaml
spec:
  experiments:
    - name: cpu-hog
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: "300"       # 5 minutes
            - name: CPU_CORES
              value: "1"         # Stress 1 core per pod
            - name: LOAD_PERCENTAGE
              value: "90"        # 90% CPU utilization
            - name: TARGET_CONTAINER
              value: ""          # All containers
```

**Expected Behavior:**
- Pods consume ~90% CPU
- HPA scales up replicas (if CPU metric configured)
- Pods not OOMKilled (memory unchanged)
- Request latency increases but stays < threshold
- ArgoCD does NOT resync (no spec change)

**Verification:**
```bash
# Watch HPA scaling
kubectl get hpa -n production -w

# Check pod CPU usage
kubectl top pods -n production -l app=go-service

# Check for throttling
kubectl get pods -n production -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.running}{"\n"}{end}'
```

---

## Pre-Flight Checklist

Before running ANY experiment:

```bash
# 1. Verify steady state
./scripts/verify-steady-state.sh --environment production

# 2. Check no ongoing deployments
argocd app list | grep -E "Progressing|Syncing"

# 3. Verify error budget available
# Grafana: error budget remaining > 50%

# 4. Notify team
# Slack: #platform-ops "Starting chaos experiment: pod-kill-go-service in production"

# 5. Confirm maintenance window
# Check: Not during peak traffic, not during other maintenance
```

### Steady State Verification Script
```bash
#!/bin/bash
# scripts/verify-steady-state.sh

ENVIRONMENT=${1:-production}
NAMESPACE=${ENVIRONMENT}

echo "=== Steady State Check for $ENVIRONMENT ==="

# Check deployments
echo "Checking deployments..."
kubectl get deployments -n $NAMESPACE -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.readyReplicas}/{.spec.replicas}{"\t"}{.status.conditions[?(@.type=="Available")].status}{"\n"}{end}'

# Check pods
echo "Checking pods..."
kubectl get pods -n $NAMESPACE --field-selector=status.phase!=Running -o name

# Check ArgoCD
echo "Checking ArgoCD..."
argocd app list -o json | jq -r '.[] | select(.status.sync.status!="Synced" or .status.health.status!="Healthy") | .name'

# Check error rate (requires Prometheus)
# curl -s "http://prometheus:9090/api/v1/query?query=rate(http_requests_total{status=~\"5..\"}[5m])" | jq '.data.result[] | select(.value[1] > "0.01")'

echo "=== Check complete ==="
```

---

## During Experiment

### Monitoring Dashboard
Open Grafana dashboard: `chaos/experiment-overview`

**Key Panels:**
- Pod count per deployment (should dip then recover)
- HPA replica count (should scale up)
- Request latency p50/p95/p99
- Error rate (5xx)
- CPU/Memory usage
- ArgoCD sync status

### Abort Criteria
**STOP experiment immediately if:**
- Error rate > 5% for > 30 seconds
- Any deployment goes to 0 ready replicas
- ArgoCD shows `Degraded` for > 2 minutes
- Any pod OOMKilled
- Cascade failure detected (other services impacted)

```bash
# Emergency abort
kubectl delete chaosengine pod-kill-go-service -n litmus

# Or via Litmus Portal: Click "Abort"
```

---

## Post-Experiment

### Verification Checklist
```bash
# 1. Verify steady state restored
./scripts/verify-steady-state.sh --environment production

# 2. Check experiment results
kubectl get chaosresult pod-kill-go-service -n litmus -o yaml

# 3. Review metrics
# - Latency returned to baseline?
# - Error rate back to < 0.1%?
# - All pods running and ready?
# - HPA at steady replica count?
# - ArgoCD all Synced + Healthy?

# 4. Document results
# Create incident/learning record:
# - Experiment name, date, duration
# - Observed behavior vs expected
# - Any surprises
# - Action items (fixes, improvements)
```

### Results Interpretation

| Result | Meaning | Action |
|--------|---------|--------|
| `Pass` | All steady state criteria met | Document, no action needed |
| `Fail` | Steady state violated | Investigate root cause, create fix task |
| `Partial` | Some metrics degraded but recovered | Analyze, may need tuning |

---

## Experiment Development

### Adding New Experiment
1. Create experiment manifest in `chaos/experiments/`
2. Define steady state probes (entry/exit criteria)
3. Test in staging environment
4. Add to GitHub Actions workflow
5. Document in this runbook

### Experiment Template
```yaml
# chaos/experiments/new-experiment.yaml
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: new-experiment
  namespace: litmus
spec:
  appinfo:
    appns: production
    applabel: "app=go-service"
  chaosServiceAccount: litmus-admin
  monitoring: true
  jobCleanUpPolicy: delete
  experiments:
    - name: experiment-name
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: "60"
        # Add probes for steady state verification
        probe:
          - name: "steady-state-check"
            type: "httpProbe"
            httpProbe/inputs:
              url: "http://go-service.production.svc/health"
              criteria: "==200"
            mode: "Continuous"
            runProperties:
              probeTimeout: 10
              interval: 5
              probePollingInterval: 2
```

---

## Safety Guidelines

### Never Run in Production Without:
- [ ] Successful run in staging
- [ ] Team notification (Slack + calendar invite)
- [ ] On-call engineer available
- [ ] Rollback plan documented
- [ ] Abort criteria defined and understood

### Blast Radius Control
- Start with single service in staging
- Use `PODS_AFFECTED_PERC: "25"` initially
- Gradually increase to 50%, then 100%
- Never run multiple experiments simultaneously

### Scheduling
- **Staging:** Daily automated (03:00 UTC via GitHub Actions)
- **Production:** Manual only, business hours, with on-call
- **Blocklist:** No experiments during:
  - Black Friday / peak events
  - Major releases (24h before/after)
  - Known infrastructure maintenance

---

## Troubleshooting

### Experiment Stuck in "Running"
```bash
# Check chaosengine status
kubectl get chaosengine -n litmus

# Check runner pods
kubectl get pods -n litmus -l chaosengine=new-experiment

# Check logs
kubectl logs -n litmus -l chaosengine=new-experiment -c chaos-experiment

# Force delete if stuck
kubectl delete chaosengine new-experiment -n litmus --force --grace-period=0
```

### Probe Failures
```bash
# Check probe details
kubectl get chaosresult -n litmus -o yaml

# Common probe issues:
# - HTTP probe: service not ready, wrong URL, TLS issues
# - Cmd probe: command not found, permission denied
# - K8s probe: RBAC issues, resource not found
```

### Litmus Operator Issues
```bash
# Restart operator
kubectl rollout restart deployment/litmus-operator -n litmus

# Check operator logs
kubectl logs -n litmus deployment/litmus-operator -f
```

---

## Related Runbooks
- [Load Testing](./load-testing.md) - k6 load tests
- [ArgoCD Operations](./argocd-operations.md) - ArgoCD self-healing
- [Disaster Recovery](./disaster-recovery.md) - Full recovery procedures

---

## Quick Reference

| Task | Command |
|------|---------|
| List experiments | `kubectl get chaosengine -n litmus` |
| Run experiment | `kubectl apply -f chaos/experiments/<name>.yaml` |
| Watch experiment | `kubectl get chaosengine <name> -n litmus -w` |
| View results | `kubectl get chaosresult -n litmus` |
| Abort experiment | `kubectl delete chaosengine <name> -n litmus` |
| Verify steady state | `./scripts/verify-steady-state.sh --environment production` |
| Trigger via GH Actions | `gh workflow run chaos.yaml -f experiment=<name>` |