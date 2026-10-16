# BackupVerifyMissing

`warning`, pages. Rule: [`platform/backup-verify/alerts.yaml`](../../../platform/backup-verify/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Prometheus has no passing `check` result at all in its window (9 days, 30
for `restic-data`): the restore tests never ran or never passed, or their
results do not reach Prometheus.

## Confirm

```sh
q 'count by (check) (backup_verify_last_success_timestamp_seconds)'
q 'up{job="pushgateway"}'
kubectl -n backup-verify get cronjobs,jobs,pods
```

Expected while it fires: the `check` missing from the first query. If the
second is empty or `0`, the Pushgateway is not scraped.

## Fix

1. Pushgateway not scraped: `kubectl -n backup-verify get pod,svc,servicemonitor`
   and the Application `backup-verify` in Argo CD. A restarted Pushgateway
   loses its groups; the next run pushes again.
2. CronJobs missing or suspended: the Application `backup-verify` is not
   synced, or the CronJob is not in `ci/active-cronjobs.txt`.
3. Runs that fail: [BackupVerifyFailed](BackupVerifyFailed.md).
4. Run the check now, as in [BackupVerifyStale](BackupVerifyStale.md#fix).

## Resolved when

`q 'count by (check) (backup_verify_last_success_timestamp_seconds)'` lists
the check; the alert clears within the hour.

## Links

- [backups.md: Reading the results](../../backups.md#reading-the-results)
