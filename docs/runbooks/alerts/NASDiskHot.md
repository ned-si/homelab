# NASDiskHot

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/nas-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/nas-alerts.yaml).
Shell: [Before you start](README.md#before-you-start).

## What it means

NAS disk `disk` has been above 65 °C for 30 minutes. The pool's SATA SSDs are
rated to 70 °C; past that they throttle and wear faster.

## Confirm

```sh
q 'truenas_disk_temperature_celsius'
```

Expected while it fires: the disk above 65. Several disks hot at once means
the case, one disk alone means its bay or the disk.

## Fix

1. A heavy job at the same time (a scrub, a resilver, the Immich backup)
   explains a peak; check the Homelab / Storage dashboard. It should drop
   when the job ends.
2. Physical: check the case fans spin, the intake is not blocked or dusty,
   and nothing stands against the vents. Clean or replace a dead fan.
3. One disk hot while the others are not: reseat it in another bay if one is
   free, or plan its replacement ([NASSmartTestFailed](NASSmartTestFailed.md)).

## Resolved when

The temperature stays at 65 °C or below; the alert clears.

## Links

- [observability.md: NAS metrics](../../observability.md#nas-metrics)
