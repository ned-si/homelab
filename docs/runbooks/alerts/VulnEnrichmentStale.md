# VulnEnrichmentStale

`warning`, pages. Rule: [`platform/vuln-enrich/rules.yaml`](../../../platform/vuln-enrich/rules.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The `vuln-enrich` CronJob (namespace `monitoring`, daily 06:20 UTC) has not
pushed KEV and EPSS data for 3 days. The Homelab / Security dashboard's "Act
now" list is out of date, not empty.

## Confirm

```sh
q 'time() - vuln_enrich_last_success_timestamp_seconds'
kubectl -n monitoring get cronjob,jobs -l app.kubernetes.io/name=vuln-enrich
kubectl -n monitoring logs job/<newest-job> | tail -20
```

Expected while it fires: an age over 259200 seconds (or nothing), and failed
Jobs or none.

## Fix

1. Download errors: the CISA KEV or FIRST EPSS endpoint was down or changed
   its format. Wait for the next run if it was an outage; fix `enrich.py` if
   the format changed (`tests/test_vuln_enrich.py`).
2. Push errors: the Pushgateway in `backup-verify` is down.
3. Run it now:

   ```sh
   kubectl -n monitoring create job --from=cronjob/vuln-enrich vuln-enrich-manual
   kubectl -n monitoring logs -f job/vuln-enrich-manual
   kubectl -n monitoring delete job vuln-enrich-manual
   ```

   Expected: `{"msg": "pushed", "cves": <n>, "kev": <n>, ...}`.

## Resolved when

A `pushed` line; the alert clears within the hour.

## Links

- [observability.md: Vulnerability priority](../../observability.md#vulnerability-priority)
