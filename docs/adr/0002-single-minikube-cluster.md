# Single minikube cluster

- Status: Accepted
- Date: 2026-09-26

## Context and Problem Statement

Team practice requires Atlantis to run **in-cluster**, as a pod that receives GitHub
webhooks and runs `tofu plan` / `tofu apply` against the cluster it lives in. But the
ecosystem's application workloads also need a Kubernetes cluster to deploy into.

Running two clusters locally is possible on a 16 GB machine, but it doubles the memory
the two control planes consume, and it fragments the mental model: two kubeconfigs, two
sets of namespaces, two ways for a learner to be looking at "the wrong cluster."

The alternative — running Atlantis outside the cluster — is the one this project rules
out explicitly, because the team's practice is that Atlantis *is* an in-cluster
component.

## Decision Drivers

- Atlantis must run in-cluster.
- The machine has 16 GB RAM; a second control plane is affordable but wasteful.
- Learners need one obvious place to look.
- Namespace isolation is sufficient for everything this project hosts.

## Considered Options

- One minikube profile, namespaces for isolation.
- Two minikube profiles: one for Atlantis, one for workloads.
- Atlantis outside the cluster (k3s/systemd on the host).

## Decision Outcome

Chosen option: **one minikube profile named `platform`, docker driver, 8 GB RAM,
namespace isolation instead of cluster isolation**, because

- it satisfies the in-cluster requirement without a second control plane;
- isolation is expressed in the same primitive the ecosystem already teaches
  (Kubernetes namespaces, RBAC, network policies);
- it leaves enough headroom on a 16 GB host for Docker Desktop, the cluster, and a
  dashboard-rendering script to run at once.

The namespaces are fixed by the Makefile's `NAMESPACES` variable:
`argocd`, `atlantis`, `ministack`, `vault`, `monitoring`, `registry`,
`external-secrets`, `platform-system`.

### Positive Consequences

- One `kubectl` context for the entire project; no `-n`-plus-context confusion.
- Blast radius is bounded by namespaces, which is the boundary ArgoCD projects enforce.
- The whole stack is disposable in one command.

### Negative Consequences

- **Shared blast radius locally.** A misapplied manifest in one namespace can take out a
  neighbouring one. This is accepted because the entire stack is disposable: `make
  cluster-down` deletes the profile and all its data, and `make cluster-up` rebuilds it
  from Git.
- No true environment isolation, so staging-like behaviour has to be simulated with
  namespaces and values overrides rather than separate clusters.

## Links

- [ADR-0001: Record architecture decisions](0001-record-architecture-decisions.md)
