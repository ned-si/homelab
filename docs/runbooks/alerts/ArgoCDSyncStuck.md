# ArgoCDSyncStuck

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/argocd-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/argocd-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

A sync of the Application `name` failed in the last 6 hours and it has been
OutOfSync for 30 minutes since: the merge never deployed and no revert
replaced it. The cluster still runs the previous revision.

## Confirm

```sh
kubectl -n argo get application <name> -o jsonpath='{.status.sync.status} {.status.operationState.phase}{"\n"}{.status.operationState.message}{"\n"}'
kubectl -n argo get application <name> -o json |
  jq -r '.status.operationState.syncResult.resources[]? | select(.status != "Synced") | "\(.kind) \(.namespace)/\(.name): \(.message)"'
```

Expected while it fires: `OutOfSync Failed` (or `Error`) and the objects the
API server refused, with its message.

## Fix

1. Read the message. Usual causes: an immutable field changed (a Job's
   template, a StatefulSet's volumeClaimTemplates, a PVC's storageClassName),
   a CRD the object needs is not installed yet, an admission webhook refused
   it, or a Secret the render references does not exist.
2. Fix it in git on a branch from `origin/main`, or revert the change that
   broke the sync (`git revert <sha>`), then `scripts/pr-merge.sh <n>` on
   green CI. Argo CD retries on its own after the merge.
3. An immutable object: delete it by hand only if it holds no data (a Job, a
   Deployment), then let Argo CD recreate it:
   `kubectl -n <namespace> delete <kind> <object>`. Never delete a PVC or a
   CNPG Cluster this way.
4. Ask Argo CD to compare again at once:
   `kubectl -n argo annotate application <name> argocd.argoproj.io/refresh=hard --overwrite`.

## Resolved when

`status.sync.status` is `Synced` and the alert clears.

## Links

- [observability.md: Argo CD alerts](../../observability.md#argo-cd-alerts)
- [decisions.md: No prune where a deletion is an outage](../../decisions.md#no-prune-where-a-deletion-is-an-outage)
- `https://argo.lilalala.com/applications/argo/<name>`
