# Record Architecture Decisions

- Status: Accepted
- Date: 2026-09-26

## Context and Problem Statement

The platform learning ecosystem spans four repositories, and the decisions taken in
`platform-infra` — one cluster, one IaC tool, one local AWS emulator — are load-bearing
for all of them. Those decisions are expensive to revisit: changing the IaC tool or
splitting the cluster late in the project would ripple through every repo, every
runbook, and every piece of training material built on top of them.

Without a written record, the *reasoning* behind those decisions lives only in the head
of whoever made them, and the reasoning is the part a new contributor actually needs.

## Decision Drivers

- Decisions must be recoverable without archaeology through commit history.
- A contributor must be able to see *why*, not just *what*.
- The record must be append-only: a reversed decision is as informative as the original.

## Considered Options

- Record decisions in commit messages only.
- Record decisions in a wiki.
- Record decisions as ADRs in this repository.

## Decision Outcome

Chosen option: **record decisions as ADRs in this repository**, because

- one file per decision, so a change of mind produces a new numbered file rather than
  an edit that destroys the original reasoning;
- they live next to the code they govern, so they are versioned and reviewed in the
  same pull request as the change itself;
- they are plain Markdown, readable without any tooling.

### Positive Consequences

- Every later task can cite a decision instead of re-arguing it.
- New contributors read four short files and understand the constraints of the project.
- Reverting a decision is explicit and traceable.

### Negative Consequences

- Writing an ADR is overhead on every significant decision, including small ones.
- Stale ADRs are possible if a decision is quietly abandoned; the status field
  (`Proposed` / `Accepted` / `Superseded by ADR-NNNN`) is the mitigation.

## Links

- [ADR-0002: Single minikube cluster](0002-single-minikube-cluster.md)
- [ADR-0003: OpenTofu over Terraform](0003-opentofu-over-terraform.md)
- [ADR-0004: Ministack over LocalStack](0004-ministack-over-localstack.md)
