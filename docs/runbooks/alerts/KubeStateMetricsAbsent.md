# KubeStateMetricsAbsent

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Prometheus has had no `kube_pod_info` for 15 minutes: kube-state-metrics is
not scraped. About half the rules (pods, jobs, CronJobs, PVCs, Deployments,
nodes, the outage alerts) evaluate over nothing and report nothing wrong.

## Confirm

```sh
q 'up{job="kube-state-metrics"}'
kubectl -n monitoring get deploy kube-prometheus-stack-kube-state-metrics
kubectl -n monitoring get servicemonitor -l app.kubernetes.io/name=kube-state-metrics --show-labels
```

Expected while it fires: no series or `0`; a Deployment not available, or
its ServiceMonitor missing.

## Fix

1. Pod not running: `kubectl -n monitoring describe pod -l app.kubernetes.io/name=kube-state-metrics`
   and its logs. An `OOMKilled` needs a higher limit in
   `platform/kube-prometheus-stack/values.yaml`.
2. ServiceMonitor gone: the Application `kube-prometheus-stack` is not
   synced or Degraded; read its status in Argo CD.

## Resolved when

`q 'up{job="kube-state-metrics"}'` returns `1`; the alert clears.

## Links

- [observability.md](../../observability.md)
