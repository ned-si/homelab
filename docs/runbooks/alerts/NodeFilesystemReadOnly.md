# NodeFilesystemReadOnly

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

A filesystem on `instance` (the node IP plus `:9100`) was remounted
read-only. On these nodes that is usually the start of eMMC failure. The node
still reports Ready while everything on it slowly breaks.

## Confirm

```sh
q 'node_filesystem_readonly{fstype!~"tmpfs|ramfs|rootfs|overlay|squashfs|iso9660|nsfs|autofs"} == 1'
talosctl -n <ip> dmesg | grep -Ei 'mmc|ext4|xfs|i/o error|read-only' | tail -30
talosctl -n <ip> read /sys/class/mmc_host/mmc0/mmc0:0001/life_time
```

Expected while it fires: the mountpoint, and I/O or remount errors in the
kernel log. `life_time` is two hex steps (`0x01` low, `0x0b` worn out).

## Fix

1. A control plane: check etcd still has 3 members
   (`talosctl -n <other-cp-ip> etcd members`) and take a snapshot from a
   healthy one: `task talos:etcd-snapshot -- <other-cp-ip>`.
2. Move work away: `kubectl cordon <node>`.
3. Reboot once: `talosctl -n <ip> reboot`. Expected: back in
   `talosctl -n <ip> services` within minutes, the mount writable.
4. Read-only again, or I/O errors in `dmesg`: the eMMC is failing. It is
   soldered to the RK1 module, so the fix is a new module in that slot
   ([node-replacement.md](../node-replacement.md)). Leave the node cordoned
   until then.
5. After a clean reboot: `kubectl uncordon <node>`.

## Resolved when

The query returns nothing, the node is uncordoned and `dmesg` shows no new
I/O errors.

## Links

- [NodeEmmcEndOfLife](NodeEmmcEndOfLife.md)
- [talos-cheatsheet.md: Troubleshooting](../../talos-cheatsheet.md#4-troubleshooting)
