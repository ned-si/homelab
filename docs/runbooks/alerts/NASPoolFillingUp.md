# NASPoolFillingUp

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/nas-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/nas-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

At the trend of the last 7 days, pool `pool` is full within 30 days
(recording rule `nas:pool_days_until_full`), for 6 hours running.

## Confirm

```sh
q 'nas:pool_days_until_full'
q 'topk(5, deriv(truenas_dataset_used_bytes{dataset=~"homelab/.+"}[7d]))'
```

Expected while it fires: under 30 days, and the datasets growing fastest
(bytes per second).

## Fix

1. A fast-growing dataset that should not grow (a backup repository whose
   prune stopped, a log volume): fix its cause. Restic prune runs on the 1st
   of the month ([backups.md: Retention](../../backups.md#retention)).
2. Expected growth (photos, media): free space or plan capacity, as in
   [NASPoolNearlyFull](NASPoolNearlyFull.md#fix).

## Resolved when

`nas:pool_days_until_full` is above 30 or absent (usage stable or
shrinking); the alert clears.

## Links

- [NASPoolNearlyFull](NASPoolNearlyFull.md)
