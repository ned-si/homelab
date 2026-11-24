# TupprOperatorAbsent

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/tuppr-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/tuppr-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Prometheus has had no tuppr metrics for 30 minutes. No upgrade runs and no
upgrade alert can fire.

## Confirm

```sh
kubectl -n system-upgrade get deploy,pods -l app.kubernetes.io/name=tuppr
kubectl -n system-upgrade logs deploy/tuppr --tail=50
kubectl -n system-upgrade get servicemonitor
q 'up{job="tuppr-metrics-service"}'
```

Expected while it fires: the Deployment at 0 ready, or `up` at `0` or
absent.

## Fix

1. Pod not running: read its events and log. An image or admission error
   is fixed in a pull request on the `tuppr` Application.
2. Pod running but no metrics: check the ServiceMonitor and the metrics
   Service (`platform/tuppr/values.yaml`, `monitoring.serviceMonitor`).

## Resolved when

`q 'tuppr_build_info'` returns a series; the alert clears.

## Links

- [talos-cheatsheet.md: Talos and Kubernetes upgrades](../../talos-cheatsheet.md#talos-and-kubernetes-upgrades) (watch, pause, recovery)
- [talos-cheatsheet.md: A node won't come back](../../talos-cheatsheet.md#a-node-wont-come-back)
