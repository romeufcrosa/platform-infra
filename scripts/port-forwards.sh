#!/usr/bin/env bash
# Port-forward every platform workload to localhost.
#
# SKELETON (Task 3). No workloads are deployed yet, so the FORWARDS table below
# is intentionally empty and the script exits 0 having done nothing. Tasks 8
# and 10 append entries; the reading of `tofu/outputs.tf`'s `endpoints` map is
# what makes the list authoritative rather than hand-maintained prose.
#
# Ports come from .env.example (ARGOCD_PORT, GRAFANA_PORT, VAULT_PORT,
# MINISTACK_PORT, REGISTRY_PORT, ATLANTIS_PORT). Every port is overridable so a
# machine with a busy port does not need a fork.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_CONTEXT="${KUBE_CONTEXT:-platform}"

# Read overrides from .env if present. `set -a` so the assignments export and
# reach the kubectl invocations. A missing .env is normal, not an error — the
# defaults below are the documented values.
if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_ROOT/.env"
  set +a
fi

ARGOCD_PORT="${ARGOCD_PORT:-8081}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
VAULT_PORT="${VAULT_PORT:-8200}"
MINISTACK_PORT="${MINISTACK_PORT:-4566}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
ATLANTIS_PORT="${ATLANTIS_PORT:-8080}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"

# Forward table. Each row is "<namespace>/<service> <local>:<remote> <label>".
# Rows are READ FIRST into an array and only then acted on, so this script's
# own filtering never pipes a producer into a consumer that can exit early
# (`producer | grep -q` under `set -o pipefail` reports a *passing* match as
# failure: grep -q exits at first match, the producer takes SIGPIPE 141, and
# pipefail promotes that to the script's exit status). Capturing first and
# matching against the captured text avoids the whole class of bug.
FORWARDS=(
  # "argocd/argocd-server        8081:443   argocd"          # Task 6
  # "monitoring/grafana         3000:80    grafana"         # Task 8
  # "monitoring/prometheus-server 9090:9090 prometheus"     # Task 8
  # "registry/registry          5000:5000  registry"        # Task 8
  # "ministack/ministack        4566:4566  ministack"       # Task 7
  # "vault/vault                8200:8200  vault"           # Task 9
  # "atlantis/atlantis          8080:8080  atlantis"        # Task 10
)

# Anchored column test, not substring. `minikube addons list`-style tabular
# output contains rows that merely *start with* a name we care about
# (`ingress-dns` vs `ingress`), so an unanchored `grep -q "ingress"` false-passes.
# `grep -x` pins the match to a whole line.
#
# The match is fed by a HERESTRING, not a pipe. Under `set -o pipefail`,
# `<producer> | grep -q ...` reports a genuine match as FAILURE: grep -q exits
# at the first match, the producer takes SIGPIPE (141) while it still has
# output queued, and pipefail promotes that to the pipeline's status. Measured
# on this host: `seq 500000 | grep -q 1` -> 141, but `seq 500000 | grep -q
# 500000` -> 0, because a match on the *last* line lets the producer finish
# first and the bug hides. A herestring is a temp file, so there is no producer
# to kill and the race cannot occur at any input size. Capturing to a variable
# first and grepping that is the other safe form; this repo uses both.
context_is_ready() {
  local contexts
  # Capture first; never pipe kubectl into grep -q.
  contexts="$(kubectl config get-contexts -o name 2>/dev/null || true)"
  if grep -qx "$KUBE_CONTEXT" <<<"$contexts"; then
    return 0
  fi
  printf 'ERROR: kubeconfig context %q not found. Run `make cluster-up` first.\n' \
    "$KUBE_CONTEXT" >&2
  return 1
}

if [ "${#FORWARDS[@]}" -eq 0 ]; then
  printf 'port-forwards: no forwards defined yet (skeleton, Task 3).\n'
  printf 'Nothing is deployed until `make deploy-infra` has run.\n'
  exit 0
fi

context_is_ready

pids=()
for row in "${FORWARDS[@]}"; do
  # shellcheck disable=SC2086
  set -- $row
  target="$1"; mapping="$2"; label="$3"
  printf 'forwarding %-12s %s -> localhost:%s\n' "$label" "$target" "$mapping"
  kubectl --context "$KUBE_CONTEXT" -n "${target%%/*}" \
    port-forward "svc/${target##*/}" "$mapping" &
  pids+=($!)
done

# Forwarding is a long-running foreground job, not something to race to the end.
# Trap so Ctrl-C reaps the children instead of orphaning them.
cleanup() {
  printf '\nstopping port-forwards...\n'
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# `wait` returns the exit status of the last job; a killed child makes that
# non-zero, which under `set -e` would kill the script on the way out.
wait || true
