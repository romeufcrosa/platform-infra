# examples/

Manifests that are **not applied by anything** and are **not synced by ArgoCD**.
They are the worked examples Phase 2 copies from, kept reviewable in a pull
request rather than reconstructed from memory once a service exists.

Nothing here is deployed. There is no kustomization.yaml in this directory and
there is no OpenTofu resource that reads any file in it. If you find one, that
is a bug — an example that something applies is a component, and it belongs
under `kubernetes/` with an owner.

## `external-secrets/go-service-credentials.yaml`

The full Vault → External Secrets → Kubernetes Secret path for one service. It
is the canonical copy: `tofu/modules/vault/external-secrets-example.yaml` used
to hold a second one that no tool read, and it is gone, because two copies of a
manifest drift and the unread one drifts silently.

Apply it by hand to exercise the path locally:

```bash
kubectl --context platform apply -f examples/external-secrets/go-service-credentials.yaml
```

It needs the OpenTofu-owned `ClusterSecretStore/vault` and a seeded Vault
(`./scripts/seed-vault.sh`). Its `remoteRef.key` / `remoteRef.property` pairs
are checked against the seed script by `scripts/check-secret-contract.sh`.

## Where these go in Phase 2

Into the **service's own repository**, under an AppProject namespaced for that
service. Not into `kubernetes/platform-system/`.

That is not tidiness. The `platform-system` AppProject lists eight platform
namespaces in `spec.destinations` and deliberately omits `dev`, `staging` and
`prod`, so that no platform component can be a single mistyped path away from
writing into production — see the comment on
`tofu/modules/argocd/bootstrap-appproject.yaml.tftpl`. ArgoCD validates a
resource's namespace against the AppProject, not against the Application's
destination, so an ExternalSecret for a service namespace cannot be synced by
the platform Application at all.

The ownership argument is the same one from the other direction: a service's
credentials manifest belongs to whoever operates the service. Putting it in the
platform base would mean the platform team owned every service's secrets.
