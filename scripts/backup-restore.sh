#!/usr/bin/env bash
# Disaster Recovery Backup/Restore Script
# Main entry point for backup and restore operations

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
BACKUP_DIR="${BACKUP_DIR:-/tmp/dr-backups}"
S3_BUCKET="${S3_BUCKET:-ministack-backups}"
S3_ENDPOINT="${S3_ENDPOINT:-http://minio.minio.svc:9000}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
POSTGRES_HOST="${POSTGRES_HOST:-postgres-cluster-pgbouncer.platform-system.svc}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
VAULT_ADDR="${VAULT_ADDR:-http://vault.vault.svc:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
ARGOCD_SERVER="${ARGOCD_SERVER:-}"
ARGOCD_TOKEN="${ARGOCD_TOKEN:-}"
NAMESPACE="${NAMESPACE:-platform-system}"

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}\n"; }

usage() {
    cat <<EOF
${BOLD}Disaster Recovery Backup/Restore Script${NC}

${BOLD}Usage:${NC}
  $0 <command> [options]

${BOLD}Commands:${NC}
  backup              Run full backup (postgres + vault + argocd)
  backup-postgres     Backup PostgreSQL databases only
  backup-vault        Backup Vault secrets only
  backup-argocd       Backup ArgoCD applications/manifests only
  restore             Run full restore (interactive)
  restore-postgres    Restore PostgreSQL databases only
  restore-vault       Restore Vault secrets only
  restore-argocd      Restore ArgoCD applications only
  list                List available backups
  schedule            Install CronJob for daily backups

${BOLD}Options:${NC}
  --timestamp TS      Specific backup timestamp to restore (default: latest)
  --namespace NS      Kubernetes namespace (default: platform-system)
  --dry-run           Show what would be done without executing
  --force             Skip confirmation prompts
  -h, --help          Show this help

${BOLD}Environment Variables:${NC}
  BACKUP_DIR              Local backup directory (default: /tmp/dr-backups)
  S3_BUCKET               S3 bucket for backups (default: ministack-backups)
  S3_ENDPOINT             S3 endpoint URL (default: http://minio.minio.svc:9000)
  AWS_ACCESS_KEY_ID       AWS/Minio access key
  AWS_SECRET_ACCESS_KEY   AWS/Minio secret key
  POSTGRES_HOST           PostgreSQL host (default: postgres-cluster-pgbouncer.platform-system.svc)
  POSTGRES_PORT           PostgreSQL port (default: 5432)
  POSTGRES_USER           PostgreSQL user (default: postgres)
  POSTGRES_PASSWORD       PostgreSQL password
  VAULT_ADDR              Vault address (default: http://vault.vault.svc:8200)
  VAULT_TOKEN             Vault token
  ARGOCD_SERVER           ArgoCD server URL
  ARGOCD_TOKEN            ArgoCD auth token

${BOLD}Examples:${NC}
  $0 backup                              # Full backup
  $0 backup-postgres                     # PostgreSQL only
  $0 restore --timestamp 20260115-120000 # Restore specific backup
  $0 list                                # List available backups
  $0 schedule                            # Install daily backup CronJob

EOF
}

# Check required tools
check_tools() {
    local missing=()
    for tool in kubectl pg_dump pg_restore aws vault argocd jq; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing tools (some operations may fail): ${missing[*]}"
    fi
}

# Generate timestamp
timestamp() {
    date +"%Y%m%d-%H%M%S"
}

# Ensure backup directory exists
ensure_backup_dir() {
    mkdir -p "$BACKUP_DIR"
}

# Upload to S3
s3_upload() {
    local file="$1"
    local key="$2"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would upload $file to s3://$S3_BUCKET/$key"
        return
    fi
    AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    aws --endpoint-url "$S3_ENDPOINT" s3 cp "$file" "s3://$S3_BUCKET/$key"
}

# Download from S3
s3_download() {
    local key="$1"
    local file="$2"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would download s3://$S3_BUCKET/$key to $file"
        return
    fi
    AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    aws --endpoint-url "$S3_ENDPOINT" s3 cp "s3://$S3_BUCKET/$key" "$file"
}

# List backups in S3
s3_list() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would list s3://$S3_BUCKET/"
        return
    fi
    AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BUCKET/" --recursive
}

# Main command dispatcher
main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    COMMAND="$1"
    shift

    DRY_RUN=false
    FORCE=false
    RESTORE_TIMESTAMP=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --timestamp)
                RESTORE_TIMESTAMP="$2"
                shift 2
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
                shift
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

    check_tools
    ensure_backup_dir

    case "$COMMAND" in
        backup)
            log_step "Starting Full Backup"
            ./backup-postgres.sh
            ./backup-vault.sh
            ./backup-argocd.sh
            log_success "Full backup completed"
            ;;
        backup-postgres)
            ./backup-postgres.sh
            ;;
        backup-vault)
            ./backup-vault.sh
            ;;
        backup-argocd)
            ./backup-argocd.sh
            ;;
        restore)
            if [[ -z "$RESTORE_TIMESTAMP" ]]; then
                log_info "Finding latest backup..."
                RESTORE_TIMESTAMP=$(s3_list | grep -E 'postgres.*\.dump$' | tail -1 | awk '{print $4}' | sed 's|.*postgres-\(.*\)\.dump|\1|' || echo "")
                if [[ -z "$RESTORE_TIMESTAMP" ]]; then
                    log_error "No backups found"
                    exit 1
                fi
                log_info "Using latest backup: $RESTORE_TIMESTAMP"
            fi
            if [[ "$FORCE" != true ]]; then
                echo -e "${YELLOW}${BOLD}⚠️  This will RESTORE from backup $RESTORE_TIMESTAMP. Are you sure? (y/N)${NC}"
                read -r confirm
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    log_info "Restore cancelled"
                    exit 0
                fi
            fi
            ./restore-postgres.sh --timestamp "$RESTORE_TIMESTAMP"
            ./restore-vault.sh --timestamp "$RESTORE_TIMESTAMP"
            ./restore-argocd.sh --timestamp "$RESTORE_TIMESTAMP"
            log_success "Full restore completed"
            ;;
        restore-postgres)
            ./restore-postgres.sh ${RESTORE_TIMESTAMP:+--timestamp "$RESTORE_TIMESTAMP"}
            ;;
        restore-vault)
            ./restore-vault.sh ${RESTORE_TIMESTAMP:+--timestamp "$RESTORE_TIMESTAMP"}
            ;;
        restore-argocd)
            ./restore-argocd.sh ${RESTORE_TIMESTAMP:+--timestamp "$RESTORE_TIMESTAMP"}
            ;;
        list)
            log_step "Available Backups"
            s3_list
            ;;
        schedule)
            ./install-backup-cronjob.sh
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            usage
            exit 1
            ;;
    esac
}

main "$@"