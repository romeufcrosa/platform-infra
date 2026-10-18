#!/usr/bin/env bash
# Install Backup CronJob
# Creates a Kubernetes CronJob for daily disaster recovery backups

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[CRONJOB]${NC} $*"; }
log_success() { echo -e "${GREEN}[CRONJOB]${NC} $*"; }
log_error() { echo -e "${RED}[CRONJOB]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[CRONJOB]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CronJob manifest
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: dr-backup
  namespace: platform-system
  labels:
    app.kubernetes.io/name: dr-backup
    app.kubernetes.io/part-of: platform-infra
spec:
  schedule: "0 2 * * *"  # Daily at 02:00 UTC
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  startingDeadlineSeconds: 3600
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: dr-backup
          restartPolicy: OnFailure
          containers:
            - name: backup
              image: bitnami/kubectl:latest
              command:
                - /bin/bash
                - -c
                - |
                  set -euo pipefail
                  echo "Starting daily DR backup at $(date)"

                  # Install required tools
                  apt-get update && apt-get install -y postgresql-client awscli vault jq >/dev/null 2>&1

                  # Run backup script
                  /scripts/backup-restore.sh backup

                  echo "Daily DR backup completed at $(date)"
              env:
                - name: BACKUP_DIR
                  value: "/tmp/dr-backups"
                - name: S3_BUCKET
                  valueFrom:
                    secretKeyRef:
                      name: dr-backup-config
                      key: S3_BUCKET
                      optional: true
                - name: S3_ENDPOINT
                  valueFrom:
                    secretKeyRef:
                      name: dr-backup-config
                      key: S3_ENDPOINT
                      optional: true
                - name: AWS_ACCESS_KEY_ID
                  valueFrom:
                    secretKeyRef:
                      name: dr-backup-credentials
                      key: AWS_ACCESS_KEY_ID
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: dr-backup-credentials
                      key: AWS_SECRET_ACCESS_KEY
                - name: POSTGRES_HOST
                  valueFrom:
                    secretKeyRef:
                      name: dr-backup-config
                      key: POSTGRES_HOST
                      optional: true
                - name: POSTGRES_PORT
                  valueFrom:
                    secretKeyRef:
                      name: dr-backup-config
                      key: POSTGRES_PORT
                      optional: true
                - name: POSTGRES_USER
                  valueFrom:
                    secretKeyRef:
                      name: dr-backup-config
                      key: POSTGRES_USER
                      optional: true
                - name: POSTGRES_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: dr-backup-credentials
                      key: POSTGRES_PASSWORD
                - name: VAULT_ADDR
                  valueFrom:
                    secretKeyRef:
                      name: dr-backup-config
                      key: VAULT_ADDR
                      optional: true
                - name: VAULT_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: dr-backup-credentials
                      key: VAULT_TOKEN
                - name: ARGOCD_SERVER
                  valueFrom:
                    secretKeyRef:
                      name: dr-backup-config
                      key: ARGOCD_SERVER
                      optional: true
                - name: ARGOCD_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: dr-backup-credentials
                      key: ARGOCD_TOKEN
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
          volumes:
            - name: scripts
              configMap:
                name: dr-backup-scripts
                defaultMode: 0755
EOF

log_success "CronJob 'dr-backup' created in platform-system namespace"
log_info "Schedule: Daily at 02:00 UTC"
log_info ""
log_info "Required secrets (create before running):"
log_info "  kubectl create secret generic dr-backup-credentials \\"
log_info "    --from-literal=AWS_ACCESS_KEY_ID=... \\"
log_info "    --from-literal=AWS_SECRET_ACCESS_KEY=... \\"
log_info "    --from-literal=POSTGRES_PASSWORD=... \\"
log_info "    --from-literal=VAULT_TOKEN=... \\"
log_info "    --from-literal=ARGOCD_TOKEN=... -n platform-system"
log_info ""
log_info "  kubectl create secret generic dr-backup-config \\"
log_info "    --from-literal=S3_BUCKET=ministack-backups \\"
log_info "    --from-literal=S3_ENDPOINT=http://minio.minio.svc:9000 \\"
log_info "    --from-literal=POSTGRES_HOST=postgres-cluster-pgbouncer.platform-system.svc \\"
log_info "    --from-literal=POSTGRES_PORT=5432 \\"
log_info "    --from-literal=POSTGRES_USER=postgres \\"
log_info "    --from-literal=VAULT_ADDR=http://vault.vault.svc:8200 \\"
log_info "    --from-literal=ARGOCD_SERVER=https://argocd.example.com -n platform-system"
log_info ""
log_info "Required ConfigMap (create from scripts directory):"
log_info "  kubectl create configmap dr-backup-scripts --from-file=$SCRIPT_DIR -n platform-system"
log_info ""
log_info "Required ServiceAccount (with backup permissions):"
log_info "  kubectl create serviceaccount dr-backup -n platform-system"
log_info "  # Add RBAC for: pods, secrets, configmaps, applications.argoproj.io, etc."