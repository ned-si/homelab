# NASSmartTestFailed

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/nas-alerts.yaml`](../../../platform/kube-prometheus-stack/routes/nas-alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

The newest `test` SMART self-test of NAS disk `disk` did not pass. The disk
is likely to fail; ZFS may not have noticed yet.

## Confirm

```sh
q 'truenas_disk_smart_last_test_success == 0'
```

TrueNAS web UI (`https://192.168.1.228`), Shell:

```sh
smartctl -l selftest /dev/<disk>
smartctl -a /dev/<disk> | grep -Ei 'overall|reallocated|pending|wear'
```

Expected while it fires: the newest self-test line not `Completed without error`.

## Fix

1. Run a long test to be sure: `smartctl -t long /dev/<disk>` (hours; the
   result shows in `smartctl -l selftest`).
2. It fails again, or SMART shows reallocated, pending or worn-out values:
   replace the disk before it fails
   ([NASPoolUnhealthy](NASPoolUnhealthy.md#fix) steps 2 to 5). A disk that is
   still ONLINE can be replaced in place, without offlining it first, which
   keeps the redundancy during the resilver.

## Resolved when

A new self-test of the disk (or its replacement) passes:
`q 'truenas_disk_smart_last_test_success{disk="<disk>"}'` returns `1`.

## Links

- [observability.md: NAS metrics](../../observability.md#nas-metrics)
