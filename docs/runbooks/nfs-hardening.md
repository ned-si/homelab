# NFS hardening (outstanding)

Carried over from the old README's terse `nfs: harden (!)`. Still true, still not
done — this is a tracked gap, not a completed task.

## The problem

`infrastructure/nfs-storage/nfs-volumes.yaml` mounts
`192.168.1.228:/mnt/homelab/k8s/nfs` with `nfsvers=4.1` and no authentication.

NFS without Kerberos authenticates by **IP address and UID**, nothing else. So:

- any host that can reach the NAS on port 2049 can mount the media library
- it presents whatever UID it likes, and the server believes it
- everything runs as UID 1000, so a single compromised container on the LAN reads
  and writes the whole library

The library is also the largest single thing in the homelab, and it is the one
volume not protected by iSCSI's implicit initiator-group scoping.

## What has been done in this repo

Partial mitigation only, at the consumer end:

- Plex and Jellyfin mount the share **read-only** (`readOnly: true` with
  `subPath: media`). They have no reason to write and now cannot.
- qBittorrent is restricted to `subPath: torrents`, so it cannot touch the
  library directly.
- The *arr apps still mount the whole share read-write, because hardlinking a
  download into the library requires exactly that. See the long comment in
  `nfs-volumes.yaml` about why the mount cannot be narrowed further.

None of that constrains a host outside the cluster.

## What still needs doing, on the TrueNAS side

Ordered by effort-to-benefit.

### 1. Scope the export to the node IPs (do this first)

In TrueNAS: **Shares → Unix (NFS) Shares →** the `k8s/nfs` share → **Advanced**.

Set **Networks** to the node subnet, or better, list the four node addresses
explicitly. Set **Hosts** likewise. This alone removes "any device on the LAN"
from the threat model.

Note this needs revisiting after the house move, since the node addresses change.

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

`mountOptions` currently include `hard`, which means I/O retries indefinitely if
the NAS disappears. That is the correct trade-off for a media library (stall
rather than corrupt), but it does mean a NAS outage wedges these pods until it
returns, and they cannot be killed cleanly. `soft` would trade corruption risk
for recoverability. Left on `hard` deliberately.
