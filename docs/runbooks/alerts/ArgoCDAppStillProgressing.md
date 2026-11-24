# ArgoCDAppStillProgressing

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/argocd-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/argocd-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Argo CD has reported the user-facing Application `name` (project `apps`) as
Progressing for an hour: a workload never became Ready. The usual causes are
an image that cannot be pulled (`ImagePullBackOff`, a registry outage), a
pod stuck Pending, or a readiness probe that never passes. Auto-rollback acts
on Degraded only, so nothing automatic fixes it, and while it lasts tuppr's
health gate holds any Talos or Kubernetes upgrade.

## Confirm

```sh
kubectl -n argo get application <name> -o jsonpath='{.status.health.status}{"\n"}'
kubectl -n argo get application <name> -o json |
  jq -r '.status.resources[] | select(.health.status == "Progressing" or .health.status == "Missing") | "\(.kind) \(.namespace)/\(.name): \(.health.message // "")"'
kubectl -n <namespace> get pods -o wide | grep -v -E 'Running|Completed'
```

Expected while it fires: `Progressing`, the workloads that are not Ready,
and their pods in `ImagePullBackOff`, `ErrImagePull`, `Pending` or
`Running` with `0/1` Ready.

## Fix

1. Read the pod: `kubectl -n <namespace> describe pod <pod>`; the Events
   name the cause.
2. Image pull fails: check the registry from the Mac with
   `curl -sI -m 10 https://<registry>/v2/` (expected `401` or `200`). A
   registry outage that lasts: pull the same digest from another registry
   that publishes it (the image path in the manifest, same `@sha256:`),
   open a pull request and merge with `scripts/pr-merge.sh <n>`.
3. Pending: a node or the NAS is down (`HomelabNodeDown`, `HomelabNASDown`):
   fix that first. A PVC that does not attach: [storage.md](../../storage.md).
4. Not Ready after a merge: revert the change on a branch from `origin/main`
   (`git revert <sha>`), open a pull request and merge it once CI is green.

## Resolved when

`status.health.status` is `Healthy` and the alert clears within a few
minutes. A held tuppr upgrade resumes by itself.

## Links

- [ArgoCDAppStillDegraded](ArgoCDAppStillDegraded.md)
- [observability.md: Argo CD alerts](../../observability.md#argo-cd-alerts)
- `https://argo.lilalala.com/applications/argo/<name>`
