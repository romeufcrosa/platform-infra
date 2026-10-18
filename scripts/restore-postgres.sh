#!/usr/bin/env bash
# PostgreSQL Restore Script
# Restores databases from S3 backup

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[PG-RESTORE]${NC} $*"; }
log_success() { echo -e "${GREEN}[PG-RESTORE]${NC} $*"; }
log_error() { echo -e "${RED}[PG-RESTORE]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[PG-RESTORE]${NC} $*"; }

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

if [[ -z "$POSTGRES_PASSWORD" ]]; then
    log_error "POSTGRES_PASSWORD not set"
    exit 1
fi

S3_KEY="postgres/postgres-$RESTORE_TIMESTAMP.dump.gz"
LOCAL_FILE="$BACKUP_DIR/postgres-$RESTORE_TIMESTAMP.dump.gz"

log_step "Starting PostgreSQL Restore: $RESTORE_TIMESTAMP"

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
    DUMP_FILE="${LOCAL_FILE%.gz}"
    log_success "Decompressed to $DUMP_FILE"
fi

# Restore
log_info "Restoring to $POSTGRES_HOST:$POSTGRES_PORT..."
export PGPASSWORD="$POSTGRES_PASSWORD"
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would run: psql -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -f $DUMP_FILE postgres"
else
    # Drop existing connections
    psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d postgres -c "
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname != 'postgres' AND pid <> pg_backend_pid();
    " 2>/dev/null || true

    # Restore
    psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -f "$DUMP_FILE" postgres
    log_success "PostgreSQL restore completed"
fi

# Cleanup
if [[ "$DRY_RUN" != true ]]; then
    rm -f "$DUMP_FILE"
    log_info "Cleaned up local file"
fi

log_success "PostgreSQL restore completed: $RESTORE_TIMESTAMP"