# CNPGWALArchiveLag

`critical`, pages. Rule: [`platform/barman-cloud-plugin/monitoring.yaml`](../../../platform/barman-cloud-plugin/monitoring.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

More than 5 WAL segments of `namespace/pod` have waited for archiving for 30
minutes: WAL is produced faster than it is archived, or archiving stalls
without failing outright. The volume fills if it continues.

## Confirm

```sh
q 'cnpg_collector_pg_wal_archive_status{value="ready"} > 5'
kubectl -n <namespace> logs <pod> -c plugin-barman-cloud --since=1h | tail -30
q 'kubelet_volume_stats_available_bytes{namespace="<namespace>"} / kubelet_volume_stats_capacity_bytes'
```

Expected while it fires: the count of ready segments, rising or flat.

## Fix

1. Errors in the log: follow [CNPGWALArchivingFailing](CNPGWALArchivingFailing.md).
2. No errors, slow uploads: a saturated uplink (a large restic backup or a
   seeding torrent at the same time) or a burst of writes (an import, a
   reindex). Wait for it to end, or pause the competing job; the count must
   go down.
3. The volume is filling: grow it ([PersistentVolumeNearlyFull](PersistentVolumeNearlyFull.md)).

## Resolved when

The count drops to 5 or below and the alert clears.

## Links

- [backups.md: Databases](../../backups.md#databases)
