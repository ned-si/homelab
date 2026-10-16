# NASExporterAbsent

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/nas-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/nas-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Prometheus has had no `truenas_up` for 15 minutes: `truenas-exporter` is not
running or not scraped. No NAS health alert (pool, disks, capacity) can fire.

## Confirm

```sh
q 'up{job="truenas-exporter"}'
kubectl -n democratic-csi get deploy,servicemonitor truenas-exporter --show-labels
kubectl -n democratic-csi logs deploy/truenas-exporter --tail=20
```

Expected while it fires: no series; a Deployment not available or a
ServiceMonitor missing its `release` label.

## Fix

1. Pod failing: read its logs; a crash at start is usually the Secret it
   reads (`iscsi-democratic-csi-driver-config`).
2. Missing objects: the Application `truenas-exporter` in Argo CD, and
   `platform/truenas-exporter/` in git.

## Resolved when

`q 'truenas_up'` returns a value; the alert clears. A `0` is
[NASExporterFailing](NASExporterFailing.md).

## Links

- [observability.md: NAS metrics](../../observability.md#nas-metrics)
