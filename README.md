# platform-infra

Infrastructure for the platform learning ecosystem: OpenTofu, ArgoCD, Atlantis, Vault,
External Secrets, kube-prometheus-stack, Ministack, and a local registry on minikube.

## Status

| Component | Phase | State | Verified by | Last verified |
|-----------|-------|-------|--------------|---------------|
| Repository + toolchain | 1 | ✅ done | `make help` | 2026-09-26 |
| minikube cluster | 1 | ⬜ todo | `make cluster-up` | — |
| …one row per component… |

## Quick start

```bash
mise trust

# The pinned python 3.12.5 prebuilt artifact predates Python's release
# attestations, so mise's verification rejects it without this.
export MISE_PYTHON_GITHUB_ATTESTATIONS=false
mise install

make cluster-up
make deploy-infra
make port-forwards
make verify        # must print: PHASE 1 VERIFICATION PASSED
```

## Architecture

The design this repo implements is
[`docs/specs/2026-09-23-platform-learning-ecosystem-design.md`](docs/specs/2026-09-23-platform-learning-ecosystem-design.md).
The plan that produced it is
[`docs/plans/2026-09-26-phase1-infrastructure-foundation.md`](docs/plans/2026-09-26-phase1-infrastructure-foundation.md).

Decisions are recorded as ADRs, one per decision, never edited after acceptance
([ADR-0001](docs/adr/0001-record-architecture-decisions.md)):

| ADR | Decision |
|-----|----------|
| [0001](docs/adr/0001-record-architecture-decisions.md) | Record architecture decisions |
| [0002](docs/adr/0002-single-minikube-cluster.md) | Single minikube cluster |
| [0003](docs/adr/0003-opentofu-over-terraform.md) | OpenTofu over Terraform |
| [0004](docs/adr/0004-ministack-over-localstack.md) | Ministack over LocalStack |

## Repository layout

```
platform-infra/
├── .github/
│   ├── workflows/
│   │   ├── ci.yaml                    # tofu fmt/validate, helm lint, actionlint, yamllint
│   │   ├── atlantis-plan.yaml         # PR-only: pings Atlantis, fetches plan comment
│   │   └── atlantis-apply.yaml        # PR-merged: comments `atlantis apply`
│   ├── CODEOWNERS                     # ops/* owned by ops team, tf/* co-owned
│   ├── dependabot.yml
│   └── workflows/README.md
├── .gitignore                         # local-secrets/, .terraform/, *.tfstate
├── .tool-versions                     # pinned versions
├── .env.example                       # GITHUB_ORG/REPO, TUNNEL token, etc.
├── Makefile                           # cluster-up, deploy-infra, port-forwards, verify, cluster-down
├── README.md                          # the maintained status document
├── tofu/
│   ├── versions.tf                    # required_version + required_providers
│   ├── providers.tf                   # helm, kubernetes, random, tls (all configured)
│   ├── main.tf                        # wires every module, in dependency order
│   ├── outputs.tf                     # endpoints, namespaces, ports (consumed by scripts)
│   ├── variables.tf                   # every tunable input, typed
│   ├── modules/
│   │   ├── namespace/                 # one namespace, labelled
│   │   ├── minikube_addons/           # registry/ingress/metrics-server addons
│   │   ├── argocd/                    # helm_release + bootstrap Application
│   │   ├── atlantis/                  # helm_release + repo creds + ngrok-less tunnel job
│   │   ├── ministack/                 # helm_release or raw manifest + queue bootstrap Job
│   │   ├── vault/                     # helm_release + dev-mode config + policy
│   │   ├── external_secrets/          # helm_release + ClusterSecretStore
│   │   ├── prometheus/                # kube-prometheus-stack helm_release
│   │   └── registry/                  # registry deployment + image pull secret
│   └── environments/
│       └── local/
│           ├── backend.hcl           # tfvars for the local profile
│           └── overrides.tf          # local-only tweaks (dev-mode Vault, small replicas)
├── argocd/                            # GitOps application definitions (ArgoCD reads these)
│   ├── projects/
│   │   ├── platform-system.yaml
│   │   ├── dev.yaml
│   │   ├── staging.yaml
│   │   └── prod.yaml
│   └── applications/
│       ├── platform-system.yaml       # self-manages the platform components
│       └── kustomization.yaml
├── kubernetes/
│   └── platform-system/               # Kustomize base — what ArgoCD actually syncs
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       └── platform/                  # one k8s manifest per component, minimal
│           ├── ministack.yaml
│           ├── vault.yaml
│           ├── external-secrets.yaml
│           ├── prometheus.yaml
│           └── registry.yaml
├── helm/
│   └── values/                        # Helm values files consumed by helm_release
│       ├── argocd.yaml
│       ├── atlantis.yaml
│       ├── vault.yaml
│       ├── prometheus.yaml
│       └── ministack.yaml
├── dashboards/                        # Grafana dashboard JSON (Frontend 1)
│   ├── platform-overview.json
│   ├── go-service-golden-signals.json
│   └── slo-dashboard.json
├── docs/
│   ├── adr/
│   │   ├── 0001-record-architecture-decisions.md
│   │   ├── 0002-single-minikube-cluster.md
│   │   ├── 0003-opentofu-over-terraform.md
│   │   └── 0004-ministack-over-localstack.md
│   ├── runbooks/
│   │   ├── cluster-reset.md
│   │   ├── atlantis-webhook-debug.md
│   │   ├── argocd-out-of-sync.md
│   │   └── vault-unseal.md
│   └── onboarding.md                  # <30 min new-dev path (Frontend 2)
├── scripts/
│   ├── setup-minikube.sh
│   ├── port-forwards.sh
│   ├── seed-vault.sh
│   ├── bootstrap-ministack-queues.sh
│   ├── verify-phase1.sh               # the phase gate
│   └── smoke-atlantis-webhook.sh      # (Frontend 2)
└── .terraform.lock.hcl                # committed — provider versions are part of the contract
```

`docs/specs/` and `docs/plans/` are copies of the umbrella `fullstack/` originals, so this
repo is self-contained: someone reading only `platform-infra` finds the design and the
plan that produced it.

## Make targets

```
  help               Show this help
  cluster-up         Create/start the minikube cluster with pinned addons
  cluster-down       Delete the minikube cluster (destructive)
  deploy-infra       Apply all infrastructure with OpenTofu
  destroy-infra      Destroy all infrastructure managed by OpenTofu (destructive)
  port-forwards      Forward ArgoCD, Grafana, Vault, Ministack, registry to localhost
  verify             Run the Phase 1 success-criteria gate
  fmt                Format and validate OpenTofu + Helm + YAML
```

## Troubleshooting

Runbooks live in [`docs/runbooks/`](docs/runbooks/): `cluster-reset.md`,
`atlantis-webhook-debug.md`, `argocd-out-of-sync.md`, `vault-unseal.md`.

### Toolchain pins

`.tool-versions` pins every tool the scripts and Makefile depend on. Run
`mise trust && mise install` after cloning, and run the tools through
`mise exec -- <tool>` (or activate mise in your shell) so the pinned version is the one
on `PATH` — macOS ships kubectl 1.36, Helm 4, jq 1.8, and **GNU Make 3.81**, and Make
3.81 breaks the heredoc recipes these targets rely on.

Four pins could not be expressed in `.tool-versions` and are installed another way. The
**versions are exactly as planned**; only the install mechanism differs, because the
current mise registry renamed or dropped those keys:

| Planned | Installed as | Why |
|---------|--------------|-----|
| `tofu 1.7.0` | `opentofu 1.7.0` in `.tool-versions` | mise renamed the registry key `tofu` → `opentofu`. Same binary, same version. |
| `docker 27.1.0` | `docker-cli 27.1.0` in `.tool-versions` | mise renamed the registry key `docker` → `docker-cli`. Same binary, same version. |
| `mise 2024.10.0` | installed via `curl https://mise.run \| sh` | mise cannot manage itself; the brief states mise is a prerequisite, not a `.tool-versions` entry. Installed: 2026.9.14. |
| `atlantis 0.28.0` | official release binary, `~/.local/bin/atlantis` | mise has no `atlantis` registry entry at any version. Installed 0.28.0 from the runatlantis GitHub release. |

`python 3.12.5` also needs one extra env var, because the 3.12.5 prebuilt artifact
predates Python's release attestations and mise's verification fails on it:

```bash
export MISE_PYTHON_GITHUB_ATTESTATIONS=false
```

Everything else installs with a plain `mise install`. Verify the whole set with:

```bash
mise exec -- tofu version        # OpenTofu v1.7.0
mise exec -- kubectl version --client  # v1.30.2
mise exec -- helm version --short # v3.15.3
mise exec -- make --version      # GNU Make 4.4.1
mise exec -- aws --version       # aws-cli/2.17.0
```

If any of these print something other than the pinned version, the toolchain has drifted —
fix that before trusting a failure elsewhere.
