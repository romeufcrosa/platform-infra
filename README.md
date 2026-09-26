# platform-infra

Infrastructure for the platform learning ecosystem: OpenTofu, ArgoCD, Atlantis, Vault,
External Secrets, kube-prometheus-stack, Ministack, and a local registry on minikube.

## Status

| Component | Phase | State | Verified by | Last verified |
|-----------|-------|-------|--------------|---------------|
| Repository + toolchain | 1 | ✅ done | `make help` | 2026-09-26 |
| minikube cluster | 1 | ⬜ todo | `make cluster-up` | — |
| OpenTofu root module | 1 | ✅ done | `tofu validate` | 2026-09-26 |
| Namespaces + External Secrets Operator | 1 | ⬜ todo | `kubectl get ns` | — |
| CI + Kustomize + AppProjects | 1 | ⬜ todo | `make validate` | — |
| ArgoCD | 1 | ⬜ todo | `argocd app list` | — |
| Ministack (SQS/S3/Secrets Manager) | 1 | ⬜ todo | `aws sqs list-queues` | — |
| kube-prometheus-stack + registry | 1 | ⬜ todo | `curl :9090/api/v1/targets` | — |
| Vault + secret contract | 1 | ⬜ todo | `kubectl -n dev get secret` | — |
| Atlantis + GitHub webhook | 1 | ⬜ todo | Atlantis plan comment on a PR | — |
| Grafana dashboards | 1 | ⬜ todo | `curl :3000/api/search` | — |
| Onboarding + `make verify` | 1 | ⬜ todo | clean rebuild in < 30 min | — |

> Every component gets a real row rather than a `…one row per component…` placeholder.
> A placeholder is the worst of both worlds: it reads as a table to a skimmer while
> telling a human nothing, and a reviewer cannot tell whether the missing rows were
> deliberate or forgotten. Task 12 flips each row to ✅ with its real verification
> command and date.

## Quick start

```bash
# 1. Toolchain. `mise install` puts the tools in mise's shims, but on macOS it
#    does NOT shadow /usr/bin/make, so `make` would still resolve to Apple's
#    BSD Make 3.81 — and GNU Make 4 is a hard requirement (the heredoc recipes
#    in later tasks need it). Either activate mise in your shell...
mise trust && mise install
eval "$(mise activate bash)"     # or: mise activate  (zsh)
make --version                   # must report GNU Make 4.4.1

# ...or skip the shell setup and call make through mise explicitly:
mise exec -- make cluster-up
```

```bash
make cluster-up
make deploy-infra
make port-forwards
make verify        # must print: PHASE 1 VERIFICATION PASSED
```

> Quick start keeps `make` because the whole point of `.tool-versions` is that a
> shell which has mise active resolves `make` to the pinned 4.4.1. The two
> `mise exec --` lines are the escape hatch for a shell where it does not —
> documented rather than assumed, because a reader who hits BSD Make 3.81 on
> their first `make deploy-infra` will otherwise conclude the pin is broken.

## Cluster lifecycle

`make cluster-up` runs [`scripts/setup-minikube.sh`](scripts/setup-minikube.sh), which is
the single entry point for the local cluster. It is **idempotent**: an existing, running
profile is started and left otherwise untouched, and an absent one is created. Re-running
it is always safe — it never recreates a cluster you already have.

On creation it builds the profile named by `MINIKUBE_PROFILE` (default `platform`, which
is also the contract in the Makefile), pinned to Kubernetes `v1.30.2` on the Docker
driver, then enables two addons: `ingress` and `metrics-server`. Every downstream
component runs `kubectl`/`helm`/`tofu` against kubeconfig context `platform`.

> **The `registry` addon is deliberately absent, not forgotten.** minikube's `registry`
> addon deploys a `registry-proxy` DaemonSet pinned to
> `gcr.io/k8s-minikube/kube-registry-proxy:0.0.6`, and that image has been **deleted from
> gcr.io** — the tag list comes back empty and the manifest returns HTTP 404, and the
> DaemonSet pins a `@sha256:` digest as well as a tag, so neither a retag nor a pull of
> any other tag helps. The addon has no configuration options either, so there is nothing
> to override. This is upstream breakage, reproducible beyond the `minikube 1.34.0` pin
> ([minikube#21452](https://github.com/kubernetes/minikube/issues/21452) shows the same
> class of failure on 1.36.0, closed `lifecycle/rotten`).
>
> Nothing in Phase 1 needs it. **The registry this project uses comes from
> `tofu/modules/registry/`** — a Helm-installed registry in the `registry` namespace,
> with `registry_url` and a pull secret in the platform namespaces as the contract. The
> minikube addon was always redundant with that design; it is now both redundant and
> broken. The `registry` namespace is created by OpenTofu in Task 4 and the registry
> workload arrives in Task 8. **Please do not readd the addon** — it will fail, and the
> failure is the confusing kind that only surfaces as an unrelated `ImagePullBackOff`.

Each tunable is an environment override, so a machine that needs a different shape does
not need a fork:

| Variable | Default | Notes |
|----------|---------|-------|
| `MINIKUBE_PROFILE` | `platform` | Also the kubeconfig context name. |
| `K8S_VERSION` | `v1.30.2` | Matches the pinned `kubectl 1.30.2`. |
| `MINIKUBE_CPUS` | `4` | |
| `MINIKUBE_MEMORY` | `7800mb` | See the Docker memory note below. |
| `MINIKUBE_DISK` | `50g` | |

The addon set is also recorded declaratively in
[`tofu/modules/minikube_addons/`](tofu/modules/minikube_addons/). The addons themselves
are applied by the script — minikube addons are a cluster-lifecycle concern that OpenTofu
has no resource for — so the module does not manage them.

> **What that module's `check` block can and cannot do.** It compares the `addons`
> list the root passes in against a literal recorded in the module. **Both sides
> are literals in this repository.** minikube's addon state is not exposed
> through the Kubernetes API, so there is no `data` source that could read the
> truth, and the check **cannot detect an addon that was disabled on the running
> cluster.** It can only fail if someone edits one of the two literals and forgets
> the other. Its value is caller-wiring: it guarantees the root keeps passing the
> documented baseline, so changing the call site has to be deliberate.
>
> To check the cluster's *actual* addon state, run
> `minikube addons list -p platform` and compare — `scripts/setup-minikube.sh` is
> the only thing in the repo that can observe it. Note also that an OpenTofu
> `check` block reports a failure as a **warning**; the plan still exits `0`, so
> treat the warning as the signal rather than the exit code.

## The OpenTofu root module

`tofu/` is the spine of the repo. Every component from the namespace foundation
onward is attached to it as a `module` block, and `make deploy-infra` runs it.
`make deploy-infra` must be the only thing that creates infrastructure —
nothing here is ever applied by hand with `kubectl apply`.

State lives at `tofu/environments/local/terraform.tfstate` via a `local` backend
whose single block lives in [`tofu/backend.tf`](tofu/backend.tf).
`tofu/environments/local/backend.hcl` is a hand-maintained reference copy of
those settings, not something OpenTofu reads.

**`tofu/environments/local/` is a real module, and `overrides.tf` is live.**
It is called by the root as `module "local" { source = "./environments/local" }`.
`locals` do not cross a module boundary, so `overrides.tf` keeps its `locals`
block and `outputs.tf` alongside it re-exports each override as a module output;
the root collects them into `local.local_overrides` and surfaces them through the
`local_overrides` output.

This matters because the **Phase 1 exit criterion** is "open a PR editing
`tofu/environments/local/overrides.tf` and read the Atlantis plan comment".
Editing an override produces a visible, non-empty `tofu plan` diff — that is what
the criterion is checking. Were the file inert, the edit would produce an empty
plan and the one manual proof that the webhook, tunnel, PAT, repo lock and
`dir: tofu` all work together would silently prove nothing.

Three places declare the same key set, and they must agree:

| File | Declares |
|------|----------|
| `tofu/environments/local/overrides.tf` | the values themselves, in a `locals` block |
| `tofu/environments/local/outputs.tf` | one `output` per local, re-exporting them |
| `tofu/main.tf` | `local.local_overrides`, which reads every one of them |

[`scripts/check-local-overrides.sh`](scripts/check-local-overrides.sh) enforces
that agreement, and runs as part of `make fmt`. It fails if a local has no
output, if an output is not consumed by `local_overrides`, or if a `type =`
argument reappears on an output (a Terraform 1.3+ feature that hard-errors on
OpenTofu 1.7 — see below). A key added to one file and forgotten in another is
exactly the declared-but-not-wired defect this repo has produced three times, and
this check is the guard against a fourth.

**`tofu/main.tf` owns the namespace list.** `local.platform_namespaces` — the
eight platform namespaces plus `dev`, `staging`, `prod`, eleven in total — is the
single source of truth. The namespace module's `for_each` and the `namespaces`
output both derive from it, and [ADR-0002](docs/adr/0002-single-minikube-cluster.md)
makes it authoritative. The Makefile's `NAMESPACES` is a human-readable mirror
that nothing consumes. OpenTofu owns all eleven; every `helm_release` passes
`create_namespace = false`, so no chart and no tool races another for the same
object.

### Two HCL details that look like errors and are not

Both of these contradict what a Terraform author would expect, so they are worth
stating plainly. Both are verified against the pinned **OpenTofu 1.7.0**.

**The block is spelled `terraform {`, not `tofu {`.** The rule that this repo uses
OpenTofu and never Terraform is about the **binary you invoke** (`tofu`, never
`terraform`), not the HCL block name. OpenTofu did not accept a `tofu` block
until 1.8.0; on 1.7.0 it is a hard error:

```
Error: Unsupported block type
  on backend.tf line 1:
   1: tofu {
Blocks of type "tofu" are not expected here.
```

**`output` blocks have no `type` argument.** `type = map(string)` on an output is
a Terraform 1.3+ feature. OpenTofu's `output` block accepts only `value`,
`description`, `sensitive`, `ephemeral`, `depends_on`, and `deprecated`, so
declaring `type` fails `tofu validate`:

```
Error: Unsupported argument
  on outputs.tf line 3, in output "endpoints":
   3:   type        = map(string)
An argument named "type" is not expected here.
```

Values are still type-checked where they are consumed, so the `endpoints` map and
`namespaces` list keep the contract later tasks rely on. `variable` blocks *do*
support `type` — that one is unchanged.

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
├── Makefile                           # help, cluster-up, cluster-down, deploy-infra, destroy-infra, port-forwards, verify, fmt
├── README.md                          # the maintained status document
├── tofu/
│   ├── versions.tf                    # required_version + required_providers
│   ├── providers.tf                   # helm, kubernetes, random, tls, local (all configured)
│   ├── backend.tf                     # the root module's single `local` backend block
│   ├── main.tf                        # wires every module, in dependency order
│   ├── outputs.tf                     # endpoints, namespaces (consumed by scripts)
│   ├── variables.tf                   # every tunable input, typed
│   ├── .terraform.lock.hcl            # committed — provider versions are part of the contract
│   ├── modules/
│   │   ├── namespace/                 # one namespace, labelled
│   │   ├── minikube_addons/           # ingress/metrics-server addons (records the baseline)
│   │   ├── argocd/                    # helm_release + bootstrap Application
│   │   ├── atlantis/                  # helm_release + repo creds + ngrok-less tunnel job
│   │   ├── ministack/                 # helm_release or raw manifest + queue bootstrap Job
│   │   ├── vault/                     # helm_release + dev-mode config + policy
│   │   ├── external_secrets/          # helm_release + ClusterSecretStore
│   │   ├── prometheus/                # kube-prometheus-stack helm_release
│   │   └── registry/                  # registry deployment + image pull secret
│   └── environments/
│       └── local/                     # a REAL module: module "local" in tofu/main.tf
│           ├── backend.hcl           # reference copy of the backend settings (not loaded)
│           ├── overrides.tf          # LIVE local-only tweaks (dev-mode Vault, small replicas)
│           └── outputs.tf            # re-exports each override; locals do not cross modules
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
│   ├── check-local-overrides.sh       # guard: overrides.tf stays wired (runs in make fmt)
│   ├── port-forwards.sh
│   ├── seed-vault.sh
│   ├── bootstrap-ministack-queues.sh
│   ├── verify-phase1.sh               # the phase gate
│   └── smoke-atlantis-webhook.sh      # (Frontend 2)
```

> The lock file lives at **`tofu/.terraform.lock.hcl`**, not the repository root.
> `tofu -chdir=tofu init` writes it beside the module it initialises, and it is
> committed so the provider versions in the plan are the versions every machine
> and CI run resolves.

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
  fmt                Format and validate OpenTofu config and the local-overrides guard
```

## Troubleshooting

Runbooks live in [`docs/runbooks/`](docs/runbooks/): `cluster-reset.md`,
`atlantis-webhook-debug.md`, `argocd-out-of-sync.md`, `vault-unseal.md`.

### `Docker Desktop has only NNNNMB memory but you specified MMMMMB`

minikube refuses to give the node more memory than the Docker engine has in total, and a
stock **Docker Desktop is allocated 8GB, which reports as ~7834MB**. That is why the
default is `7800mb` and not a rounder `8192mb` — a round 8GB is unreachable on a default
Docker Desktop install, and the failure is a hard refusal, not a slow boot. Raise the
Docker Desktop memory limit (Settings → Resources) and then override:

```bash
MINIKUBE_MEMORY=10240mb make cluster-up
```

### If you see `registry-proxy` in `ImagePullBackOff`

You have re-enabled the minikube `registry` addon. Don't. It is dropped from the baseline
deliberately, and it cannot be made to work.

The addon deploys two pieces: the registry itself (`docker.io/registry:2.8.3`) and a
`registry-proxy` DaemonSet whose image is `gcr.io/k8s-minikube/kube-registry-proxy:0.0.6`.
That image has been **deleted from gcr.io** — the tag list returns `{"tags":[]}` and the
manifest returns HTTP 404 — so the DaemonSet cannot pull, and `minikube addons enable
registry` dies with `MK_ADDON_ENABLE: ... context deadline exceeded`. The registry pod is
fine; only the proxy is missing, which is why the symptom looks unrelated to a registry.

There is no fix at the `minikube 1.34.0` pin. Every `kube-registry-proxy` tag *and* the
digest the addon pins are gone from gcr.io; the addon exposes no image override
(`minikube addons configure registry` reports no options); and because the DaemonSet pins
a `@sha256:` digest, a tag bump would not help either. See
[minikube#21452](https://github.com/kubernetes/minikube/issues/21452) — closed
`lifecycle/rotten`, and it reproduces on newer releases too.

The registry this project actually uses is the Helm release in
`tofu/modules/registry/`, not this addon. If you need a registry, use that. The
`ingress` and `metrics-server` addons are unaffected.

### Toolchain pins

`.tool-versions` pins every tool the scripts and Makefile depend on. Run
`mise trust && mise install` after cloning, and run the tools through
`mise exec -- <tool>` (or activate mise in your shell) so the pinned version is the one
on `PATH` — macOS ships kubectl 1.36, Helm 4, and **GNU Make 3.81**, and Make
3.81 breaks the heredoc recipes these targets rely on. (`jq` is absent from macOS
entirely, which is why it is pinned here rather than assumed.)

Two pins are written under a different mise key. The **versions are exactly as planned**;
only the registry key differs, because the current mise registry renamed them:

| Planned | Written as | Why |
|---------|-----------|-----|
| `tofu 1.7.0` | `opentofu 1.7.0` | mise renamed the registry key `tofu` → `opentofu`. Same binary, same version. |
| `docker 27.1.0` | `docker-cli 27.1.0` | mise renamed the registry key `docker` → `docker-cli`. Same binary, same version. |

`mise` itself is a prerequisite, not a `.tool-versions` entry — it cannot manage itself.
Install it with `curl https://mise.run | sh` (currently 2026.9.14).

`docker-cli 27.1.0` pins the **client only**. The daemon comes from Docker Desktop and
reports its own, different version. That mismatch is expected, not toolchain drift.

Not pinned: Atlantis. The Phase 1 work deploys the Atlantis *server* via its Helm chart,
whose `0.28.0` version is pinned in the module — no Phase 1 script invokes the Atlantis
CLI, so a CLI pin would be theatre.

Everything installs with a plain `mise install`. Verify the set with:

```bash
mise exec -- tofu version        # OpenTofu v1.7.0
mise exec -- kubectl version --client  # v1.30.2
mise exec -- helm version --short # v3.15.3
mise exec -- make --version      # GNU Make 4.4.1
mise exec -- aws --version       # aws-cli/2.17.0
```

If any of these print something other than the pinned version, the toolchain has drifted —
fix that before trusting a failure elsewhere.
