# CNPGBaseBackupTooOld

`critical`, pages. Rule: [`platform/barman-cloud-plugin/monitoring.yaml`](../../../platform/barman-cloud-plugin/monitoring.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

`namespace/pod` has no base backup newer than 26 hours, or none at all: the
daily ScheduledBackup (00:00 to 01:10 UTC) did not produce one. The RPO of 24 h
depends on WAL plus a recent base backup.

## Confirm

```sh
q 'time() - barman_cloud_cloudnative_pg_io_last_available_backup_timestamp > 26 * 3600'
kubectl -n <namespace> get scheduledbackups.postgresql.cnpg.io
kubectl -n <namespace> get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp | tail -3
```

Expected while it fires: the pod with its age in seconds; no recent Backup,
or recent ones `failed`.

## Fix

1. Recent Backups `failed`: follow [CNPGBackupFailed](CNPGBackupFailed.md).
2. No recent Backup: the ScheduledBackup is suspended, missing or points at
   another cluster (the CI rule `cnpg-backup` checks this in git; compare with
   the live object: `kubectl -n <namespace> get scheduledbackups.postgresql.cnpg.io -o yaml`).
   The CNPG operator and the plugin run in `immich`:
   `kubectl -n immich get deploy`.
3. A new cluster that never had a backup: take one now, as in
   [CNPGBackupFailed](CNPGBackupFailed.md#fix) step 3.

## Resolved when

A `completed` Backup newer than 26 hours; the alert clears within 15 minutes.

## Links

- [backups.md: Schedule](../../backups.md#schedule)
