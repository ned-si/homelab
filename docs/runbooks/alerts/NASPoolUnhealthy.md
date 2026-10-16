# NASPoolUnhealthy

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/nas-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/nas-alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

ZFS reports pool `pool` not healthy for 5 minutes: DEGRADED, FAULTED or with
errors. Pool `homelab` is RAIDZ1 over 5 disks: while one data disk is out,
one more failure loses every PVC and the media library.

## Confirm

```sh
q 'truenas_pool_healthy == 0'
q 'truenas_pool_device_online == 0'
```

Then in the TrueNAS web UI (`https://192.168.1.228`), Shell:

```sh
zpool status -v homelab
```

Expected while it fires: `state: DEGRADED` (or worse) and the device that is
`FAULTED`, `REMOVED`, `UNAVAIL` or has errors.

## Fix

1. Only a `cache` device (L2ARC, `nvd0`) is affected: the data is safe.
   Remove it from the pool: `zpool remove homelab nvd0`. The pool turns
   ONLINE; reads lose the cache.
2. A data disk: check the backups are fresh first (Homelab / Data protection
   dashboard: every backup under 24 h, restore tests passing). Avoid heavy
   writes until the resilver ends.
3. Note the failed disk's serial: Storage → Disks. Then Storage → Pools →
   `homelab` → Status → the disk → Offline.
4. Physical swap: put a disk of at least the same size in its bay. If the
   bay is not hot-swap, shut the NAS down first, which is an outage of every
   PVC: follow [cold-start.md: Planned shutdown](../cold-start.md#planned-shutdown).
5. Storage → Pools → `homelab` → Status → the offline disk → Replace, pick
   the new disk. The resilver starts.

## Resolved when

`zpool status homelab` shows `state: ONLINE` after the resilver, and
`q 'truenas_pool_healthy'` returns `1` for every pool.

## Links

- [observability.md: NAS metrics](../../observability.md#nas-metrics)
- [NASPoolDeviceNotOnline](NASPoolDeviceNotOnline.md), [NASPoolDeviceErrors](NASPoolDeviceErrors.md)
