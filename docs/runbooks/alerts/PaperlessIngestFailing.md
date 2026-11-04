# PaperlessIngestFailing

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/paperless-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/paperless-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The Paperless ingest canary has not succeeded in 13 hours, or Prometheus has
no success on record. CronJob `paperless/paperless-canary` runs at 01:00,
07:00, 13:00 and 19:00 UTC: it uploads a generated one-page PDF with a random
number as the user `canary`, waits until a full-text search finds the number,
then deletes the page and empties it from the trash. Two runs in a row have
failed or not run, so a document uploaded through the web app may not be
OCRed, indexed or findable.

## Confirm

```sh
q 'time() - paperless_canary_last_success_timestamp_seconds'
q 'paperless_canary_success'
kubectl -n paperless get cronjob paperless-canary
kubectl -n paperless get jobs --sort-by=.status.startTime | grep canary
```

Expected while it fires: an age above 46800 seconds (13 hours), or no
result; `paperless_canary_success 0` or no Job in that time.

## Fix

1. Read the last run:

   ```sh
   kubectl -n paperless logs job/<job> | grep -E 'PASS|FAIL'
   ```

   | `FAIL` | Meaning | Next |
   | --- | --- | --- |
   | `POST /api/documents/post_document/: HTTP 401` or `403` | the token in `paperless-canary` is wrong, or `canary` lost `add_document` | the `canary` row in [secrets.md](../../secrets.md#rotating-a-credential) |
   | `HTTP 5xx` or a connection error | Paperless is down or restarting | `kubectl -n paperless get pods`; the Deployment's events and logs |
   | `not findable after 900 s` | the upload was accepted but never consumed or indexed | the consumption task in Paperless (Tasks, as `nedsi-admin`), `kubectl -n paperless logs deploy/paperless`, the Valkey pod |
   | `cleanup: ...` | found, but the page was not deleted or not emptied from the trash | delete the `canary <number>` document as `nedsi-admin` and empty it from the trash; then the permission named in the error |
   | `push: ...` | the Pushgateway did not take the result | `kubectl -n backup-verify get pods`; the `paperless-canary` entry in the NetworkPolicy of `platform/backup-verify/pushgateway.yaml`, and the egress rule in `infrastructure/network-policies/30-paperless.yaml` |

   No Job at all: `kubectl -n paperless describe cronjob paperless-canary`
   (suspended, or the Secret `paperless-canary` is missing).

2. Run the canary now:

   ```sh
   kubectl -n paperless create job --from=cronjob/paperless-canary canary-now
   kubectl -n paperless wait --for=condition=complete --timeout=25m job/canary-now
   kubectl -n paperless logs job/canary-now
   kubectl -n paperless delete job canary-now
   ```

   Expected: `job.batch/canary-now condition met` and
   `PASS findable after <n> s`.

## Resolved when

A run passes; the alert clears within 10 minutes.

## Links

- [`apps/paperless/canary.yaml`](../../../apps/paperless/canary.yaml)
- [`apps/paperless/canary/canary.py`](../../../apps/paperless/canary/canary.py)
- [PaperlessIngestSlow](PaperlessIngestSlow.md)
