# NodeFilesystemCriticallyFull

`critical`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

`mountpoint` on `instance` has had less than 8% free for 10 minutes. The
kubelet starts evicting pods under disk pressure and new containers fail.

## Confirm

```sh
q 'node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs|rootfs|overlay|squashfs|iso9660|nsfs|autofs"} / node_filesystem_size_bytes < 0.08'
kubectl describe node <node> | grep -A6 Conditions
talosctl -n <ip> usage /var --depth 2 | sort -n | tail -15
```

Expected while it fires: under 0.08, and possibly `DiskPressure True`.

## Fix

Follow [NodeFilesystemNearlyFull](NodeFilesystemNearlyFull.md#fix), images
first: they are the fastest space to get back. If the node is already
evicting pods, cordon it while you clean (`kubectl cordon <node>`), then
`kubectl uncordon <node>`.

## Resolved when

Free above 8% (the warning clears above 15%), and `DiskPressure False`.

## Links

- [NodeFilesystemNearlyFull](NodeFilesystemNearlyFull.md)
