# Runbook: ArgoCD out of sync

ArgoCD is the GitOps control plane: every manifest under
`kubernetes/platform-system/` reaches the cluster through the one
`platform-system` Application. This runbook is organised as
**symptom → cause → fix**, because that is the order you meet them in.

Before anything else, orient yourself:

```bash
kubectl --context platform -n argocd get application platform-system
kubectl --context platform -n argocd get pods
tofu -chdir=tofu plan -detailed-exitcode; echo "plan exit=$?"
```

`plan exit=0` and a healthy Application is the state this platform is supposed
to be in. If those two disagree with each other, that is the first clue — see
the ownership note below.

---

## 1. `OutOfSync` with no visible diff

**Symptom**

```bash
kubectl --context platform -n argocd get application platform-system
# NAME             STATUS   HEALTHY
# platform-system  OutOfSync Synced
```

`argocd app diff platform-system` prints nothing, or prints a diff that
disappears when you refresh. A hard refresh (`argocd app get --hard-refresh`)
sometimes clears it and sometimes does not.

**Cause**

Two owners for one object. The most common instance in this repo is the
`platform-system` **Application itself**: it is created by OpenTofu
(`module.argocd.kubernetes_manifest.bootstrap_application`) and its committed
copy lives at `argocd/applications/platform-system.yaml`. The two are rendered
from the same `templatefile()`, so they cannot disagree in content — but if
anyone hand-edits the committed YAML, they will, and `local_file` will
overwrite the edit on the next apply.

The same shape applies to the eleven namespaces. `tofu/main.tf`'s
`module.namespaces` owns every one of them, and four of them
(`platform-system`, `dev`, `staging`, `prod`) are *also* declared inside
`kubernetes/platform-system/`, which the Application syncs. The
`ignoreDifferences` block in the bootstrap Application exists precisely for
this: it suppresses the three labels OpenTofu writes and ArgoCD would otherwise
try to reconcile.

**Fix**

Pick one owner per object, and never both. In this repo:

| Object | Owner |
| --- | --- |
| All eleven namespaces | OpenTofu (`module.namespaces`) |
| The `platform-system` Application | OpenTofu (`kubernetes_manifest`) |
| Everything in `kubernetes/platform-system/` | ArgoCD |

If the Application shows `OutOfSync` with no diff, check that the committed
`argocd/applications/platform-system.yaml` still matches what the module would
render. The cheapest check is to re-apply and see whether the file changes:

```bash
tofu -chdir=tofu apply -auto-approve -input=false
git diff --stat argocd/applications/platform-system.yaml
```

A non-empty diff there means someone edited the generated file. Revert it — the
`.tftpl` is the source.

A related symptom: a namespace stuck in `OutOfSync` with a diff on
`platform.environment`. That is `kubernetes/platform-system/namespace.yaml`
declaring `dev`/`staging`/`prod` while `local.common_labels` in `tofu/main.tf`
sets the environment label to `var.environment` (`local`). The
`/metadata/labels/platform~1environment` jsonPointer in the Application's
`ignoreDifferences` hides it. If that pointer is missing, the diff is real and
will never resolve on its own.

---

## 2. `ComparisonError`

**Symptom**

```bash
kubectl --context platform -n argocd get application platform-system
# NAME             STATUS   HEALTHY
# platform-system  ComparisonError Unknown
```

`argocd app get platform-system` names the repository URL in the error, e.g.
`repository not found`, `authentication required`, or `x509: certificate signed
by unknown authority`.

**Cause**

ArgoCD cannot reach the repo named in `spec.source.repoURL`. The registration
lives in the `platform-infra-repo` Secret that `module.argocd` creates:

```bash
kubectl --context platform -n argocd get secret platform-infra-repo \
  -o jsonpath='{.data.type}'; echo
kubectl --context platform -n argocd get secret platform-infra-repo \
  -o jsonpath='{.data.url}'; echo
```

The usual causes, in order of likelihood:

1. **A private repo with no credentials.** `var.github_pat` defaults to `""`,
   so the Secret is written with an empty `password` and ArgoCD tries an
   anonymous clone and is refused.
2. **URL mismatch.** The Secret's `url` and the Application's
   `spec.source.repoURL` are both rendered from `var.platform_infra_repo_url`,
   so they normally agree. If a stale Secret predates a change to that
   variable, they will not. `tofu apply` reconciles this; a Secret created
   outside OpenTofu will not be.

**Fix**

Set the PAT and re-apply. It is a `sensitive` variable, so put it in a gitignored
`tofu/environments/local/*.auto.tfvars` — never on the command line, which lands
it in shell history:

```hcl
# tofu/environments/local/local.auto.tfvars
github_pat = "ghp_..."
```

```bash
tofu -chdir=tofu apply -auto-approve -input=false
```

If the URL itself is wrong, fix `var.platform_infra_repo_url` in
`tofu/variables.tf` — it is used twice on purpose (the repo Secret and the
Atlantis lock in Task 10), so there is one place to change it.

---

## 3. `Progressing` forever

**Symptom**

```bash
kubectl --context platform -n argocd get application platform-system
# NAME             STATUS       HEALTHY
# platform-system  Progressing  Progressing
```

It stays `Progressing` past a few minutes and `argocd app get` shows an
operation that has not finished.

**Cause**

Something the Application is trying to apply is not becoming ready. ArgoCD
reports the symptom; the Pod is where the cause is. `Progressing` on a sync that
never settles is almost always a Pod that never passes readiness — the usual
suspects in this platform are an External Secrets `ClusterSecretStore` waiting
on a Vault that Task 9 has not installed yet, or a resource referring to a CRD
that the CRDs list in `tofu/modules/external_secrets/outputs.tf` does not
enumerate.

**Fix**

```bash
argocd app get platform-system --show-operation
kubectl --context platform -n platform-system get pods
kubectl --context platform -n platform-system describe pod <failing-pod>
```

Read the Events and the container's last log lines. The `describe` output names
the failing probe or the unschedulable reason far more often than the
ArgoCD status does.

Also check that ArgoCD itself is healthy, because an unhealthy controller
reports every Application as `Progressing`:

```bash
kubectl --context platform -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl --context platform -n argocd get deploy
```

---

## 4. Hard `Failed` right after an ArgoCD upgrade

**Symptom**

```bash
kubectl --context platform -n argocd get application platform-system
# NAME             STATUS   HEALTHY
# platform-system  Failed    Unknown
```

It appears within a minute or two of a `helm upgrade` / `tofu apply` that
bumped the chart, and the pod logs show a `Failed` operation with a
deserialization or field-validation error.

**Cause**

CRD version skew. The `argoproj.io` CRDs are installed by the chart
(`crds.install: true`), and the CRD's **stored** version can be newer than the
version the newly-installed controller binary understands — or the reverse,
when a controller is rolled back below the CRD it was installed with. The
manifest is then rejected by the API server and the operation fails hard rather
than degrading.

This repo pins `chart = "6.7.18"` and `global.image.tag: v2.10.9` together
precisely so the controller and the CRDs move as a pair. A chart bump that does
not move the image tag with it is the realistic way to hit this.

**Fix**

Check the two versions against each other, then reconcile:

```bash
helm --context platform -n argocd list
helm --context platform -n argocd get manifest argocd \
  | grep -A3 'kind: CustomResourceDefinition' | head -20
kubectl --context platform get crd applications.argoproj.io -o jsonpath='{.spec.versions[*].name}'; echo
```

The `spec.versions[*].name` list must contain the version the running controller
expects. If it does not, the fix is to move the pin back to a pair that agrees —
do not delete the CRD by hand, because `crds.keep: true` exists so that CRDs
survive an uninstall precisely to avoid this kind of data loss.

The failure to read out of a version skew is worth stating plainly: the
`Failed` status names a field, not a cause, and the field is usually a
symptom of the mismatch rather than a mistake in the manifest.

---

## Related: the admin password

The admin password is written to `local-secrets/argocd-admin-password`
(mode 0600, gitignored) and its bcrypt hash to
`local-secrets/argocd-admin-password.bcrypt`. The hash is what the chart
stores in `argocd-secret`; the plaintext is what you type at the login prompt.
Both are read back from those files on every subsequent run, so a re-apply does
not invalidate the password you already have.

```bash
PW="$(cat local-secrets/argocd-admin-password)"
kubectl --context platform -n argocd port-forward svc/argocd-server 8081:443 &
argocd login localhost:8081 --username admin --password "$PW" --insecure --grpc-web
```

The chart is configured with `server.insecure: true` so that port-forward
works over plain HTTP. That is safe for a laptop-only cluster and is **not**
safe for anything reachable from a network — if you ever expose ArgoCD, that
flag is the first thing to revisit.

## Related: first apply on a fresh cluster

`kubernetes_manifest` resolves `Application` against the live API at **plan**
time, so the very first `tofu apply` on a cluster without the CRD fails in the
plan with `no matches for kind "Application" in group "argoproj.io"` before any
apply-time ordering can help. Install the chart first:

```bash
make bootstrap-argocd   # tofu apply -target=module.argocd.helm_release.argocd
tofu -chdir=tofu apply -auto-approve -input=false
```

`make deploy-infra` already runs both in order. See
`tofu/modules/argocd/main.tf` for why this cannot be solved inside the module.

## Related: the ServiceMonitor is absent

That is correct until Task 8. `server.metrics.serviceMonitor.enabled` is
explicitly `false` in `helm/values/argocd.yaml` because the chart's
ServiceMonitor template is gated on the `monitoring.coreos.com/v1` CRD existing
at render time, and kube-prometheus-stack does not exist yet. Task 8 flips it to
true through `var.enable_service_monitor` after installing the CRD. An
ArgoCD ServiceMonitor that is still missing after Task 8 lands means the toggle
was not flipped — check `tofu output endpoints` and the `helm --context platform
-n argocd get manifest argocd` output for `kind: ServiceMonitor`.
