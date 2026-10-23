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

# ADDED BY TASK 8 — the local container registry, consumed by every Phase 2
# service.
#
# `output "in_cluster_url"` in tofu/modules/registry publishes the registry as
# `registry.registry.svc:5000`, and a pod pulling an image from that name needs
# TWO node-level things that no amount of in-cluster configuration supplies:
#
#   1. The container runtime must treat that host as a PLAIN-HTTP registry.
#      Otherwise it rewrites the scheme to `https://` and the registry — which
#      runs no TLS and no auth — answers nothing usable.
#   2. The NODE must resolve that name. kubelet performs the image-pull DNS
#      lookup itself, from the node's resolver, not through the pod's
#      `dnsPolicy: ClusterFirst`. A Service name that resolves perfectly inside
#      every pod is invisible to the runtime pulling on the pod's behalf.
#
# Without both, the pull fails with a single message that conflates them and
# reads like a broken registry:
#
#   Failed to pull image "registry.registry.svc:5000/smoke:test":
#     Error response from daemon: Get "https://registry.registry.svc:5000/v2/":
#     dial tcp: lookup registry.registry.svc on 192.168.65.254:53: no such host
#
# Verified 2026-10-01 against this cluster, with each fix isolated:
#
#   before:  Get "https://registry.registry.svc:5000/v2/": no such host
#   +insecure-registry only:
#            Get "http://registry.registry.svc:5000/v2/": no such host
#   +/etc/hosts only:  still `https://` -> no such host
#   +both:             pod Succeeded, prints PULL_SECRET_WORKS
#
# The ClusterIP form works with none of this, because minikube already ships
# `10.96.0.0/12` in its insecure list:
#
#   kubectl run t --image=10.104.212.169:5000/smoke:test ... -> PULL_SECRET_WORKS
#
# That is not the contract, though. A ClusterIP changes whenever the Service is
# recreated, so hard-coding it into Phase 2 pod specs trades a name that works
# for one that breaks silently and at random. Fix the node.
REGISTRY_HOST="registry.registry.svc"
REGISTRY_ADDR="${REGISTRY_HOST}:5000"

failed_addons=()

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v minikube >/dev/null || die "minikube not found — run 'mise install' first"

if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  log "Profile '$PROFILE' exists; starting it"
  # `--insecure-registry` is deliberately NOT passed here, and this comment is
  # the reason. Measured 2026-10-01 on this profile:
  #
  #   $ minikube start -p platform --insecure-registry=registry.registry.svc:5000
  #   ... Done! kubectl is now configured ...
  #   $ minikube ssh -- docker info | grep -A5 'Insecure Registries'
  #     10.96.0.0/12
  #     127.0.0.0/8
  #
  # The flag is accepted and has no effect on an already-created profile: it is
  # only read at node creation, and it is not persisted to the node's config.
  # Believing it worked here is exactly the failure mode this repo keeps
  # hitting — a command that exits 0 taken as proof of the thing it names.
  # The node's runtime is therefore configured explicitly, below, where the
  # result is verified rather than assumed.
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
    --embed-certs=true \
    --insecure-registry="$REGISTRY_ADDR"
fi

# Wait for API server to be ready before enabling addons
# This prevents "connection refused" errors when addons try to apply manifests
log "Waiting for API server to be ready..."
for i in {1..30}; do
  if kubectl --context "$PROFILE" get --raw=/readyz >/dev/null 2>&1; then
    log "API server is ready"
    break
  fi
  if [ $i -eq 30 ]; then
    die "Timed out waiting for API server to be ready"
  fi
  sleep 2
done

# --- Registry reachability from the NODE (Task 8) ---------------------------
#
# Idempotent, and a no-op once done. Skipped before Task 8 deploys the registry
# Service, because there is nothing to point at and the ClusterIP does not exist
# yet; `make deploy-infra` is followed by `make cluster-up` in the documented
# onboarding order, and this is the second step of that pair doing its work.
#
# Both steps VERIFY what they did and warn loudly if they did not. A silent
# no-op here is the worst outcome available: the failure resurfaces as an
# ImagePullBackOff in a Phase 2 service, on a laptop that has been told the
# platform works.
registry_cluster_ip() {
  kubectl --context "$PROFILE" -n registry \
    get svc registry -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true
}

ip="$(registry_cluster_ip)"
if [ -z "$ip" ]; then
  warn "registry Service not found in namespace 'registry' — skipping node registry config."
  warn "Run 'make deploy-infra' first, then 'make cluster-up' again."
else
  # 1. Plain-HTTP registry.
  #
  # The node's dockerd is started by minikube with an explicit
  # `--insecure-registry 10.96.0.0/12` on its command line, and systemd refuses
  # to start dockerd if /etc/docker/daemon.json ALSO sets `insecure-registries`
  # — the two are mutually exclusive. Verified 2026-10-01:
  #
  #   Process: /usr/bin/dockerd ... --insecure-registry 10.96.0.0/12
  #            (code=exited, status=1/FAILURE)
  #   Job for docker.service failed because the control process exited with
  #   error code.
  #
  # So the fix is a systemd drop-in that REPLACES ExecStart with the same
  # command line plus the registry host, not a daemon.json edit. The existing
  # ExecStart is copied verbatim from `systemctl show` rather than
  # reconstructed, so a future minikube that changes the flags is not silently
  # overridden by a stale copy here.
  log "Configuring node container runtime for plain-HTTP $REGISTRY_ADDR"
  current_exec="$(minikube ssh -p "$PROFILE" -- \
    "systemctl show docker --property=ExecStart --value" 2>/dev/null || true)"
  if [ -z "$current_exec" ]; then
    warn "could not read dockerd's ExecStart; skipping insecure-registry config"
    warn "in-cluster pulls by DNS name will fail until this is done by hand"
  elif printf '%s' "$current_exec" | grep -q "$REGISTRY_ADDR"; then
    log "  already configured"
  else
    new_exec="$(printf '%s' "$current_exec" | sed "s| --insecure-registry | --insecure-registry $REGISTRY_ADDR --insecure-registry |")"
    minikube ssh -p "$PROFILE" -- \
      "sudo mkdir -p /etc/systemd/system/docker.service.d &&
       sudo sh -c 'printf \"[Service]\nExecStart=\nExecStart=%s\n\" \"$new_exec\" > /etc/systemd/system/docker.service.d/insecure-registry.conf' &&
       sudo systemctl daemon-reload &&
       sudo systemctl restart docker" >/dev/null 2>&1 ||
      { warn "failed to restart dockerd with the registry as an insecure registry"; warn "in-cluster pulls by DNS name will fail"; }
    if minikube ssh -p "$PROFILE" -- \
      "docker info 2>/dev/null | grep -q '$REGISTRY_ADDR'"; then
      log "  verified: docker info lists $REGISTRY_ADDR"
    else
      warn "dockerd restarted but '$REGISTRY_ADDR' is NOT in its insecure list"
      warn "in-cluster pulls by DNS name will fail"
    fi
  fi

  # 2. Node-side name resolution.
  #
  # kubelet resolves image references from the node, so the Service name must be
  # in the node's /etc/hosts. The entry is rewritten (not appended) each run so
  # a Service recreated at a different ClusterIP is followed rather than shadowed
  # by a stale first match.
  #
  # NOT `sed -i`. Inside the minikube node /etc/hosts is a bind mount, and sed's
  # default in-place strategy writes a temp file and renames it over the target,
  # which cannot be done to a mount point. Verified 2026-10-01:
  #
  #   sed: cannot rename /etc/sedUFWpas: Device or resource busy
  #
  # `grep -v` to a temp file, then `tee` the result back over /etc/hosts, is a
  # truncate-and-write, which a bind mount does allow.
  log "Adding $REGISTRY_HOST -> $ip to the node's /etc/hosts"
  minikube ssh -p "$PROFILE" -- \
    "sudo sh -c 'grep -v \"[[:space:]]$REGISTRY_HOST\([[:space:]]\|\$\)\" /etc/hosts > /tmp/hosts.new; echo \"$ip $REGISTRY_HOST registry\" >> /tmp/hosts.new; tee /etc/hosts < /tmp/hosts.new > /dev/null; rm -f /tmp/hosts.new'" ||
    warn "failed to update the node's /etc/hosts for $REGISTRY_HOST"

  if minikube ssh -p "$PROFILE" -- "getent hosts '$REGISTRY_HOST'" | grep -q "$ip"; then
    log "  verified: node resolves $REGISTRY_HOST -> $ip"
  else
    warn "node does NOT resolve $REGISTRY_HOST to $ip"
    warn "in-cluster pulls by DNS name will fail"
  fi
fi

for addon in "${ADDONS[@]}"; do
  log "Ensuring addon '$addon' enabled"
  # One failing addon must not abort the rest — under `set -e` a hard failure here
  # leaves the remaining addons unasserted, so a re-run after one broken addon
  # silently stops working. Collect failures and report them together at the end.
  # Use --validate=false to skip openapi validation which fails if API server
  # aggregation isn't fully ready yet (even though /readyz returns success).
  if ! minikube addons enable "$addon" -p "$PROFILE" --validate=false >/dev/null; then
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
