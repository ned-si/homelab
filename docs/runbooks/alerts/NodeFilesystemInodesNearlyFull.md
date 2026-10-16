# NodeFilesystemInodesNearlyFull

`warning`, pages. Rule: [`platform/kube-prometheus-stack/routes/alerts.yaml`](../../../platform/kube-prometheus-stack/routes/alerts.yaml).
Shell: [Before you start](README.md#before-you-start). Needs the LAN.

## What it means

`mountpoint` on `instance` has under 10% of its inodes free. Inodes run out
independently of bytes: writes fail with `ENOSPC` while there is free space.
On the eMMC that is usually many small files in containerd layers or in a
pod's `emptyDir`.

## Confirm

```sh
q 'node_filesystem_files_free{fstype!~"tmpfs|ramfs|rootfs|overlay|squashfs|iso9660|nsfs|autofs"} / node_filesystem_files < 0.10'
talosctl -n <ip> image list | wc -l
```

Expected while it fires: the ratio under 0.10.

## Fix

1. Remove unused images
   ([NodeFilesystemNearlyFull](NodeFilesystemNearlyFull.md#fix) step 1):
   every layer holds thousands of files.
2. A pod creating many small files in an `emptyDir` or a cache: list the
   largest pod directories (named by pod UID), then clean that pod's cache
   or restart it:

   ```sh
   talosctl -n <ip> usage /var/lib/kubelet/pods --depth 1 | sort -n | tail -5
   kubectl get pods -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,UID:.metadata.uid | grep <uid>
   ```

## Resolved when

Free inodes above 10%; the alert clears after 30 minutes.

## Links

- [NodeFilesystemNearlyFull](NodeFilesystemNearlyFull.md)
