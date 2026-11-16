# NFS hardening

Both NFS exports accept only the four node addresses (step 1, done
2026-11-16). They still have no authentication beyond the client's address;
steps 2-5 are the remaining options, in order.

## The problem

The theater workloads mount `192.168.1.228:/mnt/homelab/k8s/nfs` as inline NFS
volumes (`apps/theater/*.yaml`), without authentication.

NFS without Kerberos authenticates by **IP address and UID**, nothing else. So:

- any host that reaches the NAS on port 2049 from an allowed address can mount
  the media library
- it presents whatever UID it likes, and the server believes it
- everything runs as UID 1000, so a single compromised container on the LAN reads
  and writes the whole library

The library is also the largest single thing in the homelab.

### Two datasets, two positions

There are two NFS exports, both limited to the node addresses.

| Dataset | Export | Consumers |
|---|---|---|
| `homelab/k8s/nfs` → `/mnt/homelab/k8s/nfs` | hosts `192.168.1.247`, `.238`, `.239`, `.240`; maproot `nobody:nogroup` | the media library, `theater` |
| `homelab/k8s/backups` → `/mnt/homelab/k8s/backups` | the same four hosts; maproot `root:wheel`; owned uid/gid 1000, mode 0770 | the CronJob `immich/immich-library-backup-local`, which mounts it inline (`apps/immich/resources/backup-files.yaml`) and writes the NAS restic repository of the photo library; the `nfs-storage` leaf declares its PV/PVC pairs (`infrastructure/nfs-storage/backup-volume.yaml`), not mounted by anything yet |

`infrastructure/nfs-storage/backup-volume.yaml` explains why they are separate
datasets: separate snapshot schedules and compression, separate fill-up risk,
and a scoped export for the copy you fall back to when the library is gone.

The address list is the only control: a LAN device that takes a node's
address can still mount either export and, as uid 1000, delete the NAS copy
of the photo library.

### What network policy does not cover

Enforcing `infrastructure/network-policies/` does **not** help here, and it is worth
knowing why before assuming it does. `nfs:` PersistentVolumes and democratic-csi's
iSCSI volumes are attached by the kubelet and `iscsid` in the **host** network
namespace, before the container starts. `CiliumNetworkPolicy` selects pods, so it
never sees those packets. Policy stops a *pod* reaching the NAS; only the export
allow-list stops a *node* or any other host on the LAN.

## Consumers today

| Workload | Export path | Mode |
| --- | --- | --- |
| Plex, Jellyfin | `/mnt/homelab/k8s/nfs/media` | read-write (read-only is on the [roadmap](../roadmap.md)) |
| qBittorrent | `/mnt/homelab/k8s/nfs/torrents` | read-write |
| Sonarr, Radarr, Lidarr | `/mnt/homelab/k8s/nfs` | read-write: hardlinking a download into the library needs both trees on one mount |

Narrowing these mounts limits what a compromised container can reach. It does
not constrain any host outside the cluster.

## The TrueNAS side

Ordered by effort-to-benefit.

### 1. Scope the exports to the node IPs (done 2026-11-16)

In TrueNAS: **Shares → Unix (NFS) Shares →** the `k8s/nfs` share → **Advanced**,
then the same for the `k8s/backups` share. The four node addresses
(`192.168.1.247`, `.238`, `.239`, `.240`) are listed under **Hosts**, and
**Networks** is empty: a subnet would include every laptop and phone in the
house.

The node addresses are site-specific
([architecture.md](../architecture.md#site-specific-values)). A node with a
new address gets "permission denied" on mount until its address is added
here, so redo it if they change.

Check from the Mac:

```sh
showmount -e 192.168.1.228
```

Expected: both exports, each with `192.168.1.240 192.168.1.239 192.168.1.238
192.168.1.247` and nothing else.

### 2. `maproot`

The media export maps root to `nobody:nogroup`. The backups export maps root
to `root:wheel`: `immich-library-backup-local` writes as root, and clearing it
would map those writes to `nobody` and break the backup. A client with a node
address is root on that share.

### 3. Squash to a dedicated UID

Set **Mapall User / Mapall Group** to the `1000` account that owns the media,
rather than trusting client-supplied UIDs. This makes the UID claim irrelevant.

### 4. NFSv4 with Kerberos (the real fix)

`sec=krb5p` gives authentication and encryption. It also means running a KDC and
keytabs on every node, which for a four-node homelab is a genuine project rather
than an afternoon. Reasonable to defer, but it is the only option that actually
authenticates rather than approximating it with IP allow-lists.

### 5. Consider moving media to iSCSI

iSCSI is already used for every other volume via democratic-csi, and TrueNAS
scopes iSCSI targets by initiator group. The reason media is on NFS is
`ReadWriteMany` — several pods mount it at once, and iSCSI block volumes are
`ReadWriteOnce`.

That constraint is real, so this is not a straightforward swap. It would mean one
pod owning the filesystem and re-exporting it, which just moves the problem.

## Related

The NFS mounts are `hard`, which means I/O retries indefinitely if the NAS
disappears. That is the correct trade-off for a media library (stall
rather than corrupt), but it does mean a NAS outage wedges these pods until it
returns, and they cannot be killed cleanly. `soft` would trade corruption risk
for recoverability. Left on `hard` deliberately.
