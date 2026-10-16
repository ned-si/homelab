# CNPGWALArchivingFailing

`critical`, pages. Rule: [`platform/barman-cloud-plugin/monitoring.yaml`](../../../platform/barman-cloud-plugin/monitoring.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The last WAL archive attempt of `namespace/pod` failed and none has succeeded
since. Point-in-time recovery stops at the last archived segment, and the
unarchived WAL stays on the data volume until it fills.

## Confirm

```sh
kubectl -n <namespace> logs <pod> -c plugin-barman-cloud --since=1h | grep -iE 'error|fail' | tail -20
kubectl -n <namespace> get cluster.postgresql.cnpg.io <cluster> \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
q 'kubelet_volume_stats_available_bytes{namespace="<namespace>"} / kubelet_volume_stats_capacity_bytes'
```

Expected while it fires: archive errors in the sidecar log and
`ContinuousArchiving=False`. The last query shows how much room the volume
has left.

## Fix

1. Read the error: `AccessDenied` or `InvalidAccessKeyId` (the namespace's
   Secret `cnpg-backup-s3`, used by ObjectStore `cnpg-backup`, or the IAM
   policy in `bootstrap/aws-backup/`), a
   timeout (network, DNS), or `NoSuchBucket`.
2. Fix the cause through git. Archiving resumes by itself and catches up;
   nothing to restart.
3. If the volume is over 85% full while you work on it, grow it first
   ([PersistentVolumeNearlyFull](PersistentVolumeNearlyFull.md)).

## Resolved when

`ContinuousArchiving=True`, and
`q 'cnpg_pg_stat_archiver_last_archived_time{pod="<pod>"} > cnpg_pg_stat_archiver_last_failed_time{pod="<pod>"}'`
returns a value; the alert clears.

## Links

- [backups.md: Databases](../../backups.md#databases)
- [backups.md: Credentials](../../backups.md#credentials)
