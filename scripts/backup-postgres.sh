#!/usr/bin/env bash
# PostgreSQL Backup Script
# Backs up all databases to S3 (Ministack)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Source common config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/backup-restore.sh" 2>/dev/null || true

log_info() { echo -e "${BLUE}[PG-BACKUP]${NC} $*"; }
log_success() { echo -e "${GREEN}[PG-BACKUP]${NC} $*"; }
log_error() { echo -e "${RED}[PG-BACKUP]${NC} $*"; }

TS=$(timestamp)
BACKUP_FILE="$BACKUP_DIR/postgres-$TS.dump"
S3_KEY="postgres/postgres-$TS.dump"

# Check required env vars
if [[ -z "$POSTGRES_PASSWORD" ]]; then
    log_error "POSTGRES_PASSWORD not set"
    exit 1
fi

log_step "Starting PostgreSQL Backup: $TS"

# Dump all databases
log_info "Dumping all databases from $POSTGRES_HOST:$POSTGRES_PORT..."
export PGPASSWORD="$POSTGRES_PASSWORD"
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would run: pg_dumpall -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER > $BACKUP_FILE"
else
    pg_dumpall -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" > "$BACKUP_FILE"
    log_success "Dump saved to $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
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

log_success "PostgreSQL backup completed: $S3_KEY.gz"