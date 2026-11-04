# PaperlessRestoreStale

`warning`, pages. Rule: [`platform/backup-verify/alerts.yaml`](../../../platform/backup-verify/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The monthly Paperless restore test has not passed in 35 days, or Prometheus
has no passing result on record. CronJob `backup-verify-paperless` runs on the
3rd of the month at 19:00 UTC: it restores the newest `paperless-export`
snapshot, imports it into a throwaway Paperless in its own pod and compares
the document counts. Until it passes again, nothing proves that the export
restores into a working Paperless. A failed run also fires
`BackupVerifyFailed` (`check="paperless-restore"`).

## Confirm

```sh
q 'time() - backup_verify_last_success_timestamp_seconds{check="paperless-restore"}'
kubectl -n backup-verify get cronjob backup-verify-paperless
kubectl -n backup-verify get jobs --sort-by=.status.startTime
```

Expected while it fires: an age above 3024000 seconds (35 days), or no
result; and no Job of `backup-verify-paperless` that completed in that time.

## Fix

1. Read the last run, if there is one:

   ```sh
   kubectl -n backup-verify logs job/<job> --all-containers | grep -E 'PASS|FAIL|documents|PDF'
   ```

   Expected: `documents: imported <n>, manifest.json <n>, export-meta.json <n>`,
   `the PDF opens` and `PASS paperless-export`. Each `FAIL` line names the
   step:

   | `FAIL` | Meaning | Next |
   | --- | --- | --- |
   | no snapshot, or snapshot `<n> h old` | the nightly `paperless/paperless-backup` did not snapshot the export | its last Job log, [Schedule](../../backups.md#schedule) |
   | `restic restore failed` | the snapshot does not restore | `restic check` of `paperless/media`, [Verification](../../backups.md#verification) |
   | `migrate` or `document_importer failed` | the export does not import into this Paperless version, or the passphrase differs from the export's | the 20 log lines above the `FAIL`; the passphrase copies in [secrets.md](../../secrets.md) |
   | `document counts differ` | the export lost or gained documents against its database copy | treat the export as at risk; compare with a manual restore ([How to restore](../../backups.md#how-to-restore)) |
   | `the PDF does not open` | a restored file is damaged | the same, for that document |

2. Run the test now:

   ```sh
   kubectl -n backup-verify create job --from=cronjob/backup-verify-paperless paperless-now
   kubectl -n backup-verify wait --for=condition=complete --timeout=60m job/paperless-now
   kubectl -n backup-verify logs job/paperless-now --all-containers | grep -E 'PASS|FAIL'
   kubectl -n backup-verify delete job paperless-now
   ```

   Expected: `job.batch/paperless-now condition met` and
   `PASS paperless-export: imported into a throwaway Paperless, counts match, a PDF opens`.
   Deleting the Job deletes its pod and the pod's scratch claim.

## Resolved when

A run passes; the alert clears within the hour.

## Links

- [backups.md: Verification](../../backups.md#verification)
- [`platform/backup-verify/restore-paperless.yaml`](../../../platform/backup-verify/restore-paperless.yaml)
- [`platform/backup-verify/scripts/verify-paperless.sh`](../../../platform/backup-verify/scripts/verify-paperless.sh)
