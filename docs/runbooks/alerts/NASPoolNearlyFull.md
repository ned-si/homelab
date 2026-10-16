# NASPoolNearlyFull

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/nas-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/nas-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

NAS pool `pool` has been over 80% used for an hour. ZFS slows down and
fragments past about 80%. Every iSCSI volume and the media library live on
pool `homelab`.

## Confirm

```sh
q 'nas:pool_used:ratio'
q 'topk(10, truenas_dataset_used_bytes{dataset=~"homelab/.+"})'
```

Expected while it fires: the pool above 0.80, and the datasets that hold the
space. In the TrueNAS Shell, `zfs list -o space -r -d 2 homelab` adds the
space held by snapshots (`USEDSNAP`).

## Fix

1. Snapshots: old ZFS snapshots of large datasets hold deleted data. Review
   Tasks → Periodic Snapshot Tasks retention and delete snapshots no longer
   needed (Storage → Snapshots). Never the newest snapshot of the Immich zvol.
2. Released volumes: PVs with reclaim policy `Retain` keep their zvol after
   their claim is gone:
   `kubectl get pv | grep -E 'Released|Available'`. Delete one only after
   checking its data is not needed ([backups.md: Reclaim policy](../../backups.md#reclaim-policy)).
3. The media library (`homelab/k8s/nfs/media`): remove watched or unwanted
   titles through Sonarr and Radarr, so they do not come back.
4. Nothing to remove: plan more capacity (larger disks, replaced one at a
   time with a resilver each, then `zpool online -e`).

## Resolved when

`q 'nas:pool_used:ratio'` is under 0.80; the alert clears.

## Links

- [NASPoolCriticallyFull](NASPoolCriticallyFull.md), [NASPoolFillingUp](NASPoolFillingUp.md)
- Homelab / Storage dashboard
