# NASPoolCriticallyFull

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/nas-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/nas-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

NAS pool `pool` has been over 90% used for 15 minutes. A full pool stops
every write: every PVC, the media library and the local backups at once.

## Confirm

```sh
q 'nas:pool_used:ratio'
q 'nas:pool_days_until_full'
```

Expected while it fires: above 0.90; the second query (if present) says how
many days are left at the 7-day trend.

## Fix

Free space now, fastest first:

1. Stop what is filling it if it is still growing: pause the downloads in
   qBittorrent, or an import.
2. Delete old ZFS snapshots and released volumes, as in
   [NASPoolNearlyFull](NASPoolNearlyFull.md#fix) steps 1 and 2.
3. Remove media through Sonarr and Radarr.

Then plan capacity ([NASPoolNearlyFull](NASPoolNearlyFull.md#fix) step 4).

## Resolved when

Under 0.90 (the warning clears under 0.80).

## Links

- [NASPoolNearlyFull](NASPoolNearlyFull.md)
