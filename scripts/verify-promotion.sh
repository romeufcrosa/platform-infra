#!/usr/bin/env bash
# Verification script for promotion
# Usage: ./verify-promotion.sh <environment> <service1> [service2] ...

set -euo pipefail

ENVIRONMENT="${1:-}"
shift
SERVICES=("$@")

if [[ -z "$ENVIRONMENT" || ${#SERVICES[@]} -eq 0 ]]; then
    echo "Usage: $0 <environment> <service1> [service2] ..."
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[VERIFY]${NC} $*"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_error() { echo -e "${RED}[FAIL]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# Get namespace for environment
get_namespace() {
    case "$1" in
        dev) echo "dev" ;;
        staging) echo "staging" ;;
        prod) echo "prod" ;;
        *) echo "$1" ;;
    esac
}

NAMESPACE=$(get_namespace "$ENVIRONMENT")

# Check if kubectl is available and connected
if ! command -v kubectl &> /dev/null; then
    log_warn "kubectl not found, skipping Kubernetes-level verification"
    exit 0
fi

if ! kubectl cluster-info &>/dev/null; then
    log_warn "Not connected to cluster, skipping Kubernetes-level verification"
    exit 0
fi

FAILED=0

for svc in "${SERVICES[@]}"; do
    log_info "Verifying $svc in $ENVIRONMENT..."

    # Check deployment exists and is ready
    DEPLOYMENT="${svc}"
    if kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" &>/dev/null; then
        READY=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}')
        DESIRED=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
        if [[ "$READY" == "$DESIRED" && "$READY" -gt 0 ]]; then
            log_success "$svc deployment: $READY/$DESIRED replicas ready"
        else
            log_error "$svc deployment: $READY/$DESIRED replicas ready"
            FAILED=1
        fi
    else
        log_warn "$svc deployment not found in namespace $NAMESPACE"
    fi

    # Check pods are running
    PODS_RUNNING=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=$svc" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    PODS_TOTAL=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=$svc" --no-headers 2>/dev/null | wc -l)
    if [[ "$PODS_RUNNING" -gt 0 && "$PODS_RUNNING" -eq "$PODS_TOTAL" ]]; then
        log_success "$svc pods: $PODS_RUNNING/$PODS_TOTAL running"
    elif [[ "$PODS_TOTAL" -eq 0 ]]; then
        log_warn "$svc pods: none found"
    else
        log_error "$svc pods: $PODS_RUNNING/$PODS_TOTAL running"
        FAILED=1
    fi

    # Check service exists
    if kubectl get service "$svc" -n "$NAMESPACE" &>/dev/null; then
        log_success "$svc service exists"
    else
        log_warn "$svc service not found"
    fi

    # Check ingress exists (for staging/prod)
    if [[ "$ENVIRONMENT" == "staging" || "$ENVIRONMENT" == "prod" ]]; then
        if kubectl get ingress "$svc" -n "$NAMESPACE" &>/dev/null; then
            log_success "$svc ingress exists"
        else
            log_warn "$svc ingress not found"
        fi
    fi

    # Check PDB exists (for prod)
    if [[ "$ENVIRONMENT" == "prod" ]]; then
        if kubectl get pdb "$svc" -n "$NAMESPACE" &>/dev/null; then
            log_success "$svc PodDisruptionBudget exists"
        else
            log_warn "$svc PodDisruptionBudget not found"
        fi

        # Check NetworkPolicy exists
        if kubectl get networkpolicy "$svc" -n "$NAMESPACE" &>/dev/null; then
            log_success "$svc NetworkPolicy exists"
        else
            log_warn "$svc NetworkPolicy not found"
        fi
    fi

    # Check HPA exists
    if kubectl get hpa "$svc" -n "$NAMESPACE" &>/dev/null; then
        log_success "$svc HPA exists"
    else
        log_warn "$svc HPA not found"
    fi
done

# Check monitoring namespace for ServiceMonitors (if applicable)
if kubectl get servicemonitor -n monitoring -l "app.kubernetes.io/part-of=platform-services" &>/dev/null; then
    log_success "ServiceMonitors exist in monitoring namespace"
fi

if [[ $FAILED -eq 0 ]]; then
    log_success "All verifications passed for $ENVIRONMENT"
    exit 0
else
    log_error "Some verifications failed"
    exit 1
fi