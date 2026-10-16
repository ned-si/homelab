# NASScrubOverdue

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/nas-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/nas-alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

Pool `pool` has not finished a scrub in 40 days. TrueNAS scrubs every 35
days by default; without scrubs, silent corruption is only found when the
data is read.

## Confirm

```sh
q '(time() - truenas_pool_scrub_end_timestamp_seconds) / 86400'
```

TrueNAS web UI (`https://192.168.1.228`): Tasks → Scrub Tasks; Shell:
`zpool status <pool>` shows the last scan.

Expected while it fires: over 40 days, and a scrub task disabled, missing,
or a scrub that was cancelled or never finished.

## Fix

1. Re-enable or recreate the scrub task (threshold 35 days).
2. Start one now in the Shell: `zpool scrub <pool>`. It takes hours on
   `homelab` and slows the pool; start it in the evening.

## Resolved when

`zpool status <pool>` shows `scrub repaired ... with 0 errors` and a recent
date; the alert clears.

## Links

- [NASPoolDeviceErrors](NASPoolDeviceErrors.md) if the scrub finds errors
