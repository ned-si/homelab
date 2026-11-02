# PrometheusRetentionCutBySize

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

`retentionSize` deleted blocks in the last 4 days while the oldest sample is
younger than 29 days. Prometheus holds less than the 30 days the SLO windows
(`routes/slo.yaml`) and the 30-day restic-data check need. A TSDB younger
than 30 days that deletes nothing is refilling after a wipe: no alert.

## Confirm

```sh
q '(time() - prometheus_tsdb_lowest_timestamp_seconds) / 86400'
q 'increase(prometheus_tsdb_size_retentions_total[4d])'
q 'prometheus_tsdb_storage_blocks_bytes'
q 'rate(prometheus_tsdb_head_samples_appended_total[1d])'
```

Expected while it fires: under 29 days kept, a size deletion above 0, blocks
near `retentionSize`.

## Fix

Daily growth is blocks bytes divided by days kept; 30 days must fit under
`retentionSize` with room left for the WAL and compaction.

1. Ingestion grew: find the series behind it with
   `q 'topk(10, scrape_samples_scraped)'` and drop unused
   ones with a `metricRelabelings` drop, as in #908.
2. Otherwise grow the volume, in a pull request: `retentionSize` and
   `prometheus.prometheusSpec.storageSpec` in
   `platform/kube-prometheus-stack/values.yaml`, and the claim and PV in
   `infrastructure/iscsi-volumes/monitoring-prometheus-db.yaml`. The CSI
   resizer grows the zvol and filesystem online after the merge (the comment
   on `retentionSize` in `values.yaml`).

## Resolved when

No size deletion for 4 days. History refills by itself: the oldest sample
reaches 30 days that many days after the last cut.

## Links

- The comment on `retentionSize` in [`platform/kube-prometheus-stack/values.yaml`](../../../platform/kube-prometheus-stack/values.yaml)
- [PrometheusTsdbVolumeNearlyFull](PrometheusTsdbVolumeNearlyFull.md)
