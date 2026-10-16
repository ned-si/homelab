# NodeFilesystemNearlyFull

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

`mountpoint` on `instance` (the node IP plus `:9100`) has had less than 15%
free for 30 minutes. On these nodes the 29 GB eMMC holds the kubelet and
containerd data (`/var`); full means no image pulls and no new containers,
while the node still reports Ready.

## Confirm

```sh
q 'node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs|rootfs|overlay|squashfs|iso9660|nsfs|autofs"} / node_filesystem_size_bytes < 0.15'
talosctl -n <ip> usage /var --depth 2 | sort -n | tail -15
talosctl -n <ip> image list | wc -l
```

Expected while it fires: the mountpoint, and the directories that hold the
space in bytes, relative to `/var` (usually `lib/containerd` or `log`).

## Fix

1. Unused images: list them and remove the old tags of images that have a
   newer one running (`kubectl get pods -A -o wide | grep <node>` shows what
   runs there):

   ```sh
   talosctl -n <ip> image list | grep <repository>
   talosctl -n <ip> image remove <image-ref>
   ```

   The kubelet also garbage-collects images above 85% disk use; removing by
   hand is for when it cannot keep up.
2. Container logs: a pod that logs in a loop. Find it in
   `talosctl -n <ip> usage /var/log/pods --depth 1 | sort -n | tail` and
   fix its log level or restart it.
3. `emptyDir` volumes (`/var/lib/kubelet/pods`): a pod that writes a scratch
   volume without a `sizeLimit`. Set one in git.

## Resolved when

Free above 15%; the alert clears after 30 minutes.

## Links

- [NodeFilesystemCriticallyFull](NodeFilesystemCriticallyFull.md)
- [talos-cheatsheet.md: Troubleshooting](../../talos-cheatsheet.md#4-troubleshooting)
