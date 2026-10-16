# BackupVerifyFailed

`warning`, pages. Rule: [`platform/backup-verify/alerts.yaml`](../../../platform/backup-verify/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The last `check` restore test of `target` failed, so that backup may not
restore. Treat the data of `target` as at risk until a test passes.

| `check` | CronJob in `backup-verify` |
| --- | --- |
| `restic`, `restic-data` | `backup-verify-files` |
| `postgres` | `backup-verify-postgres` |

## Confirm

```sh
q 'backup_verify_success == 0'
kubectl -n backup-verify get jobs --sort-by=.status.startTime
kubectl -n backup-verify logs job/<job> --all-containers | grep -E 'PASS|FAIL'
```

Expected while it fires: the `check`/`target` pair at `0`, and a `FAIL <target>`
line with the reason in the newest Job of that CronJob.

## Fix

1. A stale or missing snapshot, or a missing or empty required file: the
   backup is the problem. Check the app's backup CronJob and its last Job
   (`kubectl -n <app-namespace> get cronjobs,jobs | grep backup`, then
   `kubectl -n <app-namespace> logs job/<job>`) and fix it.
2. A restore that did not become Ready, or a table or row count that differs:
   restore the same backup by hand and compare
   ([backups.md: How to restore](../../backups.md#how-to-restore),
   [Restore a Postgres cluster from S3](../../backups.md#restore-a-postgres-cluster-from-s3)).
3. A one-row mismatch on a busy *arr table: rerun before anything else; it is
   not a backup fault if the rerun passes.
4. Rerun the test:

   ```sh
   kubectl -n backup-verify create job --from=cronjob/<cronjob> verify-now
   kubectl -n backup-verify logs -f job/verify-now --all-containers | grep -E 'PASS|FAIL'
   kubectl -n backup-verify delete job verify-now
   ```

## Resolved when

The rerun logs `PASS <target>` and `q 'backup_verify_success{check="<check>", target="<target>"}'`
returns `1`; the alert clears within 5 minutes.

## Links

- [backups.md: When a restore test fails](../../backups.md#when-a-restore-test-fails)
- [backups.md: Verification](../../backups.md#verification)
- Homelab / Data protection dashboard
