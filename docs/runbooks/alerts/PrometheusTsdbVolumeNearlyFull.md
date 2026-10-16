# PrometheusTsdbVolumeNearlyFull

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

The Prometheus volume has had less than 12% free for 15 minutes.
`retentionSize` (20 GiB) should keep the blocks inside the volume, so the WAL
or a compaction is using the headroom. A full volume stops ingestion, and
then no alert fires at all, this one included.

## Confirm

```sh
q 'kubelet_volume_stats_available_bytes{namespace="monitoring", persistentvolumeclaim=~"prometheus-.*"} / kubelet_volume_stats_capacity_bytes'
q 'prometheus_tsdb_storage_blocks_bytes'
q 'prometheus_tsdb_wal_storage_size_bytes'
```

Expected while it fires: free under 0.12; blocks near 20 GiB, or a large WAL.

## Fix

Grow the volume rather than cut retention (the SLOs need 30 days):

1. In a pull request, raise the size in both places:
   `prometheus.prometheusSpec.storageSpec` in
   `platform/kube-prometheus-stack/values.yaml` and the claim in
   `infrastructure/iscsi-volumes/monitoring-prometheus-db.yaml`.
2. The operator does not resize the PVC: after the merge, set the claim to
   the same size (online, no restart):

   ```sh
   kubectl -n monitoring patch pvc prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 \
     --type merge -p '{"spec":{"resources":{"requests":{"storage":"<size>"}}}}'
   ```

3. A large WAL alone: a scrape target with exploding series; find it with
   `q 'topk(10, scrape_samples_scraped)'` and fix or drop it.

## Resolved when

Free above 0.12; the alert clears.

## Links

- The comment on `retentionSize` in [`platform/kube-prometheus-stack/values.yaml`](../../../platform/kube-prometheus-stack/values.yaml)
