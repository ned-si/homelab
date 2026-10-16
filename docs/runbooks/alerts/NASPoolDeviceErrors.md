# NASPoolDeviceErrors

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/nas-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/nas-alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

ZFS counted `type` errors (read, write or checksum) on device `disk` of pool
`pool`. A few after a cable or power event are harmless once cleared;
errors that come back mean a failing disk or cable.

## Confirm

```sh
q 'truenas_pool_device_errors > 0'
```

TrueNAS web UI (`https://192.168.1.228`), Shell:

```sh
zpool status -v <pool>
smartctl -a /dev/<disk> | grep -Ei 'result|reallocated|pending|crc'
```

Expected while it fires: non-zero READ, WRITE or CKSUM on the device. `-v`
lists files with permanent errors, if any.

## Fix

1. Files with permanent errors: restore them from backup
   ([backups.md: How to restore](../../backups.md#how-to-restore)).
2. Clear the counters: `zpool clear <pool> <disk>`, then start a scrub:
   `zpool scrub <pool>`.
3. Errors return during the scrub, or SMART shows reallocated or pending
   sectors: replace the disk ([NASPoolUnhealthy](NASPoolUnhealthy.md#fix)
   steps 2 to 5). UDMA CRC errors point at the cable: reseat or swap it.

## Resolved when

The scrub finishes with `0 errors` and the counters stay at 0; the alert
clears.

## Links

- [NASSmartTestFailed](NASSmartTestFailed.md)
