#!/usr/bin/env bash
# Vault Backup Script
# Backs up Vault secrets to S3 (Ministack)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[VAULT-BACKUP]${NC} $*"; }
log_success() { echo -e "${GREEN}[VAULT-BACKUP]${NC} $*"; }
log_error() { echo -e "${RED}[VAULT-BACKUP]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/backup-restore.sh" 2>/dev/null || true

TS=$(timestamp)
BACKUP_FILE="$BACKUP_DIR/vault-$TS.json"
S3_KEY="vault/vault-$TS.json"

# Check required env vars
if [[ -z "$VAULT_TOKEN" ]]; then
    log_error "VAULT_TOKEN not set"
    exit 1
fi

log_step "Starting Vault Backup: $TS"

# Export Vault secrets
log_info "Exporting secrets from $VAULT_ADDR..."
export VAULT_ADDR="$VAULT_ADDR"
export VAULT_TOKEN="$VAULT_TOKEN"

if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would run: vault kv get -format=json secret/ > $BACKUP_FILE"
else
    # Get all secret paths
    vault kv list -format=json secret/ 2>/dev/null | jq -r '.[]' | while read -r path; do
        if [[ -n "$path" && "$path" != "null" ]]; then
            vault kv get -format=json "secret/$path" 2>/dev/null | jq -s '.' >> "$BACKUP_FILE" || true
        fi
    done
    # Also get platform-specific paths
    for mount in platform-services-go platform-services-node platform-frontend platform-infra; do
        vault kv list -format=json "$mount/" 2>/dev/null | jq -r '.[]' | while read -r path; do
            if [[ -n "$path" && "$path" != "null" ]]; then
                vault kv get -format=json "$mount/$path" 2>/dev/null | jq -s '.' >> "$BACKUP_FILE" || true
            fi
        done
    done
    log_success "Secrets exported to $BACKUP_FILE"
fi

# Compress
log_info "Compressing backup..."
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would run: gzip $BACKUP_FILE"
else
    gzip "$BACKUP_FILE"
    BACKUP_FILE="${BACKUP_FILE}.gz"
    log_success "Compressed to $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
fi

# Upload to S3
log_info "Uploading to S3: s3://$S3_BUCKET/$S3_KEY.gz"
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would upload to S3"
else
    s3_upload "$BACKUP_FILE" "$S3_KEY.gz"
    log_success "Uploaded to S3"
fi

# Cleanup local file
if [[ "$DRY_RUN" != true ]]; then
    rm -f "$BACKUP_FILE"
    log_info "Cleaned up local file"
fi

log_success "Vault backup completed: $S3_KEY.gz"