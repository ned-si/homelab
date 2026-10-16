# BackupLockBroken

`critical`, pages. Rule: [`platform/backup-verify/alerts.yaml`](../../../platform/backup-verify/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The weekly lock test deleted an old object version in bucket `target`, or the
bucket policy no longer denies `s3:DeleteObjectVersion` to every principal.
One leaked key can now destroy every backup.

## Confirm

```sh
q 'backup_verify_lock_ok == 0'
kubectl -n backup-verify get jobs --sort-by=.status.startTime | grep -i lock
kubectl -n backup-verify logs job/<job> -c report
```

Expected while it fires: a `BROKEN: ...` line naming what failed.

## Fix

1. Re-apply the bucket policy from git: `gh workflow run tofu.yaml`, then
   `gh run watch` on that run (stop it when it ends). The plan must show the
   policy of `bootstrap/aws-backup/main.tf` being restored.
2. Find who changed it: CloudTrail events `PutBucketPolicy`,
   `DeleteBucketPolicy`, `PutBucketVersioning` on the bucket. If it was not
   you, rotate every backup key
   ([secrets.md: Rotating a credential](../../secrets.md#rotating-a-credential)).
3. Check that recent snapshots still exist: the Homelab / Data protection
   dashboard and a `restic snapshots` run ([backups.md](../../backups.md#how-to-restore)).

## Resolved when

A new lock test logs `OK`:

```sh
kubectl -n backup-verify create job --from=cronjob/backup-verify-lock lock-now
kubectl -n backup-verify logs -f job/lock-now -c report
kubectl -n backup-verify delete job lock-now
```

`q 'backup_verify_lock_ok'` returns `1` and the alert clears.

## Links

- [backups.md: When the lock test fails](../../backups.md#when-the-lock-test-fails)
- [backups.md: Immutable versions](../../backups.md#immutable-versions)
