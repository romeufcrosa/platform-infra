# OpenTofu over Terraform

- Status: Accepted
- Date: 2026-09-26

## Context and Problem Statement

HashiCorp changed the license of Terraform (BUSL for versions after 1.5.x), and the team
standardized on OpenTofu, the Linux Foundation fork of Terraform, after that change.
OpenTofu is a drop-in replacement for the module/provider ecosystem the project already
depends on, and Atlantis supports it natively.

The risk in any IaC decision like this is drift: a mixture of `terraform` and `tofu`
invocations across local machines, CI, and the Atlantis pod produces state-lock
conflicts and subtle provider differences that are very hard to diagnose.

## Decision Drivers

- The team has already standardized on OpenTofu.
- Atlantis must be able to plan and apply these modules unattended.
- One IaC binary, everywhere, including CI.
- The project should be teachable: learners meet the tool the team actually uses.

## Considered Options

- Terraform (upstream HashiCorp).
- OpenTofu (the Linux Foundation fork).
- A different provisioner entirely (Pulumi, Kustomize-only).

## Decision Outcome

Chosen option: **OpenTofu**, because

- it is the tool the team standardized on post-BSL change;
- Atlantis supports it natively, so no custom wrapper is needed to drive it;
- the module ecosystem and provider registry are compatible, so existing knowledge
  transfers unchanged.

Concretely, this decision binds the following, with no exceptions:

- source files use the `.tf` extension;
- the binary invoked is `tofu`, never `terraform`;
- **no `terraform` invocations appear anywhere, including CI** — CI workflows, Makefile
  targets, and the Atlantis pod all call `tofu`.

### Positive Consequences

- `tofu init` handles provider registry transparently; no credential juggling for
  public providers.
- Lock file semantics are unchanged, so `.terraform.lock.hcl` remains committed and
  continues to pin provider versions as part of the contract.
- Consistent behaviour across laptop, CI, and Atlantis.

### Negative Consequences

- Tooling that hard-codes the `terraform` binary name needs a wrapper. This is a known,
  accepted cost and is the reason "no `terraform` invocations anywhere" is written into
  the decision rather than left to convention.
- Learners who already know Terraform must learn one rename.

## Links

- [ADR-0001: Record architecture decisions](0001-record-architecture-decisions.md)
