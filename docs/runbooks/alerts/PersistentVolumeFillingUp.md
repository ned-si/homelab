# PersistentVolumeFillingUp

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

PVC `namespace/persistentvolumeclaim` is under 60% free and, at the trend of
the last 6 hours, full within 24 hours. Something writes far more than usual.

## Confirm

```sh
q 'predict_linear(kubelet_volume_stats_available_bytes{namespace="<namespace>", persistentvolumeclaim="<persistentvolumeclaim>"}[6h], 24 * 3600)'
q 'kubelet_volume_stats_available_bytes{namespace="<namespace>", persistentvolumeclaim="<persistentvolumeclaim>"} / kubelet_volume_stats_capacity_bytes'
```

Expected while it fires: a negative projection. The Homelab / Storage
dashboard shows the curve.

## Fix

1. A Postgres volume: WAL that cannot be archived is the usual cause
   ([CNPGWALArchivingFailing](CNPGWALArchivingFailing.md),
   [CNPGWALArchiveLag](CNPGWALArchiveLag.md)).
2. Otherwise find the writer:
   `kubectl -n <namespace> exec <pod> -- du -xh -d2 <mount-path> | sort -h | tail`,
   and stop it at the source (a log loop, a runaway import, a download).
3. A legitimate one-off (an import, a library scan): grow the volume as in
   [PersistentVolumeNearlyFull](PersistentVolumeNearlyFull.md#fix).

## Resolved when

The projection is positive again; the alert clears after an hour.

## Links

- [PersistentVolumeNearlyFull](PersistentVolumeNearlyFull.md)
