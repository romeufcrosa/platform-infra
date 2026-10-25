# Onboarding Guide

## What this is
Four repositories, one cluster:
- **platform-infra** (this repo): OpenTofu, ArgoCD, Atlantis, Vault, External Secrets, kube-prometheus-stack, Ministack, and local registry
- **platform-services**: Go and Node services that consume the platform contracts
- **platform-dashboard**: Next.js dashboard for service observability
- **platform-docs**: This documentation site

The split exists to separate infrastructure concerns from service development, allowing each team to move at their own pace while maintaining clear contracts.

## Prerequisites
- Docker Desktop running (minimum 8GB RAM allocated to Docker)
- 8GB RAM free for the minikube VM
- GitHub account
- Install these tools via Homebrew:
  ```bash
  brew install minikube kubectl helm opentofu cloudflared openssl
  ```
- Install and configure `mise` (version manager):
  ```bash
  brew install mise
  echo 'eval "$(mise activate bash)"' >> ~/.bash_profile  # or ~/.zshrc for zsh
  ```

## Ten-minute path
Follow these steps exactly to reach a working platform in under 30 minutes:

```bash
git clone https://github.com/<you>/platform-infra.git && cd platform-infra
mise trust && mise install
eval "$(mise activate bash)"        # zsh: mise activate
make --version                      # MUST say GNU Make 4.4.1, not 3.81
make cluster-up
make deploy-infra
make port-forwards &     # leave running in this terminal
./scripts/seed-vault.sh
make verify
```

The `mise activate` line is not optional boilerplate. On macOS `mise install` writes shims but does not shadow `/usr/bin/make`, so without it `make` is Apple's BSD Make 3.81 and the later heredoc recipes fail with errors that read like repository bugs. Add the activation to your shell profile in step 2, and keep `mise exec -- make <target>` documented as the per-command fallback.

## Where things are
| Service | URL | Credentials | Description |
|---------|-----|-------------|-------------|
| ArgoCD | http://localhost:8080 | `local-secrets/argocd-admin-password` | GitOps dashboard showing Application sync status |
| Grafana | http://localhost:3000 | admin / `local-secrets/grafana-admin-password` | Observability dashboard panel |
| Prometheus | http://localhost:9090 | None | Time series database for metrics |
| Vault | http://localhost:8200 | `local-secrets/vault-root-token` | Secret management system |
| Ministack | http://localhost:4566 | None | Local AWS emulator (SQS, S3, Secrets Manager) |
| Registry | http://localhost:5000 | None | Local container registry for images |
| Atlantis | http://localhost:8080 | None | Pull request-driven IaC automation |

## The four things to try in your first hour
1. **Open the Grafana `platform-overview` dashboard and find the `dev` namespace memory panel.** Change a Pod's memory limit in `kubernetes/platform-system/platform/`, commit, and watch ArgoCD sync it. This is the GitOps loop in its shortest form.
2. **Create a queue message:** `aws --endpoint-url http://localhost:4566 sqs send-message --queue-url $(aws --endpoint-url http://localhost:4566 sqs get-queue-url --queue-name order-events --query QueueUrl --output text) --message-body '{"type":"order.created"}'`, then read it back. This is the contract Phase 2 builds on.
3. **Change a Vault secret:** `./scripts/seed-vault.sh`, then `kubectl -n dev get secret go-service-credentials -o yaml | grep database-url` before and after. Watch the Operator sync. This is the secrets loop.
4. **Open a PR that edits `tofu/environments/local/overrides.tf` and read the Atlantis plan comment.** This is the IaC review loop.

## Where to change what
| Intent | File to modify |
|--------|----------------|
| Adding a namespace | `tofu/main.tf` (add to `local.platform_namespaces` list) |
| Adding a component | Create new OpenTofu module in `tofu/modules/` and reference in `tofu/main.tf` |
| Adding a dashboard | Add JSON file to `dashboards/` and run `make dashboards` |
| Adding a secret path | Add to `tofu/modules/vault/secrets.tf` and run `./scripts/seed-vault.sh` |
| Pinning a new chart version | Update version in corresponding `tofu/modules/*/main.tf` |

## Runbooks index
- `docs/runbooks/argocd-out-of-sync.md` - ArgoCD Application stuck in degraded/syncing state
- `docs/runbooks/atlantis-webhook-debug.md` - Atlantis webhook not receiving/processing events
- `docs/runbooks/vault-secrets.md` - External Secrets Operator not updating Kubernetes secrets
- `docs/runbooks/ministack-api-coverage.md` - Expected SQS queues not appearing in Ministack
- `docs/runbooks/backup-restore.md` - Kubernetes pods failing to pull from local registry
- `docs/runbooks/grafana-dashboard-blank.md` - Grafana dashboard showing no data
- `docs/runbooks/pod-crashlooping.md` - Pods in CrashLoopBackOff or ImagePullBackOff state

## Troubleshooting the top five
1. **Pods not starting** → `kubectl get pods -A` to see crashlooping pods, then `kubectl logs -n <namespace> <pod>` for details
2. **ArgoCD out of sync** → `argocd app get platform-system` to see sync status and health
3. **Secrets not appearing in dev namespace** → `kubectl get clustersecretstore vault` to check External Secrets Operator readiness
4. **Ministack queues not responding** → `aws --endpoint-url http://localhost:4566 sqs list-queues` to verify queue existence
5. **Registry pull failing** → `kubectl describe pod <pod>` to see ImagePullBackOff events and check registry reachability