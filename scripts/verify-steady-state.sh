#!/usr/bin/env bash
# Steady State Verification Script
# Usage: ./verify-steady-state.sh --environment <environment> [--label-selector <label>]
#
# Verifies the system is in a steady state before running chaos experiments.
# Exits 0 if steady state is confirmed, non-zero otherwise.

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Defaults
ENVIRONMENT=""
LABEL_SELECTOR="app.kubernetes.io/part-of=platform-services"
VERBOSE=false

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[FAIL]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 --environment <environment> [options]

Arguments:
  --environment, -e    Target environment (dev, staging, prod) - REQUIRED
  --label-selector, -l Label selector for target pods (default: "app.kubernetes.io/part-of=platform-services")
  --verbose, -v        Verbose output
  --help, -h           Show this help

Examples:
  $0 --environment staging
  $0 --environment prod --label-selector "app.kubernetes.io/name=go-service"
  $0 -e dev -v

Exit codes:
  0  - Steady state confirmed
  1  - Steady state verification failed
  2  - Invalid arguments
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --environment|-e)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --label-selector|-l)
            LABEL_SELECTOR="$2"
            shift 2
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 2
            ;;
    esac
done

# Validate required arguments
if [[ -z "$ENVIRONMENT" ]]; then
    log_error "Environment is required. Use --environment <dev|staging|prod>"
    usage
    exit 2
fi

# Map environment to namespace
case "$ENVIRONMENT" in
    dev) NAMESPACE="dev" ;;
    staging) NAMESPACE="staging" ;;
    prod) NAMESPACE="prod" ;;
    *)
        log_error "Invalid environment: $ENVIRONMENT. Must be dev, staging, or prod"
        exit 2
        ;;
esac

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        return 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log_error "Not connected to Kubernetes cluster"
        return 1
    fi

    if ! command -v argocd &> /dev/null; then
        log_warn "argocd CLI not found - ArgoCD checks will be skipped"
    fi

    log_success "Prerequisites OK"
    return 0
}

# Check deployments are ready
check_deployments() {
    log_info "Checking deployments in namespace: $NAMESPACE..."

    local deployments
    deployments=$(kubectl get deployments -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$deployments" ]]; then
        log_warn "No deployments found matching label: $LABEL_SELECTOR"
        return 0
    fi

    local failed=0
    for deploy in $deployments; do
        local ready desired available
        ready=$(kubectl get deployment "$deploy" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        desired=$(kubectl get deployment "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        available=$(kubectl get deployment "$deploy" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")

        if [[ "$ready" == "$desired" && "$desired" -gt 0 ]]; then
            log_success "Deployment $deploy: $ready/$desired replicas ready"
        else
            log_error "Deployment $deploy: $ready/$desired replicas ready (available: $available)"
            failed=1
        fi

        if [[ "$VERBOSE" == true ]]; then
            kubectl get deployment "$deploy" -n "$NAMESPACE" -o wide
        fi
    done

    return $failed
}

# Check pods are running
check_pods() {
    log_info "Checking pods in namespace: $NAMESPACE..."

    local not_ready
    not_ready=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" \
        --field-selector=status.phase!=Running -o name 2>/dev/null | wc -l)

    if [[ "$not_ready" -gt 0 ]]; then
        log_error "$not_ready pods not in Running state"
        kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --field-selector=status.phase!=Running -o wide
        return 1
    fi

    local total_ready
    total_ready=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" \
        --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)

    if [[ "$total_ready" -eq 0 ]]; then
        log_warn "No running pods found matching label: $LABEL_SELECTOR"
        return 0
    fi

    log_success "All $total_ready pods are Running"

    # Check container readiness
    local not_ready_containers
    not_ready_containers=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" \
        -o jsonpath='{.items[?(@.status.containerStatuses[*].ready==false)].metadata.name}' 2>/dev/null | tr ' ' '\n' | wc -l)

    if [[ "$not_ready_containers" -gt 0 ]]; then
        log_error "$not_ready_containers pods have containers not ready"
        return 1
    fi

    log_success "All containers are Ready"
    return 0
}

# Check HPA status
check_hpa() {
    log_info "Checking HPA status in namespace: $NAMESPACE..."

    local hpas
    hpas=$(kubectl get hpa -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$hpas" ]]; then
        log_warn "No HPAs found matching label: $LABEL_SELECTOR"
        return 0
    fi

    for hpa in $hpas; do
        local current desired min max
        current=$(kubectl get hpa "$hpa" -n "$NAMESPACE" -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "0")
        desired=$(kubectl get hpa "$hpa" -n "$NAMESPACE" -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo "0")
        min=$(kubectl get hpa "$hpa" -n "$NAMESPACE" -o jsonpath='{.spec.minReplicas}' 2>/dev/null || echo "0")
        max=$(kubectl get hpa "$hpa" -n "$NAMESPACE" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo "0")

        if [[ "$current" -ge "$min" && "$current" -le "$max" ]]; then
            log_success "HPA $hpa: $current replicas (min: $min, max: $max, desired: $desired)"
        else
            log_error "HPA $hpa: $current replicas outside bounds (min: $min, max: $max)"
            return 1
        fi

        if [[ "$VERBOSE" == true ]]; then
            kubectl get hpa "$hpa" -n "$NAMESPACE" -o wide
        fi
    done

    return 0
}

# Check ArgoCD application status
check_argocd() {
    log_info "Checking ArgoCD application status..."

    if ! command -v argocd &> /dev/null; then
        log_warn "argocd CLI not found, skipping ArgoCD checks"
        return 0
    fi

    # Check if logged in
    if ! argocd account get-user-info &>/dev/null; then
        log_warn "Not logged into ArgoCD, skipping ArgoCD checks"
        return 0
    fi

    local apps
    apps=$(argocd app list -l "app.kubernetes.io/part-of=platform-services" -o json 2>/dev/null | jq -r '.[].metadata.name' 2>/dev/null || echo "")

    if [[ -z "$apps" ]]; then
        log_warn "No ArgoCD applications found matching label"
        return 0
    fi

    local failed=0
    for app in $apps; do
        local sync_status health_status
        sync_status=$(argocd app get "$app" -o json 2>/dev/null | jq -r '.status.sync.status' 2>/dev/null || echo "Unknown")
        health_status=$(argocd app get "$app" -o json 2>/dev/null | jq -r '.status.health.status' 2>/dev/null || echo "Unknown")

        if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
            log_success "ArgoCD App $app: Synced + Healthy"
        elif [[ "$sync_status" == "Synced" && "$health_status" == "Progressing" ]]; then
            log_warn "ArgoCD App $app: Synced + Progressing (may be OK)"
        else
            log_error "ArgoCD App $app: Sync=$sync_status, Health=$health_status"
            failed=1
        fi

        if [[ "$VERBOSE" == true ]]; then
            argocd app get "$app"
        fi
    done

    return $failed
}

# Check error rate (requires Prometheus)
check_error_rate() {
    log_info "Checking error rate..."

    if ! command -v curl &> /dev/null; then
        log_warn "curl not found, skipping error rate check"
        return 0
    fi

    # Try to query Prometheus if available
    local prometheus_url
    prometheus_url=$(kubectl get svc -n monitoring prometheus-operated -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

    if [[ -z "$prometheus_url" ]]; then
        # Try alternative service name
        prometheus_url=$(kubectl get svc -n monitoring prometheus -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    fi

    if [[ -z "$prometheus_url" ]]; then
        log_warn "Prometheus not accessible, skipping error rate check"
        return 0
    fi

    local query='rate(http_requests_total{status=~"5.."}[5m])'
    local result
    result=$(curl -s "http://${prometheus_url}:9090/api/v1/query?query=${query}" 2>/dev/null || echo "")

    if [[ -z "$result" ]]; then
        log_warn "Could not query Prometheus, skipping error rate check"
        return 0
    fi

    local high_error
    high_error=$(echo "$result" | jq -r '.data.result[] | select(.value[1] | tonumber > 0.01) | .metric' 2>/dev/null | wc -l)

    if [[ "$high_error" -gt 0 ]]; then
        log_error "Error rate > 1% detected for $high_error series"
        return 1
    fi

    log_success "Error rate < 1%"
    return 0
}

# Main verification
main() {
    echo -e "${BLUE}=== Steady State Verification for $ENVIRONMENT ===${NC}"
    echo "Namespace: $NAMESPACE"
    echo "Label Selector: $LABEL_SELECTOR"
    echo ""

    local overall_failed=0

    check_prerequisites || overall_failed=1
    check_deployments || overall_failed=1
    check_pods || overall_failed=1
    check_hpa || overall_failed=1
    check_argocd || overall_failed=1
    check_error_rate || overall_failed=1

    echo ""
    if [[ $overall_failed -eq 0 ]]; then
        log_success "=== STEADY STATE CONFIRMED ==="
        exit 0
    else
        log_error "=== STEADY STATE VERIFICATION FAILED ==="
        exit 1
    fi
}

main "$@"