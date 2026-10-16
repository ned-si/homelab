# ArgoCDMetricsAbsent

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/argocd-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/argocd-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Prometheus has had no `argocd_app_info` for 15 minutes, so no Argo CD alert
can fire, and auto-rollback, which starts from those alerts, sees nothing.

## Confirm

```sh
q 'up{job="argocd-application-controller-metrics"}'
kubectl -n argo get statefulset argocd-application-controller
kubectl -n argo get servicemonitor argocd-application-controller --show-labels
```

Expected while it fires: no series or `0`; the controller not ready, or the
ServiceMonitor missing its `release` label.

## Fix

1. Controller not ready: `kubectl -n argo logs statefulset/argocd-application-controller --tail=50`.
   Argo CD manages itself; if it cannot sync, fix it with Helm from
   `bootstrap/argocd-values.yaml` ([bootstrap.md](../../bootstrap.md)).
2. ServiceMonitor missing or without `release: kube-prometheus-stack`: the
   metrics settings in `bootstrap/argocd-values.yaml`.

## Resolved when

`q 'count(argocd_app_info)'` returns the Application count; the alert clears.

## Links

- [observability.md: Argo CD alerts](../../observability.md#argo-cd-alerts)
