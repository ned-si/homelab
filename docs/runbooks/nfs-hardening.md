# NFS hardening (outstanding)

An open gap, not a completed task: the media share is exported without
authentication. The steps below are the plan, in order.

## The problem

The theater workloads mount `192.168.1.228:/mnt/homelab/k8s/nfs` as inline NFS
volumes (`apps/theater/*.yaml`), without authentication.

NFS without Kerberos authenticates by **IP address and UID**, nothing else. So:

- any host that can reach the NAS on port 2049 can mount the media library
- it presents whatever UID it likes, and the server believes it
- everything runs as UID 1000, so a single compromised container on the LAN reads
  and writes the whole library

The library is also the largest single thing in the homelab, and it is the one
volume not protected by iSCSI's implicit initiator-group scoping.

### Two datasets, two positions

There are two NFS exports and only one of them is scoped.

| Dataset | Export | Consumers |
|---|---|---|
| `homelab/k8s/nfs` → `/mnt/homelab/k8s/nfs` | **open to the whole LAN.** This is the open item | the media library, `theater` |
| `homelab/k8s/backups` → `/mnt/homelab/k8s/backups` | scoped to `192.168.1.0/24`, owned uid/gid 1000, mode 0770 | the local backup tier (`infrastructure/nfs-storage/backup-volume.yaml`, not enabled yet) |

`infrastructure/nfs-storage/backup-volume.yaml` explains why they are separate
datasets: separate snapshot schedules and compression, separate fill-up risk,
and a scoped export for the copy you fall back to when the library is gone.

The work below is about the media dataset. `192.168.1.0/24` is also only a
subnet, not the four node addresses; tightening exports to the node list is
step 1.

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

## What still needs doing, on the TrueNAS side

Ordered by effort-to-benefit.

### 1. Scope the export to the node IPs (do this first)

In TrueNAS: **Shares → Unix (NFS) Shares →** the `k8s/nfs` share → **Advanced**.

List the four node addresses (`192.168.1.247`, `.238`, `.239`, `.240`)
explicitly under **Hosts** rather than putting the subnet in **Networks**: the
subnet still includes every laptop and phone in the house.

This alone removes "any device on the LAN" from the threat model. The node
addresses are site-specific
([architecture.md](../architecture.md#site-specific-values)), so redo it if they
change.

### 2. Turn off `maproot`

Confirm the export is **not** configured with `Maproot User: root`. If it is,
every client is root on the share, and the read-only mounts above are the only
thing standing between a container and the library.

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
