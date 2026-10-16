# BackupVerifyStale

`warning`, pages. Rule: [`platform/backup-verify/alerts.yaml`](../../../platform/backup-verify/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The weekly `check` restore test of `target` has not passed in 8 days: its
CronJob did not run, or every run failed. The backup is unproven, not known
bad.

## Confirm

```sh
q 'time() - backup_verify_last_success_timestamp_seconds{check!="restic-data"} > 8 * 86400'
kubectl -n backup-verify get cronjobs,jobs
```

Expected while it fires: the pair with its age in seconds; a CronJob with an
old `LAST SCHEDULE`, `SUSPEND True`, or recent Jobs that failed.

## Fix

1. Runs failed: follow [BackupVerifyFailed](BackupVerifyFailed.md).
2. No run: a suspended CronJob (`SUSPEND True`) must be active per
   `ci/active-cronjobs.txt`; a weekend with the cluster down just missed the
   slot. Run it now (CronJob from the table in
   [BackupVerifyFailed](BackupVerifyFailed.md#what-it-means)):

   ```sh
   kubectl -n backup-verify create job --from=cronjob/<cronjob> verify-now
   kubectl -n backup-verify logs -f job/verify-now --all-containers | grep -E 'PASS|FAIL'
   kubectl -n backup-verify delete job verify-now
   ```

3. The target was removed on purpose: delete its Pushgateway group
   ([backups.md: When a restore test fails](../../backups.md#when-a-restore-test-fails),
   last block).

## Resolved when

A `PASS <target>` line, and the alert clears within the hour.

## Links

- [backups.md: Verification](../../backups.md#verification)
- Homelab / Data protection dashboard
