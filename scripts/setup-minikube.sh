#!/usr/bin/env bash
# Idempotently create/start the platform minikube cluster with pinned addons.
# Safe to re-run: an existing, running cluster is left untouched.
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-platform}"
K8S_VERSION="${K8S_VERSION:-v1.30.2}"
CPUS="${MINIKUBE_CPUS:-4}"
# 7800mb, not 8192mb: minikube refuses a node larger than the Docker engine's
# total memory, and a stock Docker Desktop install is allocated 8GB (7834MB
# usable). Override with MINIKUBE_MEMORY after raising the Docker Desktop
# memory limit above 8GB.
MEMORY="${MINIKUBE_MEMORY:-7800mb}"
DISK="${MINIKUBE_DISK:-50g}"
ADDONS=(registry ingress metrics-server)

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v minikube >/dev/null || die "minikube not found — run 'mise install' first"

if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  log "Profile '$PROFILE' exists; starting it"
  minikube start -p "$PROFILE" >/dev/null
else
  log "Creating profile '$PROFILE' (k8s $K8S_VERSION, ${CPUS}cpu, $MEMORY, $DISK)"
  minikube start \
    -p "$PROFILE" \
    --driver=docker \
    --kubernetes-version="$K8S_VERSION" \
    --cpus="$CPUS" \
    --memory="$MEMORY" \
    --disk-size="$DISK" \
    --addons="${ADDONS[*]}" \
    --embed-certs=true
fi

for addon in "${ADDONS[@]}"; do
  log "Ensuring addon '$addon' enabled"
  minikube addons enable "$addon" -p "$PROFILE" >/dev/null
done

kubectl config use-context "$PROFILE" >/dev/null
log "Cluster ready. Context: $PROFILE"
minikube status -p "$PROFILE"
