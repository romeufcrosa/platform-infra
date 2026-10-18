#!/usr/bin/env bash
# ArgoCD Restore Script
# Restores ArgoCD applications and manifests from backup

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[ARGOCD-RESTORE]${NC} $*"; }
log_success() { echo -e "${GREEN}[ARGOCD-RESTORE]${NC} $*"; }
log_error() { echo -e "${RED}[ARGOCD-RESTORE]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[ARGOCD-RESTORE]${NC} $*"; }

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

S3_KEY="argocd/argocd-$RESTORE_TIMESTAMP.tar.gz"
LOCAL_ARCHIVE="$BACKUP_DIR/argocd-$RESTORE_TIMESTAMP.tar.gz"
EXTRACT_DIR="$BACKUP_DIR/argocd-$RESTORE_TIMESTAMP"

log_step "Starting ArgoCD Restore: $RESTORE_TIMESTAMP"

# Download from S3
log_info "Downloading from S3: s3://$S3_BUCKET/$S3_KEY"
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would download from S3"
else
    s3_download "$S3_KEY" "$LOCAL_ARCHIVE"
    log_success "Downloaded to $LOCAL_ARCHIVE"
fi

# Extract
log_info "Extracting archive..."
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would run: tar -xzf $LOCAL_ARCHIVE -C $BACKUP_DIR"
else
    tar -xzf "$LOCAL_ARCHIVE" -C "$BACKUP_DIR"
    log_success "Extracted to $EXTRACT_DIR"
fi

# Restore via ArgoCD CLI (if configured)
if [[ -n "$ARGOCD_SERVER" && -n "$ARGOCD_TOKEN" ]]; then
    log_info "Restoring ArgoCD resources via CLI..."
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would restore applications, projects, repositories"
    else
        argocd login "$ARGOCD_SERVER" --auth-token "$ARGOCD_TOKEN" --insecure

        # Restore projects
        if [[ -f "$EXTRACT_DIR/projects.json" ]]; then
            jq -c '.[]' "$EXTRACT_DIR/projects.json" | while read -r proj; do
                echo "$proj" | argocd proj create - 2>/dev/null || log_warn "Project already exists or failed"
            done
        fi

        # Restore repositories
        if [[ -f "$EXTRACT_DIR/repositories.json" ]]; then
            jq -c '.[]' "$EXTRACT_DIR/repositories.json" | while read -r repo; do
                echo "$repo" | argocd repo add - 2>/dev/null || log_warn "Repository already exists or failed"
            done
        fi

        # Restore applications
        if [[ -f "$EXTRACT_DIR/applications.json" ]]; then
            jq -c '.[]' "$EXTRACT_DIR/applications.json" | while read -r app; do
                echo "$app" | argocd app create - 2>/dev/null || log_warn "Application already exists or failed"
            done
        fi
        log_success "ArgoCD CLI restore completed"
    fi
fi

# Restore via Git manifests (apply kustomize)
log_info "Restoring manifests via kubectl apply -k..."
if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] Would run: kubectl apply -k $EXTRACT_DIR/manifests"
else
    kubectl apply -k "$EXTRACT_DIR/manifests"
    log_success "Manifests applied"
fi

# Cleanup
if [[ "$DRY_RUN" != true ]]; then
    rm -rf "$EXTRACT_DIR" "$LOCAL_ARCHIVE"
    log_info "Cleaned up local files"
fi

log_success "ArgoCD restore completed: $RESTORE_TIMESTAMP"