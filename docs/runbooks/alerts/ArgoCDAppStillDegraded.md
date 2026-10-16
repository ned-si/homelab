# ArgoCDAppStillDegraded

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/argocd-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/argocd-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Argo CD has reported the Application `name` as Degraded for 30 minutes and
nothing automatic fixed it: auto-rollback refused (not the newest merge, a
second revert in a row, an excluded app), the outage guard skipped it, or the
revert itself failed.

## Confirm

```sh
kubectl -n argo get application <name> -o jsonpath='{.status.health.status}{"\n"}'
kubectl -n argo get application <name> -o json |
  jq -r '.status.resources[] | select(.health.status == "Degraded" or .health.status == "Missing") | "\(.kind) \(.namespace)/\(.name): \(.health.message // "")"'
gh run list --workflow auto-rollback.yaml --limit 5
gh pr list --label auto-rollback --state all --limit 5
```

Expected while it fires: `Degraded`, and the objects that are not healthy.
The Homelab / Automation dashboard shows the rollback run and its decision.

## Fix

1. Read the unhealthy object: `kubectl -n <namespace> describe <kind> <object>`
   and, for a workload, `kubectl -n <namespace> logs deploy/<object> --tail=100`.
2. A node or the NAS is down (`HomelabNodeDown`, `HomelabNASDown`): fix that
   first; the app follows.
3. The newest change to the app broke it and was not reverted: revert it on a
   branch from `origin/main` (`git revert <sha>`), open a pull request and
   merge with `scripts/pr-merge.sh <n>` once CI is green.
4. An auto-rollback pull request is open but not merged: read its CI failure
   and fix or rerun it (`gh run rerun --failed <run-id>`).
5. Not a deploy (expired credential, full volume, upstream outage): fix the
   cause through git; the page of the matching alert has the steps.

## Resolved when

`status.health.status` is `Healthy` and the alert clears within a few
minutes. An outage that spent 25% or more of an app's monthly budget needs a
postmortem ([sre.md](../../sre.md#postmortems)).

## Links

- [decisions.md: Automatic rollback](../../decisions.md#automatic-rollback)
- [observability.md: Argo CD alerts](../../observability.md#argo-cd-alerts)
- `https://argo.lilalala.com/applications/argo/<name>`
