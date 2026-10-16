# BackupVerifyDataStale

`warning`, pages. Rule: [`platform/backup-verify/alerts.yaml`](../../../platform/backup-verify/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The monthly `restic check --read-data-subset` of repository `target` has not
passed in 36 days. It runs inside `backup-verify-files` on the first Saturday
of the month (`DATA_CHECK=auto`), so a missed or failed first Saturday leaves
the pack contents unread.

## Confirm

```sh
q 'time() - backup_verify_last_success_timestamp_seconds{check="restic-data"} > 36 * 86400'
kubectl -n backup-verify get jobs --sort-by=.status.startTime
```

Expected while it fires: the repository with its age in seconds.

## Fix

Run the pack read now, with `DATA_CHECK=always`:

```sh
kubectl -n backup-verify create job --from=cronjob/backup-verify-files data-now --dry-run=client -o yaml |
  yq '(.spec.template.spec.containers[] | select(.name == "verify") | .env[] | select(.name == "DATA_CHECK") | .value) = "always"' |
  kubectl apply -f -
kubectl -n backup-verify logs -f job/data-now | grep -E 'read-data|PASS|FAIL'
kubectl -n backup-verify delete job data-now
```

Expected: a `restic check --read-data-subset=<slice>/<slices>` line per
repository and no `FAIL`. A `FAIL ... reported errors` means damaged packs:
run `restic check` against that repository by hand and treat its data as at
risk ([backups.md: Verification](../../backups.md#verification)).

## Resolved when

The run passes; the alert clears within the hour.

## Links

- [backups.md: Verification](../../backups.md#verification)
- [`platform/backup-verify/scripts/restic-data-targets.txt`](../../../platform/backup-verify/scripts/restic-data-targets.txt)
