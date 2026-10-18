#!/usr/bin/env bash
# ArgoCD Backup Script
# Backs up ArgoCD applications and manifests to Git

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[ARGOCD-BACKUP]${NC} $*"; }
log_success() { echo -e "${GREEN}[ARGOCD-BACKUP]${NC} $*"; }
log_error() { echo -e "${RED}[ARGOCD-BACKUP]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/backup-restore.sh" 2>/dev/null || true

TS=$(timestamp)
BACKUP_DIR_LOCAL="$BACKUP_DIR/argocd-$TS"
S3_KEY="argocd/argocd-$TS.tar.gz"

log_step "Starting ArgoCD Backup: $TS"

# Check ArgoCD credentials
if [[ -z "$ARGOCD_SERVER" || -z "$ARGOCD_TOKEN" ]]; then
    log_warn "ARGOCD_SERVER or ARGOCD_TOKEN not set, skipping ArgoCD CLI backup"
    log_info "Falling back to Git-based backup (kustomize manifests)..."
fi

mkdir -p "$BACKUP_DIR_LOCAL"

# Backup via ArgoCD CLI (if configured)
if [[ -n "$ARGOCD_SERVER" && -n "$ARGOCD_TOKEN" ]]; then
    log_info "Backing up ArgoCD resources via CLI..."
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would run: argocd app list -o json > $BACKUP_DIR_LOCAL/applications.json"
    else
        argocd login "$ARGOCD_SERVER" --auth-token "$ARGOCD_TOKEN" --insecure
        argocd app list -o json > "$BACKUP_DIR_LOCAL/applications.json"
        argocd proj list -o json > "$BACKUP_DIR_LOCAL/projects.json"
        argocd repo list -o json > "$BACKUP_DIR_LOCAL/repositories.json"
        log_success "ArgoCD CLI backup saved"
    fi
fi

# Backup via Git (kustomize manifests)
log_info "Backing up kustomize manifests from Git..."
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would copy argocd/ directory to $BACKUP_DIR_LOCAL/manifests"
else
    cp -r "$SCRIPT_DIR/../argocd" "$BACKUP_DIR_LOCAL/manifests"
    log_success "Manifests backed up"
fi

# Create archive
log_info "Creating archive..."
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would run: tar -czf $BACKUP_DIR/argocd-$TS.tar.gz -C $BACKUP_DIR argocd-$TS"
else
    tar -czf "$BACKUP_DIR/argocd-$TS.tar.gz" -C "$BACKUP_DIR" "argocd-$TS"
    log_success "Archive created: $BACKUP_DIR/argocd-$TS.tar.gz"
fi

# Upload to S3
log_info "Uploading to S3: s3://$S3_BUCKET/$S3_KEY"
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would upload to S3"
else
    s3_upload "$BACKUP_DIR/argocd-$TS.tar.gz" "$S3_KEY"
    log_success "Uploaded to S3"
fi

# Cleanup
if [[ "$DRY_RUN" != true ]]; then
    rm -rf "$BACKUP_DIR_LOCAL" "$BACKUP_DIR/argocd-$TS.tar.gz"
    log_info "Cleaned up local files"
fi

log_success "ArgoCD backup completed: $S3_KEY"