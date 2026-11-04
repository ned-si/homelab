# PaperlessIngestSlow

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/paperless-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/paperless-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

Two runs in a row of the Paperless ingest canary (`paperless/paperless-canary`,
every 6 hours) took over 5 minutes from upload to a full-text search hit on
their one-page PDF. The target is 5 minutes for a file of up to 10 pages, so
real uploads are slower than that: OCR, the Celery worker or the task queue
is struggling.

## Confirm

```sh
q 'paperless_canary_duration_seconds'
kubectl -n paperless top pod
kubectl -n paperless logs job/<last canary job> | grep -E 'PASS|FAIL'
```

Expected while it fires: a duration above 300 and `PASS findable after <n> s`
with `<n>` above 300.

## Fix

1. Look for a backlog: an import batch or a large upload keeps the worker
   busy, and the canary page waits behind it. In Paperless (as `nedsi-admin`),
   Tasks lists the queued and running consumptions. A backlog clears by
   itself; the next run then passes under 5 minutes.
2. No backlog: check the node and the pod.

   ```sh
   kubectl -n paperless get pod -l app.kubernetes.io/name=paperless -o wide
   q 'sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="paperless"}[15m]))'
   q 'max by (pod) (container_memory_working_set_bytes{namespace="paperless"})'
   ```

   A pod near its memory limit or a node short of CPU slows OCR. The memory
   request and the OCR languages are in `apps/paperless/deployment.yaml`;
   dropping the least used language (`deu`, then `spa`) is one line there.

## Resolved when

A run takes under 5 minutes; the alert clears at that push.

## Links

- [`apps/paperless/canary.yaml`](../../../apps/paperless/canary.yaml)
- [PaperlessIngestFailing](PaperlessIngestFailing.md)
