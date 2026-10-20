# Runbook — GitOps AKS platform

The normal workflow is: change Git, open a PR, merge. There is no `kubectl` in
it. This document covers the cases where that is not enough, and the one case
where you are allowed to break it.

## Break-glass: the only sanctioned kubectl exception

**Allowed only for:** a stuck finalizer that prevents a namespace or Application
from being deleted, and only after Argo has failed to resolve it for 15 minutes.

```bash
# 1. state the incident, out loud, to whoever is on call
# 2. record the time and the resource in the incident ticket
kubectl patch <resource> <name> -n <ns> --type=merge -p '{"metadata":{"finalizers":null}}'
# 3. record the time again
```

Afterwards, **the same change must be expressed in Git** (for example, removing
the finalizer from the manifest, or documenting why the resource is orphaned) or
the next sync will reintroduce the problem. A break-glass action that is not
followed by a commit is a drift source you have created yourself.

## Stuck sync

```
Application is OutOfSync and not converging
```

1. **Look at the diff first.** The UI shows what Argo wants to apply.
   ```bash
   argocd app diff api
   ```
2. **Common causes, in order of frequency:**

| Symptom | Cause | Fix |
|---|---|---|
| `ComparisonError: ... failed to load` | kustomize overlay does not render | run `kustomize build apps/overlays/prod/api` locally; CI would have caught it, so something merged without CI |
| `OutOfSync` forever on a Secret | external-secrets cannot reach Key Vault | check the ClusterSecretStore and the federated credential |
| `Sync failed: admission webhook denied` | Kyverno rejected the manifest | read the message; fix the manifest, do **not** disable the policy |
| `Health: Degraded` on a Rollout | canary analysis failed | Argo Rollouts has already rolled back; check the analysis run |
| `resources-finalizer` blocking delete | finalizer on a resource that no longer exists | see break-glass above |

3. **Force a refresh** before concluding anything:
   ```bash
   argocd app get api --refresh
   ```
4. **If a bad commit is the cause, revert it.** That is the fix, not
   `kubectl delete`:
   ```bash
   git revert <sha> && git push
   ```

## Emergency rollback

```bash
# the right way
git revert <sha> && git push       # Argo syncs within 3 minutes

# when 3 minutes is too long (active incident, customer impact)
argocd app rollback api 42         # to history revision 42
```

A rollback via the CLI is recorded in Argo's audit trail but **not** in Git, so
the next sync will re-apply whatever `main` says. If you roll back this way, you
must follow up with a revert commit within the hour, or the rollback will be
undone silently.

## A workload is crash-looping after a merge

1. The Rollout (prod) has already stopped at 10% and rolled back — verify:
   ```bash
   kubectl -n api get rollout api-app -o jsonpath='{.status.canary.currentStep}'
   ```
2. In dev (plain Deployment) there is no canary. Fix forward or revert:
   ```bash
   git revert <sha> && git push
   ```
3. Do **not** `kubectl set image` — it will be reverted by selfHeal in under
   3 minutes, usually mid-incident, which makes the outage longer.

## Kyverno is blocking a legitimate deployment

The policy is right and the manifest is wrong, in that order, until proven
otherwise. If a policy genuinely needs an exception:

1. Add a `PolicyException` **in Git**, scoped to one namespace and one resource,
   with an expiry annotation.
2. The exception is reviewed like any other change.
3. Never set `validationFailureAction: Audit` on a cluster policy to unblock
   yourself — that disables the control for everything.

## ArgoCD itself is broken

ArgoCD is a platform component managed by the platform ApplicationSet. If it is
unhealthy:

```bash
kubectl -n argocd get pods
kubectl -n argocd logs deploy/argocd-server --tail=100
```

If ArgoCD cannot reconcile at all, workloads keep running (nothing is
self-healing, but nothing is being deleted either). Restoring ArgoCD is the
priority; while it is down, **the cluster is frozen** — do not make manual
changes, because they will be reverted the moment Argo recovers.

## Scheduled checks

| Check | Cadence | Owner |
|---|---|---|
| `./scripts/verify-gitops.sh prod` | daily | platform |
| `./scripts/drift-check.sh prod` | every 15 min (CI) | platform |
| ArgoCD version review | monthly | platform |
| Kyverno policy review | quarterly | security + platform |
| Break-glass rehearsal | quarterly | platform |

## What this runbook deliberately does not cover

**How to kubectl into a pod to debug.** Use `kubectl exec` through the
break-glass procedure, or better: add ephemeral containers via a reviewed
manifest. Ad-hoc exec is how changes escape Git.
