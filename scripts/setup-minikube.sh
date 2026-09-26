#!/usr/bin/env bash
# Idempotently create/start the platform minikube cluster with pinned addons.
# Safe to re-run: an existing, running cluster is left untouched.
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-platform}"
K8S_VERSION="${K8S_VERSION:-v1.30.2}"
CPUS="${MINIKUBE_CPUS:-4}"
# 7800mb, not 8192mb: minikube refuses a node larger than the Docker engine's
# total memory, and a stock Docker Desktop install is allocated 8GB (7835MB
# usable on a 16GB host). Override with MINIKUBE_MEMORY after raising the
# Docker Desktop memory limit above 8GB.
MEMORY="${MINIKUBE_MEMORY:-7800mb}"
DISK="${MINIKUBE_DISK:-50g}"
ADDONS=(ingress metrics-server)
failed_addons=()

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
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
  # One failing addon must not abort the rest — under `set -e` a hard failure here
  # leaves the remaining addons unasserted, so a re-run after one broken addon
  # silently stops working. Collect failures and report them together at the end.
  if ! minikube addons enable "$addon" -p "$PROFILE" >/dev/null; then
    warn "addon '$addon' failed to enable (see above)"
    failed_addons+=("$addon")
  fi
done

if [ ${#failed_addons[@]} -gt 0 ]; then
  die "failed to enable addon(s): ${failed_addons[*]}"
fi

kubectl config use-context "$PROFILE" >/dev/null
log "Cluster ready. Context: $PROFILE"
minikube status -p "$PROFILE"
