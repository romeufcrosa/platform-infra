# Runbook: reset the local cluster

## When to use this

Use this when the cluster's state has been corrupted by an experiment — for
example a half-applied Helm release, a namespace stuck in `Terminating`, CRDs
that were edited by hand, or `tofu apply` failing in a way that left the
OpenTofu state and the cluster disagreeing. A reset is the fastest reliable fix
and it is cheap, because nothing here is real.

> **Warning: this destroys ALL local state, including the Vault data and any
> images you pushed to the local registry.** There is no backup and no undo.

## Steps

```bash
# 1. Delete the cluster and all its data (prompts for confirmation).
make cluster-down

# 2. Recreate the cluster with the pinned addons.
make cluster-up

# 3. Re-apply all infrastructure with OpenTofu.
tofu -chdir=tofu apply -auto-approve

# 4. Verify the Phase 1 success criteria.
make verify
```

## Notes

- `make cluster-down` runs `minikube delete -p platform`. It is the only
  supported way to reset; do not reach for `minikube stop` (a stopped cluster
  keeps the corrupted state) and do not disable the `ingress` or
  `metrics-server` addons — Tasks 2 and 3 assert them.
- Step 2 comes from `scripts/setup-minikube.sh`, which enables the pinned
  addons. Skipping it leaves the cluster without ingress or metrics-server and
  `tofu plan` will report the Task 2 drift.
- Step 3 re-applies from `tofu/main.tf`. The OpenTofu state lives in
  `tofu/environments/local/terraform.tfstate` on disk and is *not* deleted by a
  cluster reset — so a state that is out of sync with reality will re-create
  the same broken state. If step 3 fails with a "resource already exists" or
  "object has changed" style error, destroy the OpenTofu state and re-apply:

  ```bash
  tofu -chdir=tofu destroy -auto-approve   # prompts; will fail on missing resources
  rm -f tofu/environments/local/terraform.tfstate
  tofu -chdir=tofu init -input=false
  tofu -chdir=tofu apply -auto-approve
  ```
- Vault (Task 9) runs in dev mode, so its data lives only in the cluster's
  container filesystem. A reset unseals nothing: the next `tofu apply` brings
  up a fresh empty Vault, and any ExternalSecret that referenced it will be
  unresolvable until the backing secrets are re-created.
- The local registry (Task 8) runs in-cluster too, so pushed images are gone
  after a reset. Re-push anything the manifests reference by tag.

## See also

- `docs/adr/0002-single-minikube-cluster.md` — why there is exactly one cluster
  and it is safe to destroy.
- `make help` — the full target list.
