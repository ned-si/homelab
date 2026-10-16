# BackupLockCheckStale

`warning`, pages. Rule: [`platform/backup-verify/alerts.yaml`](../../../platform/backup-verify/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The weekly lock test (`backup-verify-lock`, Saturday 20:00 UTC) has not
passed in 8 days, or never: the CronJob did not run, or every run was
`INCONCLUSIVE`. Whether old versions are protected is unknown.

## Confirm

```sh
q 'time() - backup_verify_lock_last_success_timestamp_seconds'
kubectl -n backup-verify get cronjob backup-verify-lock
kubectl -n backup-verify get jobs --sort-by=.status.startTime | grep -i lock
kubectl -n backup-verify logs job/<job> -c report
```

Expected while it fires: an age over 691200 seconds (or no result), and
`INCONCLUSIVE` lines in the newest run.

## Fix

1. `INCONCLUSIVE`: the verifier key could not write `_lock-test/weekly` or
   read the policy, or something other than the bucket policy refused the
   delete. Check the verifier IAM policy in `bootstrap/aws-backup/` was
   applied (`gh workflow run tofu.yaml`) and that Secret
   `backup-verify/s3-backup` holds the verifier key, not a `PENDING-*`
   sentinel.
2. No run: the CronJob is suspended or missing; it must be in
   `ci/active-cronjobs.txt` and synced by the Application `backup-verify`.
3. Run it now, as in [BackupLockBroken](BackupLockBroken.md#resolved-when).

## Resolved when

A run logs `OK`; the alert clears within the hour.

## Links

- [backups.md: When the lock test fails](../../backups.md#when-the-lock-test-fails)
