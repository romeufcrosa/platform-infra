# Ministack over LocalStack

- Status: Accepted
- Date: 2026-09-26

## Context and Problem Statement

The local stack needs an AWS API emulator: SQS for the queue-based exercise, S3 for
object storage, and Secrets Manager as the backing store for the Vault / External
Secrets path.

LocalStack's free tier no longer covers the services this project needs, and its
licensing changed, which makes it a poor fit for a learning project whose entire point
is that a contributor can run the whole thing locally at no cost. Ministack is fully
free and covers the three services actually required.

The downside of any emulator is fidelity, and that has to be stated up front rather than
discovered by a learner three hours into an exercise.

## Decision Drivers

- The stack must be free, with no paid tier gating a required service.
- Only SQS, S3, and Secrets Manager are needed.
- Learners must not be taught to expect AWS behaviour the emulator does not provide.

## Considered Options

- LocalStack (free tier, current licensing).
- Ministack.
- Real AWS, or a cloud free tier.

## Decision Outcome

Chosen option: **Ministack for SQS, S3, and Secrets Manager locally**, because

- it is fully free, with no licensing change able to break the project later;
- it covers the three services the exercises use, which is the whole requirement;
- it runs as a pod in the `ministack` namespace, consistent with ADR-0002's single-cluster
  decision.

Because AWS SDK compatibility is good but **not total**, services under test must be
written against a documented subset — queue operations, not every API. This is a binding
constraint on how the exercises are written, not a footnote:

- code written against Ministack targets the documented subset explicitly;
- `docs/runbooks/` records gaps as they are found, so a discovered gap becomes documented
  knowledge rather than a surprise.

### Positive Consequences

- Zero licensing risk, zero cost, and a stack a contributor can run offline.
- The emulator is disposable with the rest of the cluster.

### Negative Consequences

- A service that works against Ministack may still behave differently against real AWS.
  This is accepted and mitigated by constraining test code to the documented subset.
- Any future need for a service outside {SQS, S3, Secrets Manager} requires a new
  decision, not a configuration tweak.

## Links

- [ADR-0001: Record architecture decisions](0001-record-architecture-decisions.md)
- [ADR-0002: Single minikube cluster](0002-single-minikube-cluster.md)
