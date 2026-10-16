# PersistentVolumeNearlyFull

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

PVC `namespace/persistentvolumeclaim` has had less than 15% free for 30
minutes. A full volume under a database is an outage, and on an iSCSI zvol
with xfs not always a clean one. Nothing grows volumes automatically.

## Confirm

```sh
q 'kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.15'
kubectl -n <namespace> get pvc <persistentvolumeclaim>
kubectl -n <namespace> get pod -o json |
  jq -r --arg c '<persistentvolumeclaim>' '.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $c)) | .metadata.name'
kubectl -n <namespace> exec <pod> -- du -xh -d1 <mount-path> | sort -h | tail
```

Expected while it fires: the free ratio under 0.15, and the directories that
hold the space.

## Fix

1. A Postgres volume: check WAL archiving first
   ([CNPGWALArchivingFailing](CNPGWALArchivingFailing.md)); unarchived WAL
   fills it and growing the volume only buys time.
2. Space that should not be there (old exports, logs, a cache): remove it
   through the app.
3. Otherwise grow it in git (`iscsi` and `iscsi-retain` set
   `allowVolumeExpansion: true`; online, no data movement):
   - a CNPG volume: `spec.storage.size` of the Cluster;
   - any other PVC: `spec.resources.requests.storage` in its manifest
     (`grep -rln '<persistentvolumeclaim>' apps platform infrastructure`), and
     the PV's `spec.capacity.storage` in `infrastructure/iscsi-volumes/` when
     the volume has a file there.
   Merge with `scripts/pr-merge.sh <n>` on green CI.
4. Not for `immich/immich-data`, the photo library: plan that one as its
   own change, with a fresh ZFS snapshot of its zvol first.

## Resolved when

`kubectl -n <namespace> get pvc <persistentvolumeclaim>` shows the new
`CAPACITY` (a `FileSystemResizePending` condition clears when the pod
remounts), and the free ratio is above 0.15.

## Links

- [PersistentVolumeCriticallyFull](PersistentVolumeCriticallyFull.md)
- [backups.md: Reclaim policy](../../backups.md#reclaim-policy)
