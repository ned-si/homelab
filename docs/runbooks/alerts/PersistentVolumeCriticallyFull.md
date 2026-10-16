# PersistentVolumeCriticallyFull

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

PVC `namespace/persistentvolumeclaim` has had less than 5% free for 10
minutes. Writes fail soon; a database on it stops or corrupts its last
transaction.

## Confirm

```sh
q 'kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.05'
kubectl -n <namespace> get pvc <persistentvolumeclaim>
```

Expected while it fires: the free ratio under 0.05.

## Fix

Grow it now, as in [PersistentVolumeNearlyFull](PersistentVolumeNearlyFull.md#fix),
without waiting to find the cause: the growth is online. A volume cannot
shrink again, so add what the next months need, not more. Then find what
filled it.

If the app is already down and a merge takes too long, free space by hand
inside the pod (`kubectl -n <namespace> exec <pod> -- ...`): old logs or
caches only, never database files.

## Resolved when

The free ratio is above 0.05 (the warning clears above 0.15) and the app
answers.

## Links

- [PersistentVolumeNearlyFull](PersistentVolumeNearlyFull.md)
