# PrometheusTsdbVolumeNearlyFull

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The Prometheus volume has had less than 10% free for 15 minutes.
`retentionSize` (34 GiB) counts the blocks, the WAL and the head chunks, so at
the cap about 15% of the 40 GiB volume stays free, and a compaction dips to
about 10%. Below that, something Prometheus does not count is using the space,
such as a compaction that never finished. A full volume stops ingestion, and
then no alert fires at all, this one included.

## Confirm

```sh
q 'kubelet_volume_stats_available_bytes{namespace="monitoring", persistentvolumeclaim=~"prometheus-.*"} / kubelet_volume_stats_capacity_bytes'
q 'prometheus_tsdb_storage_blocks_bytes'
q 'prometheus_tsdb_wal_storage_size_bytes'
q 'increase(prometheus_tsdb_compactions_failed_total[1d])'
```

Expected while it fires: free under 0.10; blocks plus WAL near 34 GiB, or well
below it with failed compactions.

## Fix

Grow the volume rather than cut retention (the SLOs need 30 days):

1. In a pull request, raise the size in all three places:
   `prometheus.prometheusSpec.storageSpec` in
   `platform/kube-prometheus-stack/values.yaml`, and the PV capacity and the
   claim in `infrastructure/iscsi-volumes/monitoring-prometheus-db.yaml`.
   Raise `retentionSize` with them, to at most 85% of the new size.
2. After the merge Argo CD applies the claim, and the CSI resizer grows the
   zvol and the filesystem online, no restart:

   ```sh
   q 'kubelet_volume_stats_capacity_bytes{namespace="monitoring", persistentvolumeclaim=~"prometheus-.*"}'
   # expected: the new size, in bytes
   ```

3. A large WAL alone: a scrape target with exploding series; find it with
   `q 'topk(10, scrape_samples_scraped)'` and fix or drop it.

## Resolved when

Free above 0.10; the alert clears.

## Links

- The comment on `retentionSize` in [`platform/kube-prometheus-stack/values.yaml`](../../../platform/kube-prometheus-stack/values.yaml)
