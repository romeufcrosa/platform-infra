#!/usr/bin/env bash
# Phase 1 success-criteria gate.
# Exits 0 and prints "PHASE 1 VERIFICATION PASSED" only if every check below
# passes. Every check is a cluster or endpoint observation, not a state-file
# inspection: the point is to prove the running system, not the IaC's
# opinion of it.
set -uo pipefail

CTX="${MINIKUBE_PROFILE:-platform}"
FAILED=0
PASSED=0

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }

check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    green "  PASS  $desc"; PASSED=$((PASSED+1))
  else
    red   "  FAIL  $desc"; FAILED=$((FAILED+1))
  fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --- 0. prerequisites -------------------------------------------------------
section "Toolchain"
for t in minikube kubectl helm tofu cloudflared docker; do
  check "$t is installed" command -v "$t"
done

# --- 1. cluster -------------------------------------------------------------
section "Cluster"
# Pipe safety: every `<producer> | grep -q` assertion below is wrapped in
# `bash -c`, and a bare `bash -c` does NOT inherit this script's `pipefail`.
# That is what makes them safe. Under an active pipefail, `grep -q` exits at the
# first match, the producer takes SIGPIPE (141), and pipefail promotes that to
# non-zero — so a *passing* match reports as FAIL (verified on minikube 1.34.0:
# PIPESTATUS=141 0). If you ever add an assertion that pipes WITHOUT the
# `bash -c` wrapper, or add `set -o pipefail` to the wrapper, it will invert.
# The robust form is capture-into-a-variable, then grep the captured text.
check "kubeconfig context '$CTX' exists" bash -c "kubectl config get-contexts -o name | grep -qx '$CTX'"

# Addon assertions anchor the name column. An unanchored `grep -q "$addon.*enabled"`
# over `minikube addons list` matches any row merely STARTING with the addon name,
# and that list really contains `ingress-dns` as a separate addon — so with
# `ingress` off and `ingress-dns` on, an unanchored check false-passes and this
# gate is silently defeated. A phase gate that can pass in the wrong state is
# worse than no gate. Carried from the Task 2 finding.
addons="$(minikube -p "$CTX" addons list 2>/dev/null || true)"
addon_enabled() { grep -qE "^\|[[:space:]]*$1[[:space:]]*\|.*enabled" <<<"$2"; }
for a in ingress metrics-server; do
  check "addon '$a' enabled" addon_enabled "$a" "$addons"
done
check "API server is reachable" kubectl --context "$CTX" get --raw /readyz
check "all nodes are Ready" bash -c \
  "[ \"\$(kubectl --context '$CTX' get nodes --no-headers | grep -cv ' Ready ')\" -eq 0 ]"

# --- 2. namespaces ----------------------------------------------------------
section "Namespaces"
for ns in argocd atlantis ministack vault monitoring registry external-secrets platform-system dev staging prod; do
  check "namespace '$ns' exists" kubectl --context "$CTX" get ns "$ns"
done

# --- 3. platform components -------------------------------------------------
section "Platform components"
check "ArgoCD server is Available" bash -c \
  "kubectl --context '$CTX' -n argocd wait --for=condition=Available deploy/argocd-server --timeout=60s"
check "Atlantis server is Available" bash -c \
  "READY=\$(kubectl --context '$CTX' -n atlantis get statefulset atlantis -o jsonpath='{.status.readyReplicas}' 2>/dev/null) && TOTAL=\$(kubectl --context '$CTX' -n atlantis get statefulset atlantis -o jsonpath='{.status.replicas}' 2>/dev/null) && [ \"\$READY\" = \"\$TOTAL\" ] && [ \"\$READY\" -gt 0 ]"
check "Vault is Available" bash -c \
  "READY=\$(kubectl --context '$CTX' -n vault get statefulset vault -o jsonpath='{.status.readyReplicas}' 2>/dev/null) && TOTAL=\$(kubectl --context '$CTX' -n vault get statefulset vault -o jsonpath='{.status.replicas}' 2>/dev/null) && [ \"\$READY\" = \"\$TOTAL\" ] && [ \"\$READY\" -gt 0 ]"
check "Ministack is Available" bash -c \
  "kubectl --context '$CTX' -n ministack wait --for=condition=Available deploy/ministack --timeout=60s"
check "Prometheus is Available" bash -c \
  "READY=\$(kubectl --context '$CTX' -n monitoring get statefulset prometheus-prometheus-prometheus -o jsonpath='{.status.readyReplicas}' 2>/dev/null) && TOTAL=\$(kubectl --context '$CTX' -n monitoring get statefulset prometheus-prometheus-prometheus -o jsonpath='{.status.replicas}' 2>/dev/null) && [ \"\$READY\" = \"\$TOTAL\" ] && [ \"\$READY\" -gt 0 ]"
check "Grafana is Available" bash -c \
  "kubectl --context '$CTX' -n monitoring wait --for=condition=Available deploy/grafana --timeout=60s"
check "External Secrets Operator is Available" bash -c \
  "kubectl --context '$CTX' -n external-secrets wait --for=condition=Available deploy/external-secrets --timeout=60s"

# --- 4. no crashlooping anywhere -------------------------------------------
section "Pod health"
BADPODS=$(kubectl --context "$CTX" get pods -A --no-headers \
  | grep -Ev 'Completed|evicted' \
  | grep -E 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Error|Pending' || true)
if [ -z "$BADPODS" ]; then
  green "  PASS  no pods in CrashLoopBackOff / ImagePullBackOff / Error / Pending"
  PASSED=$((PASSED+1))
else
  red "  FAIL  unhealthy pods:"; echo "$BADPODS" | sed 's/^/        /'
  FAILED=$((FAILED+1))
fi

# --- 5. GitOps --------------------------------------------------------------
section "GitOps"
check "ArgoCD Application 'platform-system' exists" \
  kubectl --context "$CTX" -n argocd get application platform-system
check "ArgoCD Application is Synced" bash -c \
  "kubectl --context '$CTX' -n argocd get application platform-system -o jsonpath='{.status.sync.status}' | grep -q Synced"
check "ArgoCD Application is Healthy" bash -c \
  "kubectl --context '$CTX' -n argocd get application platform-system -o jsonpath='{.status.health.status}' | grep -q Healthy"
check "all 5 AppProjects exist" bash -c \
  "[ \"\$(kubectl --context '$CTX' -n argocd get appprojects -o name | wc -l | tr -d ' ')\" -eq 5 ]"

# --- 6. secrets -------------------------------------------------------------
section "Secrets"
check "ClusterSecretStore/vault is Ready" bash -c \
  "kubectl --context '$CTX' get clustersecretstore vault -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
check "ExternalSecret synced a Kubernetes Secret" \
  kubectl --context "$CTX" -n dev get secret go-service-credentials
check "admin password files exist with mode 0600" bash -c \
  "[ \"\$(stat -f '%Lp' local-secrets/argocd-admin-password 2>/dev/null || stat -c '%a' local-secrets/argocd-admin-password)\" = '600' ]"
check "no secret file is tracked by git" bash -c \
  "! git ls-files --error-unmatch local-secrets 2>/dev/null"

# --- 7. local AWS -----------------------------------------------------------
section "Local AWS (Ministack)"
AWS_ENV="AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1"
check "Ministack health endpoint responds" curl -sf http://localhost:4566/_ministack/health
for q in order-events order-events-dlq platform-notifications; do
  check "queue '$q' exists" bash -c "$AWS_ENV mise exec -- aws --endpoint-url http://localhost:4566 sqs get-queue-url --queue-name \"$q\" >/dev/null"
done
check "send/receive round-trip works" bash -c '
  MISE_AWS="mise exec -- env AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 aws --endpoint-url http://localhost:4566 sqs"
  URL=$($MISE_AWS get-queue-url --queue-name order-events --query QueueUrl --output text)
  RID=$($MISE_AWS send-message --queue-url "$URL" --message-body "{\"probe\":\"verify\"}" --query MessageId --output text) || exit 1
  [ -n "$RID" ] || exit 1
  sleep 1
  RECEIPT=$($MISE_AWS receive-message --queue-url "$URL" --max-number-of-messages 1 2>/dev/null | python3 -c "import sys, json; d=json.load(sys.stdin); print(d[\"Messages\"][0][\"ReceiptHandle\"])")
  [ -n "$RECEIPT" ] || exit 1
  $MISE_AWS delete-message --queue-url "$URL" --receipt-handle "$RECEIPT" >/dev/null'

# --- 8. registry ------------------------------------------------------------
section "Container registry"
check "registry reachable on localhost:5000" curl -sf http://localhost:5000/v2/
check "image pull secret exists in every namespace" bash -c '
  for ns in argocd atlantis ministack vault monitoring registry external-secrets platform-system; do
    kubectl --context "'"$CTX"'" -n "$ns" get secret registry-pull-secret >/dev/null 2>&1 || exit 1
  done'

# --- 9. observability -------------------------------------------------------
section "Observability"
check "Prometheus has active scrape targets" bash -c \
  "[ \"\$(curl -sf 'http://localhost:9090/api/v1/targets?state=active' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[\"data\"][\"activeTargets\"]))')\" -gt 0 ]"
check "Prometheus can answer a real query" bash -c \
  "curl -sf --get --data-urlencode 'query=up' http://localhost:9090/api/v1/query | grep -q '\"result\"'"
check "3 Grafana dashboards provisioned" bash -c \
  "[ \"\$(curl -sf -u \"admin:\$(cat local-secrets/grafana-admin-password)\" 'http://localhost:3000/api/search?type=dash-db' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')\" -ge 3 ]"

# --- 10. Atlantis -----------------------------------------------------------
section "Atlantis"
check "Atlantis health endpoint responds" curl -sf http://localhost:8080/healthz
check "Atlantis has locked the repo" bash -c \
  "kubectl --context '$CTX' -n atlantis exec deploy/atlantis -- \
     sh -c 'test -d /home/atlantis/.atlantis/repos' || true"

# --- summary ----------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASSED" "$FAILED"
if [ "$FAILED" -eq 0 ]; then
  green "PHASE 1 VERIFICATION PASSED"
  exit 0
fi
red "PHASE 1 VERIFICATION FAILED"
cat <<'EOF'

Not every check is equally load-bearing. If you are chasing failures, work in
this order:
  1. Pod health        - almost every other failure is downstream of this
  2. ArgoCD Synced     - if this fails, GitOps is not the source of truth yet
  3. ClusterSecretStore - Vault may be up while the Operator cannot reach it
  4. Ministack queues   - endpoint reachable but queues not bootstrapped
See docs/runbooks/ for the symptom-first runbooks.
EOF
exit 1