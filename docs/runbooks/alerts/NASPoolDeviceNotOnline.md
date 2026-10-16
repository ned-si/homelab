# NASPoolDeviceNotOnline

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/nas-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/nas-alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

Device `disk` (role `role`) of pool `pool` has not been ONLINE for 10
minutes. A `cache` or `log` device slows the pool; a `data` device degrades
it, and [NASPoolUnhealthy](NASPoolUnhealthy.md) fires too.

## Confirm

```sh
q 'truenas_pool_device_online == 0'
```

TrueNAS web UI (`https://192.168.1.228`), Shell: `zpool status -v <pool>`.

Expected while it fires: the device `FAULTED`, `REMOVED`, `UNAVAIL` or
`OFFLINE`.

## Fix

- `cache` device (`nvd0`, known to be failing): remove it,
  `zpool remove homelab nvd0`. Nothing else depends on it.
- `data` device: follow [NASPoolUnhealthy](NASPoolUnhealthy.md#fix).
- `REMOVED` after a cable or power event: reseat the disk's cable, then
  `zpool online <pool> <disk>` and watch the resilver in `zpool status`.

## Resolved when

`zpool status` shows every remaining device ONLINE; the alert clears.

## Links

- [observability.md: NAS metrics](../../observability.md#nas-metrics)
