#!/usr/bin/env bash
# Promotion CLI Script
# Usage: ./promote.sh <service> <from_env> <to_env> [options]
#
# Services: frontend, go-service, node-service, all
# Environments: dev, staging, prod
#
# Options:
#   --dry-run         Show what would be done without executing
#   --verify          Run post-promotion verification (default: true)
#   --no-verify       Skip post-promotion verification
#   --rollback        Rollback to previous revision instead of promoting
#   --revision N      Specific revision to rollback to (with --rollback)
#   --timeout N       Timeout in seconds for wait (default: 300)
#   -h, --help        Show this help

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Defaults
DRY_RUN=false
VERIFY=true
ROLLBACK=false
ROLLBACK_REVISION=""
TIMEOUT=300
ARGOCD_SERVER="${ARGOCD_SERVER:-}"
ARGOCD_TOKEN="${ARGOCD_TOKEN:-}"

# Service list
ALL_SERVICES=("frontend" "go-service" "node-service")

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}\n"; }

# Help
usage() {
    cat <<EOF
${BOLD}Promotion CLI Script${NC}

${BOLD}Usage:${NC}
  $0 <service> <from_env> <to_env> [options]

${BOLD}Arguments:${NC}
  service        Service to promote: frontend, go-service, node-service, or all
  from_env       Source environment: dev, staging
  to_env         Target environment: staging, prod

${BOLD}Options:${NC}
  --dry-run              Show what would be done without executing
  --verify               Run post-promotion verification (default: true)
  --no-verify            Skip post-promotion verification
  --rollback             Rollback to previous revision instead of promoting
  --revision N           Specific revision to rollback to (requires --rollback)
  --timeout N            Timeout in seconds for wait (default: 300)
  -h, --help             Show this help

${BOLD}Environment Variables:${NC}
  ARGOCD_SERVER          ArgoCD server URL (e.g., https://argocd.example.com)
  ARGOCD_TOKEN           ArgoCD auth token

${BOLD}Examples:${NC}
  $0 frontend dev staging                    # Promote frontend from dev to staging
  $0 all dev staging                         # Promote all services from dev to staging
  $0 go-service staging prod --dry-run       # Dry-run go-service promotion to prod
  $0 node-service staging prod --rollback    # Rollback node-service in prod
  $0 all dev staging --no-verify             # Promote all without verification

EOF
}

# Parse arguments
parse_args() {
    if [[ $# -lt 3 ]]; then
        usage
        exit 1
    fi

    SERVICE="$1"
    FROM_ENV="$2"
    TO_ENV="$3"
    shift 3

    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verify)
                VERIFY=true
                shift
                ;;
            --no-verify)
                VERIFY=false
                shift
                ;;
            --rollback)
                ROLLBACK=true
                shift
                ;;
            --revision)
                ROLLBACK_REVISION="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Validate arguments
validate_args() {
    # Validate service
    if [[ "$SERVICE" != "all" ]]; then
        local valid=false
        for svc in "${ALL_SERVICES[@]}"; do
            if [[ "$SERVICE" == "$svc" ]]; then
                valid=true
                break
            fi
        done
        if [[ "$valid" == false ]]; then
            log_error "Invalid service: $SERVICE. Must be one of: ${ALL_SERVICES[*]}, all"
            exit 1
        fi
        SERVICES=("$SERVICE")
    else
        SERVICES=("${ALL_SERVICES[@]}")
    fi

    # Validate environments
    case "$FROM_ENV" in
        dev|staging) ;;
        *)
            log_error "Invalid from_env: $FROM_ENV. Must be: dev or staging"
            exit 1
            ;;
    esac

    case "$TO_ENV" in
        staging|prod) ;;
        *)
            log_error "Invalid to_env: $TO_ENV. Must be: staging or prod"
            exit 1
            ;;
    esac

    # Validate promotion path
    if [[ "$FROM_ENV" == "staging" && "$TO_ENV" == "dev" ]]; then
        log_error "Cannot promote from staging to dev"
        exit 1
    fi
    if [[ "$FROM_ENV" == "prod" ]]; then
        log_error "Cannot promote from prod"
        exit 1
    fi

    # Check required tools
    if ! command -v argocd &> /dev/null; then
        log_error "argocd CLI not found. Install from https://github.com/argoproj/argo-cd/releases"
        exit 1
    fi
    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Please install jq"
        exit 1
    fi

    # Check ArgoCD credentials
    if [[ -z "$ARGOCD_SERVER" ]]; then
        log_error "ARGOCD_SERVER environment variable not set"
        exit 1
    fi
    if [[ -z "$ARGOCD_TOKEN" ]]; then
        log_error "ARGOCD_TOKEN environment variable not set"
        exit 1
    fi
}

# Login to ArgoCD
argocd_login() {
    log_step "Logging into ArgoCD"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would run: argocd login $ARGOCD_SERVER --auth-token *** --insecure"
        return
    fi
    argocd login "$ARGOCD_SERVER" --auth-token "$ARGOCD_TOKEN" --insecure
    log_success "Logged into ArgoCD"
}

# Get application name
app_name() {
    local service="$1"
    local env="$2"
    echo "${service}-${env}"
}

# Check if app exists
app_exists() {
    local app="$1"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would check if app $app exists"
        return 0
    fi
    argocd app get "$app" &>/dev/null
}

# Get app status
get_app_status() {
    local app="$1"
    if [[ "$DRY_RUN" == true ]]; then
        echo '{"status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}}}'
        return
    fi
    argocd app get "$app" -o json
}

# Pre-flight checks
preflight_checks() {
    log_step "Pre-flight Checks"

    for svc in "${SERVICES[@]}"; do
        local src_app=$(app_name "$svc" "$FROM_ENV")
        local tgt_app=$(app_name "$svc" "$TO_ENV")

        log_info "Checking $src_app (source)..."

        # Check source app exists
        if ! app_exists "$src_app"; then
            log_error "Source application $src_app does not exist"
            return 1
        fi

        # Check source app is Synced and Healthy
        local status=$(get_app_status "$src_app")
        local sync_status=$(echo "$status" | jq -r '.status.sync.status')
        local health_status=$(echo "$status" | jq -r '.status.health.status')

        if [[ "$sync_status" != "Synced" ]]; then
            log_error "Source app $src_app is not Synced (status: $sync_status)"
            return 1
        fi
        if [[ "$health_status" != "Healthy" ]]; then
            log_error "Source app $src_app is not Healthy (status: $health_status)"
            return 1
        fi
        log_success "$src_app is Synced and Healthy"

        # Check target app exists (for promotion, not rollback)
        if [[ "$ROLLBACK" == false ]]; then
            if ! app_exists "$tgt_app"; then
                log_error "Target application $tgt_app does not exist"
                return 1
            fi
            log_success "Target app $tgt_app exists"
        fi
    done

    return 0
}

# Promote service
promote_service() {
    local svc="$1"
    local tgt_app=$(app_name "$svc" "$TO_ENV")

    log_step "Promoting $svc to $TO_ENV"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would run: argocd app sync $tgt_app --prune"
        return 0
    fi

    log_info "Syncing $tgt_app..."
    if argocd app sync "$tgt_app" --prune; then
        log_success "$tgt_app sync initiated"
        return 0
    else
        log_error "Failed to sync $tgt_app"
        return 1
    fi
}

# Rollback service
rollback_service() {
    local svc="$1"
    local tgt_app=$(app_name "$svc" "$TO_ENV")

    log_step "Rolling back $svc in $TO_ENV"

    # Get current revision
    local status=$(get_app_status "$tgt_app")
    local current_rev=$(echo "$status" | jq -r '.status.sync.revision // "unknown"')

    if [[ -z "$ROLLBACK_REVISION" ]]; then
        # Get previous revision
        local history=$(argocd app history "$tgt_app" -o json 2>/dev/null || echo '[]')
        local prev_rev=$(echo "$history" | jq -r '.[1].revision // .[0].revision // empty')
        if [[ -z "$prev_rev" ]]; then
            log_error "Could not determine previous revision for rollback"
            return 1
        fi
        ROLLBACK_REVISION="$prev_rev"
    fi

    log_info "Current revision: $current_rev, Rolling back to: $ROLLBACK_REVISION"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would run: argocd app rollback $tgt_app $ROLLBACK_REVISION"
        return 0
    fi

    if argocd app rollback "$tgt_app" "$ROLLBACK_REVISION"; then
        log_success "$tgt_app rolled back to revision $ROLLBACK_REVISION"
        return 0
    else
        log_error "Failed to rollback $tgt_app"
        return 1
    fi
}

# Wait for app to be healthy
wait_for_healthy() {
    local svc="$1"
    local tgt_app=$(app_name "$svc" "$TO_ENV")

    log_step "Waiting for $tgt_app to become Healthy (timeout: ${TIMEOUT}s)"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would wait for $tgt_app to become Healthy"
        return 0
    fi

    if argocd app wait "$tgt_app" --health --timeout "$TIMEOUT"; then
        local status=$(get_app_status "$tgt_app")
        local sync_status=$(echo "$status" | jq -r '.status.sync.status')
        local health_status=$(echo "$status" | jq -r '.status.health.status')

        if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
            log_success "$tgt_app is Synced and Healthy"
            return 0
        else
            log_error "$tgt_app failed verification (sync: $sync_status, health: $health_status)"
            return 1
        fi
    else
        log_error "Timeout waiting for $tgt_app to become Healthy"
        return 1
    fi
}

# Run verification script if exists
run_verification() {
    if [[ ! -f "scripts/verify-promotion.sh" ]]; then
        log_info "No verify-promotion.sh script found, skipping custom verification"
        return 0
    fi

    log_step "Running custom verification script"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would run: ./scripts/verify-promotion.sh $TO_ENV ${SERVICES[*]}"
        return 0
    fi

    chmod +x scripts/verify-promotion.sh
    if ./scripts/verify-promotion.sh "$TO_ENV" "${SERVICES[@]}"; then
        log_success "Custom verification passed"
        return 0
    else
        log_error "Custom verification failed"
        return 1
    fi
}

# Main
main() {
    parse_args "$@"
    validate_args

    echo -e "${BOLD}${CYAN}"
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║                    PROMOTION CLI SCRIPT                       ║
╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"

    log_info "Service(s): ${SERVICES[*]}"
    log_info "From: $FROM_ENV → To: $TO_ENV"
    log_info "Mode: $( [[ "$ROLLBACK" == true ]] && echo "ROLLBACK" || echo "PROMOTE" )"
    log_info "Dry-run: $DRY_RUN"
    log_info "Verify: $VERIFY"
    echo

    # Confirmation for non-dry-run promotions to prod
    if [[ "$DRY_RUN" == false && "$ROLLBACK" == false && "$TO_ENV" == "prod" ]]; then
        echo -e "${YELLOW}${BOLD}⚠️  This will promote to PRODUCTION. Are you sure? (y/N)${NC}"
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Promotion cancelled"
            exit 0
        fi
    fi

    argocd_login

    if ! preflight_checks; then
        log_error "Pre-flight checks failed"
        exit 1
    fi

    # Perform promotion/rollback for each service
    local failed=()
    for svc in "${SERVICES[@]}"; do
        if [[ "$ROLLBACK" == true ]]; then
            if ! rollback_service "$svc"; then
                failed+=("$svc")
            fi
        else
            if ! promote_service "$svc"; then
                failed+=("$svc")
            fi
        fi
    done

    # Verification
    if [[ "$VERIFY" == true && "$ROLLBACK" == false ]]; then
        for svc in "${SERVICES[@]}"; do
            if [[ ! " ${failed[*]} " =~ " ${svc} " ]]; then
                if ! wait_for_healthy "$svc"; then
                    failed+=("$svc")
                fi
            fi
        done

        if [[ ${#failed[@]} -eq 0 ]]; then
            run_verification || failed+=("verification")
        fi
    fi

    # Summary
    echo -e "\n${BOLD}${CYAN}=== SUMMARY ===${NC}"
    if [[ ${#failed[@]} -eq 0 ]]; then
        log_success "All operations completed successfully!"
        exit 0
    else
        log_error "Failed: ${failed[*]}"
        exit 1
    fi
}

# Run main
main "$@"