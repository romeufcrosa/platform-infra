#!/usr/bin/env bash
# Vault Restore Script
# Restores Vault secrets from S3 backup

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[VAULT-RESTORE]${NC} $*"; }
log_success() { echo -e "${GREEN}[VAULT-RESTORE]${NC} $*"; }
log_error() { echo -e "${RED}[VAULT-RESTORE]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[VAULT-RESTORE]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/backup-restore.sh" 2>/dev/null || true

# Parse timestamp argument
RESTORE_TIMESTAMP=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --timestamp)
            RESTORE_TIMESTAMP="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -z "$RESTORE_TIMESTAMP" ]]; then
    log_error "Timestamp required. Use --timestamp <YYYYMMDD-HHMMSS>"
    exit 1
fi

if [[ -z "$VAULT_TOKEN" ]]; then
    log_error "VAULT_TOKEN not set"
    exit 1
fi

S3_KEY="vault/vault-$RESTORE_TIMESTAMP.json.gz"
LOCAL_FILE="$BACKUP_DIR/vault-$RESTORE_TIMESTAMP.json.gz"

log_step "Starting Vault Restore: $RESTORE_TIMESTAMP"

# Download from S3
log_info "Downloading from S3: s3://$S3_BUCKET/$S3_KEY"
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would download from S3"
else
    s3_download "$S3_KEY" "$LOCAL_FILE"
    log_success "Downloaded to $LOCAL_FILE"
fi

# Decompress
log_info "Decompressing..."
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would run: gunzip $LOCAL_FILE"
else
    gunzip -f "$LOCAL_FILE"
    RESTORE_FILE="${LOCAL_FILE%.gz}"
    log_success "Decompressed to $RESTORE_FILE"
fi

# Restore secrets
log_info "Restoring secrets to $VAULT_ADDR..."
export VAULT_ADDR="$VAULT_ADDR"
export VAULT_TOKEN="$VAULT_TOKEN"

if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would restore secrets from $RESTORE_FILE"
else
    # Read the backup file and restore each secret
    # The backup file contains JSON arrays of secret data
    jq -c '.[]' "$RESTORE_FILE" 2>/dev/null | while read -r secret; do
        if [[ -n "$secret" ]]; then
            PATH=$(echo "$secret" | jq -r '.path // empty')
            DATA=$(echo "$secret" | jq -c '.data.data // .data // empty')
            if [[ -n "$PATH" && -n "$DATA" ]]; then
                echo "$DATA" | vault kv put "$PATH" - 2>/dev/null || log_warn "Failed to restore $PATH"
            fi
        fi
    done
    log_success "Vault restore completed"
fi

# Cleanup
if [[ "$DRY_RUN" != true ]]; then
    rm -f "$RESTORE_FILE"
    log_info "Cleaned up local file"
fi

log_success "Vault restore completed: $RESTORE_TIMESTAMP"