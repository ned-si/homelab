# Design: nas-on-truenas-scale

## Overview

The NAS moves from TrueNAS CORE 13.0-U6.7 to TrueNAS Community Edition
25.10.8 in place, on the same hardware, boot SSD and pool, through the UI
update path (24.04.2.5, 24.10.2.4, 25.04.2.6, 25.10.8). The cluster side
changes before the window and works on both systems: the democratic-csi
driver config drops its FreeBSD paths, `truenas-exporter` tolerates the
endpoints 25.10 removed, and a small CronJob keeps every iSCSI target
limited to the four nodes on SCALE. In the window, with the operator at
home, the stateful workloads stop, the backups and a recursive pool
snapshot are taken, the CORE boot SSD is imaged on the Mac, and the four
updates run. Two scripts make the window deterministic:
`scripts/nas-check.py` (read-only checks of the NAS against a recorded
baseline) and `scripts/nas-maintenance.sh` (stop, canary, start). The way
back to CORE is the boot image, valid while no pool feature is enabled.
The same window flashes the BMC to v2.1.0 (#1307) with every node shut
down, right after the stateful workloads stop and before the NAS changes
([BMC firmware in the same stop](#bmc-firmware-in-the-same-stop)).

Technology, locked by this design: TrueNAS REST API v2.0 (still served by
25.10), Python 3 standard library for `nas-check.py` and the guard, bash
3.2 with `kubectl` and `jq` for `nas-maintenance.sh`, democratic-csi
v1.9.5 with chart 0.15.1 (unchanged), the existing `truenas-exporter`
image, pytest and the bash test harness in `tests/`.

## Research

Read on 2026-11-16.

| Source | What it says |
| --- | --- |
| [TrueNAS Software Status](https://www.truenas.com/docs/softwarestatus/) | General users: 25.10.8 (2026-11-05). Mission critical: 25.10.7. TrueNAS 27 is at RC.1 (2026-10-06). Upgrade chart: 13.0-U6.8 goes by `update` to 24.04.2.5 or by `ISO install` to 25.10.8; then 24.04.2.5 → 24.10.2.4 → 25.04.2.6 → 25.10.8, each by `update`. Update to the latest maintenance release of a major version before the next one. |
| [Migrating from CORE](https://www.truenas.com/docs/scale/25.10/gettingstarted/migrate/) | 13.0-U6.8 is CORE's last release (13.3-U1.2 the last of 13.3). A UI migration is supported to 24.04 only; 24.10 and later need a clean install plus configuration upload. |
| [Preparing to Migrate](https://www.truenas.com/docs/scale/25.10/gettingstarted/migrate/migrateprep/) | One-way: "Attempting to activate or roll back to a FreeBSD-based TrueNAS boot environment can break the system." Asks for "the latest publicly-available release version, 13.0-U6.7". Does not migrate: plugins and jails, NIS, system tunables, ZFS boot environments, SMB auxiliary parameters, OneDrive credentials, GELI encryption, malformed certificates (replaced by a self-signed one), the `netcli` shell, SAS multipath, GRUB-booted VMs, SSH rsync tasks; SSH connections may need recreating. Prerequisites: root not locked, no username starting with a digit, no user-created account below UID 1000, record network settings (interface names change), deprecated services (DDNS, OpenVPN, rsyncd, TFTP, WebDAV, S3) off, save the configuration and a debug file. "Linux Debian systems require at least one LUN set to zero. iSCSI portals … are defined globally." |
| [Community Migrations](https://www.truenas.com/docs/scale/25.10/gettingstarted/migrate/migrate-community/) | The manual update to 24.04: System > Update > Install Manual Update File, save the configuration, temporary location memory or pool, Apply. "TrueNAS automatically renames components, such as disks and interfaces … igb0 … is updated to eno1 … the Description igb0 is retained." Reverting to CORE: clean-install CORE and upload the configuration. |
| [Component Naming](https://www.truenas.com/docs/scale/25.10/gettingstarted/migrate/componentnaming/) | Disks become `sd*` (NVMe stays numbered), interfaces `eno*`/`enp*` by PCI location. |
| [25.10 version notes](https://www.truenas.com/docs/scale/25.10/gettingstarted/versionnotes/) | REST API deprecated since 25.04, "full removal is planned for TrueNAS 27", with a daily alert when deprecated endpoints are called. The built-in SMART test scheduling and SMART UI are removed (smartmontools stays). SMB shares without a preset move to the "Legacy Share" preset, which keeps guest access. 25.10.8: kernel 6.12.113, OpenZFS 2.3.9, Samba 4.22.10. |
| [Hardware guide](https://www.truenas.com/docs/scale/25.10/gettingstarted/scalehardwareguide/) | Minimum: 2-core x86-64, 8 GB RAM, 16 GB SSD boot device; USB sticks and spinning boot disks discouraged. |
| [API v25.10](https://api.truenas.com/v25.10/) | `iscsi.initiator` has only `initiators` and `comment`; `iscsi.target` has `auth_networks`, "network addresses allowed to access this target". `sharing.nfs` keeps `hosts`, `networks`, `maproot_*`, `mapall_*` (no `alldirs`). `api_key.create` requires a `username`. |
| [BMC-Firmware releases](https://github.com/turing-machines/BMC-Firmware/releases), [v2.x to v2.x upgrade](https://docs.turingpi.com/docs/turing-pi2-bmc-v2x-to-v2x), [v2.1 network migration](https://docs.turingpi.com/docs/v20-to-v21-migration) | v2.1.0 (2025-02-05) is the latest release; OTA `.tpu` and SD-card image, no published checksum. The OTA is verified on the BMC and reverted if verification fails; a reboot applies it. `tpi reboot`: the nodes lose power until the BMC has booted. The 2.1 network change only affects a BMC whose `/etc/network/interfaces` was edited; the page gives a shell test that prints `Not affected` otherwise. v2.1.0 switches to OUI-assigned MAC addresses, so the BMC's DHCP lease is expected to change. |
| [democratic-csi](https://github.com/democratic-csi/democratic-csi) README, [CHANGELOG](https://github.com/democratic-csi/democratic-csi/blob/master/CHANGELOG.md), [examples/freenas-iscsi.yaml](https://github.com/democratic-csi/democratic-csi/blob/master/examples/freenas-iscsi.yaml) | v1.9.5 (2026-01-07) "support SCALE-25.04", "support SCALE-25.10". `freenas-iscsi` works on CORE and SCALE; `freenas-api-*` are "EXPERIMENTAL". The example config: "leave paths unset for auto-detection". |

What this means here:

- **Path.** The clean install needs the installer's console. This NAS has
  none ([cold-start.md, facts](../../../docs/runbooks/cold-start.md#facts-this-runbook-relies-on)):
  a console means pulling the network card for a graphics card. The UI
  path needs no console, so it is the path. It costs four updates and
  reboots instead of one.
- **Start version.** The operator skips 13.0-U6.8. The preparation page
  itself names 13.0-U6.7; the chart names U6.8. If the CORE updater rejects
  the 24.04.2.5 file, CORE goes to 13.0-U6.8 in the window (one more update,
  about 15 minutes) and the migration continues.
- **Rollback.** A CORE boot environment is not a way back. The way back is
  the CORE boot device itself, so the window images it first.
- **What does not migrate**, checked for this NAS in task 1 from the
  baseline: jails and plugins (expected none), tunables (recorded; FreeBSD
  tunables are dropped, not translated), SMB auxiliary parameters (none on
  2026-11-16), init/shutdown scripts and cron jobs (recorded), deprecated
  services (must be stopped; only `cifs`, `nfs`, `iscsitarget` and `ssh`
  ran on 2026-11-16), user names and UIDs (recorded), the network settings
  (recorded; the rename is automatic).

### Hardware fit

| Part | Today (exporter, `system/info`, cold-start facts) | Target version |
| --- | --- | --- |
| Board, CPU | Gigabyte B550I AORUS PRO AX, AMD Ryzen 5 3600 (6 cores), no integrated GPU | x86-64, above the minimum; no console, as today |
| Memory | 32 GB, non-ECC | Above the 8 GB minimum; non-ECC as today |
| Boot device | Kingston A400 120 GB SATA SSD (`ada1`, boot pool on `ada1p2`) | SSD above the 16 GB minimum; kept |
| Pool `homelab` | RAIDZ1 of five Micron 5210 7.68 TB SATA SSDs (`ada0`, `ada2`-`ada5`) | AHCI; disks renamed `sd*` |
| L2ARC | Transcend TS128GMTE110S NVMe (`nvd0`), failing | Imports; renamed `nvme0n1`; removal is out of scope |
| Network | Digitus PCIe card, Intel `igb` family, port `igb0` (MAC `…B8:28`) static `192.168.1.228`; second port `igb1` unused; onboard Intel 2.5 GbE has no CORE driver | Linux `igb`; `igb0` renamed to an `en*` name and keeps its address. The onboard port gains a Linux driver (`igc`) and stays unconfigured |

Task 1 confirms the table from the CORE debug file (`pciconf -lv`): every
PCI device must have a Linux driver in kernel 6.12. A device without one
stops the migration before the window.

## Method

### The update chain

Each step uploads a manual update file from the Mac through the web UI
(System > Update > Install Manual Update File, temporary location
"Memory Device", 32 GB RAM is enough). Manual files, not the online train,
so each version is the exact one in the chart and its SHA-256 is checked
on the Mac first. Task 6 records the download URL and SHA-256 of each file
in the runbook.

| Step | From | File | Check after the reboot |
| --- | --- | --- | --- |
| U1 | 13.0-U6.7 | 24.04.2.5 | ping, `:443`, UI login, pool ONLINE, the `en*` interface holds `.228` |
| U2 | 24.04.2.5 | 24.10.2.4 | the same |
| U3 | 24.10.2.4 | 25.04.2.6 | the same |
| U4 | 25.04.2.6 | 25.10.8 | `nas-check.py --expect scale` |

The cluster stays stopped through all four: one outage instead of four,
and no workload sees an intermediate version. Each step keeps the previous
Linux boot environment, so U2 to U4 can be undone in the UI (System >
Boot, activate the previous one, reboot) without leaving SCALE.

The UI shows an "upgrade pool" prompt and the alert list a new-features
alert once the pool runs on OpenZFS 2.3. Both are ignored. No step runs
`zpool upgrade`, and `nas-check.py` compares the pool's feature flags with
the baseline after every step from U1 on.

### Why not let the apps wait

The cold-start runbook lets the cluster wait on a NAS outage, and it
recovered alone after the 9 h outage of 2026-11-15. A planned window is
different: five reboots in about two hours, each one an abrupt end of
every iSCSI session (XFS shuts a filesystem down when I/O fails past the
initiator timeout) and a hang of every `hard` NFS mount. Stopping the
stateful workloads first unmounts every volume cleanly, shuts the
databases down cleanly, logs every iSCSI session out, and lets the
migration start from a quiet pool, which also makes the snapshot
consistent. The cost is a script and its tests.

### BMC firmware in the same stop

The BMC runs firmware 2.0.5 (OpenSSH 9.3, L5). Applying the v2.1.0 OTA
needs a BMC reboot, and on 2.0.5 that reboot cuts power to the four node
slots until the BMC is back. v2.1.0 keeps the nodes powered across BMC
reboots (BMC-Firmware PR #207), but the reboot out of 2.0.5 still runs
the old code. So the
flash needs every node shut down first, and the NAS window already has
the cluster stopped.

Its place is window step 5: after `down` and the quiesced check (step
4), before the pool snapshot (step 6).

- The stateful workloads are already stopped, so the shutdown only stops
  stateless pods. `down`'s state survives the reboot: Argo CD sync stays
  paused, replicas at 0, CNPG hibernated, CronJobs suspended.
- The NAS is still untouched CORE. A BMC or node failure stops the window
  with nothing on the NAS changed: recover the cluster, `up` on CORE, and
  move the migration to another weekday. The migration never runs on a
  cluster whose cold boot just failed.
- The cold boot of all four nodes is proven before the canary and `up`
  depend on the cluster.

Overlapping the flash with the boot-image read (step 9) would save about
20 minutes, but it puts two failure domains and two hands-on tasks in
the same half hour. After `up` would need a second stop of every app.

The step takes about 30 minutes: node shutdown 5, OTA transfer and
verification 5, BMC reboot 2, power-on to four nodes Ready and etcd
healthy 10 to 15, checks 5. The window grows from about 3 h to about
3.5 h (09:00 to about 12:30 Zurich); the 14:00 stop rule stays. For those
30 minutes every app is down, the website and the apps without storage
included.

The control planes shut down in one `talosctl` call so etcd stops on all
three together, and no member waits on a quorum the others already
left. `homelab-w-1` goes first, while the control planes still serve the
API for its drain.

Risks:

- The 2.1 network migration rewrites only an edited
  `/etc/network/interfaces`; the day-before test confirms it is not.
- The on-board switch gains DSA support: the node links may drop for a
  moment while the BMC boots. The nodes are off then.
- The new MAC gives the BMC a new DHCP lease. The `blackbox-lan` probe
  pings `192.168.1.194` and `LANDeviceUnreachable` pages, so the new
  address goes into `lan.yaml` and `docs/networking.md` in a PR merged
  before `up` (Argo CD sync is paused until then); `up` deploys it before
  the unfreeze. That PR closes #1307.
- The BMC does not boot: the nodes stay unpowered. The recovery is the
  v2.1.0 SD-card image (`tp2-firmware-sdcard-v2.1.0.img`), downloaded the
  day before, written to a microSD card and booted per the Turing Pi
  firmware-upgrade guide (operator).

## Scripts and cluster changes

### `scripts/nas-check.py`

Read-only. Python 3 standard library only, so it runs on the Mac without
packages (`homelab-context`: no PyYAML).

Usage:

```
scripts/nas-check.py --record <dir>
scripts/nas-check.py --expect core|scale --baseline <dir> [--quiesced]
    [--snapshot <name>] [--features-file <file>] [--only <check>,...]
```

`--snapshot <name>` adds the `snapshot` check. `--features-file` reads
the feature flags from a file (the output of `zpool get -H -o
property,value all homelab` pasted from the UI shell) instead of SSH, for
when SSH is broken. `--only` runs the named checks only (the
post-update `version,pools,features`).

Inputs and validation:

| Input | Rule | On failure |
| --- | --- | --- |
| API key, SSH user and key | Read in memory from Secret `democratic-csi/iscsi-democratic-csi-driver-config`, key `driver-config-file.yaml` (`kubectl get secret -o jsonpath`), parsed with line rules for `apiKey:`, `sshConnection.username:` and the `privateKey: \|` block | Exit 2, "cannot read the driver config", nothing else printed |
| NAS CA | `extraCaCerts` block of `infrastructure/democratic-csi/values-iscsi.yaml` | Exit 2 |
| `--baseline` | Directory written by `--record`, with `meta.json` version 1 | Exit 64 |
| `--expect` | `core` or `scale` | Exit 64 |

What it reads: REST v2.0 over HTTPS with the CA verified and a 10 s
timeout per call (`system/info`, `pool`, `boot/get_state`, `service`,
`sharing/nfs`, `sharing/smb`, `iscsi/target`, `iscsi/initiator`,
`iscsi/global`, `iscsi/global/sessions`, `network/interface`,
`network/configuration`, `system/general`, `certificate`, `user`,
`tunable`, `pool/dataset`, `nfs` (the service config), `cronjob`,
`initshutdownscript`, `plugin` and `jail` on CORE, where a 404 is
recorded as "absent"; `zfs/snapshot` only with `--snapshot`). Over SSH,
with the key in a throwaway `ssh-agent` killed on exit: `sudo zpool get
-H -o property,value all homelab` (feature flags). The TLS certificate's
SHA-256 fingerprint from the handshake. TLS verifies the chain against
the CA and the IP SAN `192.168.1.228`, as democratic-csi does; no
hostname is used. One plain `http://192.168.1.228/` request (no
redirect follow) for the `ui` check.

`--record` writes one JSON file per endpoint plus `features.txt`,
`fingerprint.txt` and `meta.json`. Before writing, the value of every key
whose name ends in `privatekey`, `private_key`, `hash` (the user
endpoint's `unixhash` and `smbhash`), `password` or `secret`, at any
depth, is replaced by `"<redacted>"`. The users' `sshpubkey` (a public key) is
kept: it is the source for the SSH fix in the window. The directory goes
under `~/homelab-backups/nas/`.

`--expect` normalises CORE and SCALE field names and prints one
`PASS`/`FAIL <reason>` line per check. Normalisation:

- NFS: CORE `paths` list, SCALE `path`.
- iSCSI limit: CORE initiator group `auth_network`, SCALE target
  `auth_networks`.
- SMB, to `{path, hostsallow, guest}`: CORE and 24.04 to 25.04 have
  top-level `hostsallow` and `guestok`; 25.10 has `purpose`
  (`LEGACY_SHARE` after the migration) and both fields under `options`
  ([API v25.10, `sharing.smb.create`](https://api.truenas.com/v25.10/api_methods_sharing.smb.create.html)).
- NFS service: CORE `v4` true, SCALE `protocols` contains `NFSV4`.

A field missing from both places is a FAIL naming the field, never read
as false or empty. The pytest fixtures carry each shape.

| Check | Rule |
| --- | --- |
| version | `system/info.version`: CORE matches `^TrueNAS-13\.0-U6\.[78]$`; scale equals `25.10.8` exactly |
| pools | `homelab` and the boot pool ONLINE and healthy |
| features | Every `feature@` that is `enabled` or `active` now was `enabled` or `active` in the baseline (`enabled` to `active` passes). Features new to the version and `disabled` pass |
| services | `cifs`, `nfs`, `iscsitarget`, `ssh` running and enabled; NFSv4 on |
| nfs | Same export paths as the baseline; `hosts` = the four nodes; `networks` empty; `maproot_user`/`maproot_group` equal to the baseline or resolving to the same uid/gid (`wheel` → `root`, gid 0) |
| smb | Share `bits_and_pieces`: path unchanged, `hostsallow` `["192.168.1.0/24"]`, `guest` true |
| iscsi | Target names equal to the baseline; each target limited to the four nodes (CORE: through initiator group 1; scale: its `auth_networks`, `/32` each); portal on `0.0.0.0:3260` |
| tls | Fingerprint equal to the baseline; chain and IP SAN verify against the CA |
| ui | `ui_httpsredirect` true; `http://192.168.1.228/` answers 301 or 302 to `https://`; `GET /` over HTTPS has a `Strict-Transport-Security` header |
| quiesced (`--quiesced`) | Zero iSCSI sessions |
| snapshot (`--snapshot <name>`) | Every dataset and zvol of `homelab` in `pool/dataset` has `<dataset>@<name>` in `zfs/snapshot` |

Exit codes: 0 all PASS, 1 a FAIL, 2 NAS or API unreachable, 401, TLS
error or SSH failure, 64 usage. Errors print the endpoint and the HTTP
status or exception class, never a header or the key.

### `scripts/nas-maintenance.sh`

Bash 3.2, `kubectl`, `jq`. Runs on the Mac with the operator kubeconfig.

```
scripts/nas-maintenance.sh plan
scripts/nas-maintenance.sh down
scripts/nas-maintenance.sh up <state-file>
scripts/nas-maintenance.sh canary [--hold-guard]
scripts/nas-maintenance.sh status
```

`plan` computes, without changing anything, the set of stateful
workloads: every pod whose volumes include a PVC bound to a PV of class
`iscsi` or `iscsi-retain`, a PV with `spec.nfs.server` `192.168.1.228`, or
an inline `nfs` volume on that server; plus every CronJob whose job
template has such a volume. One rule for `plan`, `down` and `status`: a
pod counts only in phase `Pending` or `Running`, or `Unknown` with a
`deletionTimestamp`; a Job counts only while `status.active > 0`.
Finished pods and Jobs (kept by the history limits) are listed as
"finished, ignored". Each counted pod is followed up its owners to the
object to act on:

| Owner chain | Action in `down` | Recorded |
| --- | --- | --- |
| ReplicaSet → Deployment | scale to 0 | `spec.replicas` |
| StatefulSet without controller owner | scale to 0 | `spec.replicas` |
| StatefulSet → `Prometheus` | `spec.replicas: 0` on the CR | `spec.replicas` |
| StatefulSet → `ClickHouseInstallation` | `spec.stop: "yes"` | `spec.stop` |
| CNPG `Cluster` | annotation `cnpg.io/hibernation=on` | the annotation |
| CronJob | `spec.suspend: true` | `spec.suspend` |
| Job without CronJob, or any other kind | none | `plan` exits 3, "unknown owner" |

On 2026-11-16 that is 17 Deployments, the StatefulSets `syncthing`,
`signoz`, `signoz-zookeeper`, the Prometheus `kube-prometheus-stack-prometheus`,
the ClickHouseInstallation of SigNoz, the eight CNPG clusters and the
backup CronJobs. The `nas-watch` Prometheus, Alertmanager and democratic-csi
have no NAS volume and stay. Added by name, without a NAS volume:
CronJob `democratic-csi/nas-iscsi-guard` (suspended, so the guard makes
no write on 24.04 to 25.04; step 12 runs it once by hand).

`prometheus-operator` scaling the StatefulSet to 0 on `spec.replicas: 0`
is checked live once in task 2 (`down` then `up` of that object only, on
CORE). If it does not, the action becomes `spec.paused: true` on the CR
plus scaling its StatefulSet to 0, both recorded.

`plan` also prints the daily backup set with each job's
`status.lastSuccessfulTime`, and marks it `today` when that is after
00:00Z on the day. The set is the names in `ci/active-cronjobs.txt`
containing `-backup`, minus `backup-verify-*`; the prune, `*-nightly`,
`paperless-canary`, `vuln-enrich` and other weekly or monthly jobs are
outside it. The window's precondition is every job of the set `today`.

`down`:

1. Runs `plan`; exits 3 if a Job that mounts a NAS volume is active (a
   backup still running) or an owner is unknown. Prints the plan.
2. Disables Argo CD automated sync with `kubectl -n argo patch
   application <name> --type json -p
   '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'`, recording
   each removed block, in this order: `root`; then `layer-infrastructure`,
   `layer-platform`, `layer-apps`, waiting until each shows no
   `automated`; only then every other Application in `argo`. A layer
   with `selfHeal` would otherwise put a leaf's block back. The bash test
   asserts the order.
3. Applies the actions in the table, recording the previous value of each
   field.
4. Writes the state file `~/homelab-backups/nas-maintenance/<utc>.json`
   after each change (an interrupted run leaves a usable record).
5. Waits up to 15 minutes until no pod mounts a NAS volume and no
   VolumeAttachment of attacher `org.democratic-csi.iscsi` exists; exit 1
   listing what remains on timeout.

`up <state-file>` reverses the state file: CronJobs, CNPG annotations,
ClickHouse and Prometheus fields, StatefulSet and Deployment replicas to
their recorded values; waits up to 20 minutes for the workloads to be
Ready and the CNPG clusters `Cluster in healthy state`. Five minutes
after the CNPG clusters are healthy, it runs `kubectl rollout restart` on
every Deployment and StatefulSet in the cluster that is still not Ready
(Keycloak and other database clients in crash-loop back-off), once, and
logs each. Then it restores the recorded `automated` blocks, apps first,
layers next, `root` last. Exit 1 on timeout with the list; Argo CD is
restored in every case, so `up` can be re-run.

`canary` proves the storage path end to end, in namespace
`backup-verify` (it already mounts the NAS over NFS, so the Kyverno
exceptions and network policies allow it). It creates PVC
`nas-canary` (`iscsi`, 1 GiB) and a pod, non-root by choice under the
namespace's `baseline` Pod Security level, that writes 64 MiB of random
data, `sync`s, reads it back and compares the SHA-256; expands the PVC to
2 GiB and checks the filesystem grew. With `--hold-guard` (on SCALE, in
step 13) it then keeps the PVC and polls the canary target's
`auth_networks` through the API (key read from the driver Secret in
memory, as `nas-check.py` does) every 30 s for up to 15 minutes; it
passes when the target carries exactly the four `/32` addresses. Then it
deletes pod and PVC and waits for the PV to be gone.
A second pod mounts the four NFS paths read-only (`/mnt/homelab/k8s/nfs`,
`…/nfs/media`, `…/nfs/torrents`, `/mnt/homelab/k8s/backups`) and fails
unless each is non-empty, and unless `media/` and `torrents/` are
non-empty through the parent `/mnt/homelab/k8s/nfs` mount (a child
dataset without `crossmnt` shows as an empty directory there, and an
empty library makes Sonarr and Radarr mark everything missing). It
cannot prove the backups export's `maproot` mapping (the photo-library
backup writes as root); `nas-check.py`'s `nfs` check and the next night's
`immich-library-backup-local` run do. Every object carries label
`app.kubernetes.io/name: nas-canary`; on any failure the script deletes
them and exits 1 with the failing step. Timeouts: 5 minutes per step,
15 for the guard poll.

`status` prints the counts `down` waits on and the active state file.

Exit codes: 0 done, 1 timeout or failed step, 2 `kubectl` error, 3
precondition, 64 usage. Logs go to stderr with UTC timestamps.

### `scripts/nas-boot-image.sh`

Bash 3.2, `diskutil`, `dd`, `gzip`, `shasum`, on the Mac. It guards the
one write in the rollback: `dd` onto the wrong device destroys it, and
the five pool disks are SATA SSDs too.

```
scripts/nas-boot-image.sh read <disk> <dir>
scripts/nas-boot-image.sh verify <disk> <dir>
scripts/nas-boot-image.sh restore <disk> <dir>
```

- `<disk>` is `diskN` as `diskutil list` shows it; anything else exits 64.
- Every command first refuses (exit 3) a disk that `diskutil info -plist`
  reports as `Internal` true, or whose `TotalSize` is not between 100 and
  130 GB (the 120 GB Kingston), then runs `diskutil unmountDisk`.
- `read` saves `diskutil info -plist` as `core-boot.device.plist` (media
  name, `TotalSize`, the serial when the adapter passes it through), then
  `dd if=/dev/rdiskN bs=4m | gzip -1 > core-boot.img.gz`, and writes
  `core-boot.img.sha256` (the SHA-256 of the raw stream).
- `verify` reads the device a second time and compares its SHA-256 with
  `core-boot.img.sha256`; exit 1 on a mismatch.
- `restore` refuses (exit 3) unless `TotalSize` and `MediaName` equal the
  recorded plist (and the serial, when recorded), prints the device and
  asks for the disk identifier typed again, writes with `gunzip -c
  core-boot.img.gz | dd of=/dev/rdiskN bs=4m`, then runs `verify`.

Bash tests run it against fake `diskutil`, `dd` and `shasum` and assert
each refusal. When the SSD is attached, macOS shows "The disk you
attached was not readable by this computer": click **Ignore**, never
**Initialize**.

### democratic-csi config

The driver keeps `driver: freenas-iscsi`, the CSI driver name
`org.democratic-csi.iscsi`, release `iscsi` and both StorageClasses: every
existing PV refers to them. The SOPS Secret
`infrastructure/secrets/democratic-csi-iscsi.sops.yaml` loses its
`zfs.cli.paths` block, so the driver detects the `zfs`, `zpool`, `sudo`
and `chroot` paths on each system (upstream example). Everything else
stays: `httpConnection` (HTTPS, port 443, `allowInsecure: false`,
`apiVersion: 2`), `sshConnection`, `datasetParentName: homelab/k8s/v`,
the iSCSI target groups (portal 1, initiator group 1, no auth). The
`.example` template follows, and its stale `allowInsecure` comment is
corrected (#1371 made it `false`).

This change lands before the window and is proven on CORE by the canary.
After a merge the controller and node pods restart
(`kubectl -n democratic-csi rollout restart deploy/iscsi-democratic-csi-controller
ds/iscsi-democratic-csi-node`), because the chart puts no checksum of an
existing Secret on the pods.

If `sshConnection.username` is not `root` and the config enables sudo,
the NAS user's "Allowed sudo commands with no password" lists the CORE
paths. Task 3 adds `/usr/sbin/zfs` and `/usr/sbin/zpool` next to them on
CORE (a missing path in sudoers is harmless), so the migrated user works
on SCALE without an edit in the window. Task 8 removes the CORE paths.

SCALE switches iSCSI from `ctld` to SCST. TrueNAS migrates targets,
extents and the global base name, so the target IQNs the PVs record stay
the same; `nas-check.py` compares the target names. Every democratic-csi
target maps its extent as LUN 0, which SCST requires.

### iSCSI limited to the four nodes

On CORE the limit is initiator group 1's `auth_network` (2026-11-16, L2).
SCALE has no network field on initiator groups; the same limit is the
target's `auth_networks`. Whether TrueNAS carries group 1's networks onto
each target is not documented, and democratic-csi never sets
`auth_networks` on the targets it creates. So the limit is kept by the
cluster:

- CronJob `nas-iscsi-guard` in `democratic-csi`, every 10 minutes,
  `concurrencyPolicy: Forbid`, the exporter's image and security context,
  script `platform/truenas-exporter/iscsi_guard.py`. It reads the API key
  from the driver Secret (as the exporter does), GETs `system/info`; on a
  `TrueNAS-13` version it logs `core, nothing to do` and exits 0. On SCALE
  it GETs `iscsi/target` and PUTs `{"auth_networks": [...]}` on every
  target whose `auth_networks` differs from the expected list, one target
  per call, logging target name and old value as JSON at `info`. The list
  comes from env `ISCSI_AUTH_NETWORKS` (`192.168.1.247/32
  192.168.1.238/32 192.168.1.239/32 192.168.1.240/32`); a value that is not
  four `/32` addresses in `192.168.1.0/24` exits 1 before any call.
  An API error exits 1 (the Job fails, `KubeJobFailed` shows it); a 401 is
  logged as `api key rejected`.
- `truenas-exporter` adds `truenas_iscsi_targets_unrestricted`: targets
  not limited to exactly the expected list (CORE: through their initiator
  group's `auth_network`; SCALE: their own `auth_networks`).
- Alert `NASiSCSITargetOpen`: `truenas_iscsi_targets_unrestricted > 0` for
  1 h, `warning`, `action: human` (the guard failed for six runs), with its
  runbook and rule test.

The guard is merged before the window and does nothing on CORE. `down`
suspends it, so it writes nothing on 24.04 to 25.04, and `up` resumes it.
In the window, after U4 and before the canary, it runs once by hand
(`kubectl -n democratic-csi create job --from=cronjob/nas-iscsi-guard
nas-iscsi-guard-manual`), so the bulk update (up to 47 targets) happens
while no session is open.

### `truenas-exporter`

Before the window: `smart/test/results` becomes optional. Its failure is
logged once at `info` and does not set `truenas_up` to 0;
`truenas_disk_smart_*` is absent then. Every other endpoint stays
required, so `truenas_up` 1 after U4 proves them on 25.10.8. Disk labels
change from `ada*` to `sd*`; no rule depends on them.

After the window (task 8): the endpoint and the `truenas_disk_smart_*`
metrics go, and `NASSmartTestFailed` goes with its runbook, rule test and
the observability table row, since 25.10 no longer schedules self-tests.
SMART health stays visible through TrueNAS's own alerts
(`truenas_alerts`). Any endpoint that failed on 25.10.8 is fixed there
too. The daily "deprecated REST API" alert TrueNAS raises appears in
`truenas_alerts`; it is shown, not paged, and the REST exit is a
follow-up issue.

### API key and CA (#1371)

The key lives once, in the driver Secret, and serves democratic-csi, the
exporter, the guard and `nas-check.py`. 25.04 binds API keys to users.
The migrated key is expected to keep working; the checks are
`truenas_up` 1, the controller log without 401 and the canary. If the key
is rejected: create a key in the UI (Credentials > API Keys) for the user
the key belonged to (from the baseline's `user` record, the account
democratic-csi's SSH connection uses otherwise), put it into the Secret
with `task secrets:seal`, set the `api-token` date in
`ci/secret-rotation.tsv` in the same PR, and merge through
`scripts/pr-merge.sh`. Automated sync is off during the window, so the
merged Secret does not reach the cluster by itself: sync that one
Application by hand, then restart.

```sh
kubectl -n argo patch application secrets-infrastructure --type merge \
  -p '{"operation":{"initiatedBy":{"username":"nas-maintenance"},"sync":{"revision":"main"}}}'
# wait for status.operationState.phase == Succeeded
kubectl -n democratic-csi rollout restart deploy/iscsi-democratic-csi-controller \
  ds/iscsi-democratic-csi-node deploy/truenas-exporter
```

This fix has its own 45-minute budget (CI included) instead of the
30-minute stop rule.

The CA `homelab-nas-ca` and the `nas` certificate are in the configuration
database and migrate. TrueNAS replaces a certificate it finds malformed
with a self-signed one; then the fingerprint check fails and
democratic-csi stops with a TLS error. Fix: import the saved certificate
and key (System > Certificates > Import), select it as the UI certificate
(System > General), restart the UI, re-run `nas-check.py`.

### Shares

NFS (L1, #1303): the two exports keep paths, `hosts` (the four nodes) and
`maproot` (`nobody:nogroup` on `/mnt/homelab/k8s/nfs`, `root:wheel` on
`/mnt/homelab/k8s/backups`). Linux has no `alldirs`; subdirectories of an
exported dataset mount as before. Two fixes are decided in advance:

- `wheel` does not resolve on SCALE (the `nfs` check fails): set the
  backups export's `maproot_group` to `root`.
- A mounted path is its own child dataset and does not mount from the
  node, or shows empty through its parent: add an export for that
  dataset path with the same `hosts` and `maproot`. Task 1 records from
  `pool/dataset` whether any dataset sits under an exported path
  (`media`, `torrents` under `/mnt/homelab/k8s/nfs` in particular) and
  writes the decision (the extra exports, or none needed) into the
  runbook; the canary's non-empty checks catch what the record misses.

SMB (L3): share `bits_and_pieces` keeps `hostsallow` `192.168.1.0/24` and
guest access; 25.10 files it under the Legacy Share preset, which keeps
guest access. The two Windows machines and the Macs connect as guests by
address or name; nothing changes for them if the share opens after the
migration. Checks: `smbutil view -g //192.168.1.228` and a guest mount
with a write from the Mac; the operator opens the share on both Windows
machines. A Windows machine that refuses guest access after the
migration is a client setting ("insecure guest logons"); the share works
as before for the others, and the fix is a separate issue.

The web UI keeps `ui_httpsredirect` and HSTS (L4, #1306): the `ui` check
reads the setting, the redirect and the header.

### NAS-down alert (#1417)

`HomelabNASDown` runs in the `nas-watch` Prometheus, which has no NAS
volume, so it keeps evaluating through the window; the `cluster` silence
holds it. After `up`, its three probes must read 1 (acceptance criterion
3). The runbook keeps its fix steps; task 9 updates the UI paths and the
facts for SCALE.

The `cluster` silence keeps `Watchdog`, but `Watchdog` comes from the
main Prometheus, which `down` scales to 0. healthchecks.io then pages
"cluster dead" about 20 minutes in (5-minute period, 15-minute grace,
[observability.md](../../../docs/observability.md#heartbeat)). The freeze
pauses the healthchecks.io check (operator, its UI's Pause button) and the
unfreeze resumes it.

## Runbook

`docs/runbooks/nas-scale-migration.md` (task 6) is the copy-paste version,
following tech-docs: preconditions, numbered steps, the expected output
after each, what to do if it differs, the rollback. Steps marked
**operator** are physical or in the TrueNAS UI; the others are commands on
the Mac, run by the operator or by an agent whose brief allows live writes
for the window.

### The day before

1. Tasks 1 to 6 merged; the canary passed on CORE.
2. `scripts/nas-check.py --record ~/homelab-backups/nas/<yyyymmdd>-pre/`
   and `--expect core --baseline` the same directory: all PASS.
3. The four update files downloaded to `~/homelab-backups/nas/updates/`,
   each matching its SHA-256 from the runbook.
4. BMC: `shasum -a 256
   ~/homelab-backups/bmc-firmware/tp2-ota-v2.1.0.tpu` prints the recorded
   SHA-256; the v2.1 network test from the migration page, run in a BMC
   shell, prints `Not affected`; `tp2-firmware-sdcard-v2.1.0.img`
   downloaded next to the OTA file as the recovery image.
5. **Operator**: tells the household (from 09:00 to about 12:30, 14:00 at
   the latest, every app with storage or login unavailable, the SMB share
   too, and every app for about 30 minutes early in the window); has the
   USB-SATA adapter, a screwdriver and a microSD card at hand.

### The window (Monday to Friday, from 09:00 Zurich)

Every step's outcome (PASS lines, IDs, hashes) goes into the window log,
`~/homelab-backups/nas/<yyyymmdd>/window.log`; rollback step 0 reads it.

1. Preconditions: all nodes Ready, every Argo CD Application Synced and
   Healthy, no firing `critical`, `nas-maintenance.sh plan` exits 0 and
   shows every job of the daily backup set `today`.
2. Freeze: `gh workflow disable renovate-next.yaml` and `auto-rollback.yaml`;
   `scripts/maintenance-silence.sh cluster 6h "NAS CORE to SCALE, #1305"`
   (note the ID); **operator** pauses the healthchecks.io check. From here
   until task 10, no PR that adds a PVC merges.
3. Backups: `scripts/dump-databases.sh` (9 dumps); an on-demand CNPG
   `Backup` (method `plugin`, `barman-cloud.cloudnative-pg.io`) for each
   of the eight clusters, waiting for phase `completed`; `task
   talos:etcd-snapshot -- 192.168.1.239`.
4. `scripts/nas-maintenance.sh down` (keep the state file path).
   `scripts/nas-check.py --expect core --baseline <pre> --quiesced`: PASS.
5. BMC firmware ([BMC firmware in the same stop](#bmc-firmware-in-the-same-stop)).
   The BMC login comes from the operator's records through
   `TPI_USERNAME`/`TPI_PASSWORD`, never printed.
   1. `task talos:etcd-snapshot -- 192.168.1.239` (after `down`);
      `shasum -a 256` of the BMC image: the recorded value.
   2. `talosctl -n 192.168.1.240 shutdown`; wait until `.240` stops
      answering ping. Then
      `talosctl -n 192.168.1.247,192.168.1.238,192.168.1.239 shutdown`;
      wait until none of the three answers.
   3. `tpi firmware --file ~/homelab-backups/bmc-firmware/tp2-ota-v2.1.0.tpu
      --sha256 2c726062ba535c0a1d6b655bc1e668a712e0e8eb252474089c07ff2c5da1fe3e`:
      transfer and verification succeed.
   4. `tpi reboot`. Within 10 minutes `tpi info` answers with daemon
      2.1.0; record its address (`turingpi.local`, or the router's DHCP
      list) and MAC in the window log.
   5. `tpi power status`; `tpi power on -n 1`, `-n 2`, `-n 3`, then
      `-n 4` for the slots that are off.
   6. Checks: within 15 minutes four nodes Ready, `talosctl -n
      192.168.1.239 etcd status` three members and one leader, `talosctl
      -n 192.168.1.239 health` passes; `nas-check.py --expect core
      --baseline <pre> --quiesced`: PASS; `nmap -sV -p 22 <bmc>` OpenSSH
      9.8 or later; the step 2 silence still active (Alertmanager has no
      persistent storage: if the reboot dropped it, create it again and
      note the new ID).
   7. If the BMC address changed: a PR with the new address in
      `platform/blackbox-exporter/probes/lan.yaml` and
      `docs/networking.md`, `Closes #1307`, merged with
      `scripts/pr-merge.sh` before step 14. If it did not, #1307 is
      closed with the `tpi info` and `nmap` lines.
6. Snapshot, **operator**, CORE UI: Storage > Snapshots > Add, dataset
   `homelab`, name `pre-scale-<yyyymmdd>`, Recursive on. Check:
   `nas-check.py --expect core --baseline <pre> --snapshot
   pre-scale-<yyyymmdd> --only snapshot`: PASS.
7. Record again: `scripts/nas-check.py --record
   ~/homelab-backups/nas/<yyyymmdd>-quiesced/`.
8. **Operator**, CORE UI: System > General > Save Config with "Export
   Password Secret Seed"; System > Advanced > Save Debug; System >
   Certificates: download `homelab-nas-ca` and `nas` certificate and key.
   All into `~/homelab-backups/nas/<yyyymmdd>/`.
9. **Operator**: System > Shutdown. Takes the boot SSD out, connects it to
   the Mac with the adapter; macOS says the disk is not readable: click
   **Ignore**. `diskutil list` to find it (120 GB Kingston, external,
   never the Mac's own disk), then
   `sudo scripts/nas-boot-image.sh read disk<N> ~/homelab-backups/nas/<yyyymmdd>/`
   and `sudo scripts/nas-boot-image.sh verify disk<N> …`: same SHA-256.
   `diskutil eject`. SSD back in its port, NAS on.
10. CORE back: ping, ports 443/2049/3260, `nas-check.py --expect core`:
    PASS.
11. U1 to U4 as in [The update chain](#the-update-chain). After each,
    `nas-check.py --only version,pools,features` (and the whole
    `--expect scale` after U4).
12. Fixes, only those decided here:
    - guard run by hand (`kubectl -n democratic-csi create job
      --from=cronjob/nas-iscsi-guard nas-iscsi-guard-manual`);
    - NFS `maproot_group` `root`;
    - a child-dataset export;
    - certificate re-import;
    - SSH key login broken (`nas-check.py` exits 2 on SSH): Credentials >
      Users > the democratic-csi SSH user, paste the public key from the
      baseline's `user` record into its SSH public key field, save; check
      the SSH service still allows key login for that user. Until it
      works, the `features` check runs from the UI's System > Shell:
      `zpool get -H -o property,value all homelab | grep feature@`,
      pasted into a file read by `nas-check.py --features-file`;
    - API key replacement, with the manual sync of
      `secrets-infrastructure` ([API key and CA](#api-key-and-ca-1371)),
      on its own 45-minute budget.

    Then `nas-check.py --expect scale --baseline <quiesced>`: all PASS.
13. `scripts/nas-maintenance.sh canary --hold-guard`: PASS (the guard
    limited the canary's new target within 15 minutes).
14. `scripts/nas-maintenance.sh up <state-file>`; then the acceptance
    criteria 3 checks, `scripts/smoke.sh` and `probe_success{device="bmc"}`
    1.
15. SMB from the Mac; **operator** on both Windows machines.
16. Unfreeze: `maintenance-silence.sh --expire <id>`; **operator** resumes
    the healthchecks.io check; `gh workflow enable auto-rollback.yaml`
    and `gh workflow view auto-rollback.yaml` shows it active.
    `renovate-next.yaml` stays disabled until task 10 closes the rollback
    window.

### Stop rules

- BMC step: the BMC not answering 10 minutes after `tpi reboot`, or the
  nodes or etcd not healthy 30 minutes after power-on: stop the window
  before step 6, nothing on the NAS has changed. Recover with
  [A node won't come back](../../../docs/talos-cheatsheet.md#a-node-wont-come-back)
  (UART through `tpi uart`, slot power-cycle) or, if the BMC does not
  boot, the SD-card image (operator). Then `nas-maintenance.sh up` on
  CORE, the unfreeze, and the migration on another weekday.
- A check that fails and is not fixed by step 12's list within 30 minutes
  (45 for the API key replacement): rollback.
- At 14:00 Zurich, if step 14 has not started: rollback, so the household
  has its services in the evening.
- No ping on `.228` after U1's reboot: look at the router's DHCP list. A
  new lease whose MAC ends `B8:28` (or the onboard port's MAC): open
  `https://<lease-ip>`, Network > Interfaces, put `192.168.1.228/24`
  static on that interface with the recorded gateway and DNS, Test
  Changes, Save Changes, Persist, and continue with the U1 check. Nothing
  new on the router within 15 minutes, or the UI on the lease address
  unreachable: rollback. Without a console there is no other fix.
- A failure after U2, U3 or U4 that the previous Linux boot environment
  fixes: activate it, and stop the chain there only if the next attempt
  fails too; then rollback.

### The day after

- Every backup CronJob's night run succeeded, including
  `immich-library-backup-local` on the backups export, and
  `books-config-backup-calibre-web` at 05:20Z on the NFS export.
- `truenas_up` 1, no `NASExporterFailing`, `NASiSCSITargetOpen` silent.

## Rollback

Valid while `homelab`'s feature flags equal the baseline (step 0) and
until the rollback window closes 48 hours after the window. After it,
the rollback is no longer planned: PVCs may again be created, and their
targets would be missing on CORE.

0. Refusal check. `nas-check.py --expect scale --baseline <quiesced>
   --only features,iscsi` (with `--features-file` if SSH is broken).
   `features` must PASS, otherwise stop: CORE could not import the pool.
   If SCALE is unreachable, the operator confirms from the window log that
   every post-update `features` check passed; if one is missing, the
   rollback stops and an issue is opened. Every target the `iscsi` check
   lists as extra (a PVC created after the window) gets a one-off restic
   backup of its PVC now and is recreated on CORE after step 5.
1. If the apps run: `scripts/nas-maintenance.sh down`.
2. If the SCALE UI is reachable: Storage, pool `homelab`, Export/Disconnect
   with "Destroy data" off and "Delete saved configurations" off, so CORE
   imports it without a force flag.
3. **Operator**: shut the NAS down (UI, or the power button for 4 s), boot
   SSD to the Mac (**Ignore** on the "not readable" dialog), `sudo
   scripts/nas-boot-image.sh restore disk<N> ~/homelab-backups/nas/<yyyymmdd>/`:
   it refuses unless the disk matches `core-boot.device.plist`, unmounts
   it, writes and verifies the SHA-256. SSD back, NAS on.
4. `nas-check.py --expect core --baseline <quiesced>`. If pool `homelab` is
   not imported (it was not exported in step 2): CORE UI, Storage > Pools >
   Add > Import an existing pool; if CORE refuses a pool last used by
   another system, `sudo zpool import -f -R /mnt homelab` over SSH, then
   System > Reboot, and check again.
5. `scripts/nas-maintenance.sh canary`, then `up` (with the state file of
   the `down` that is still in effect).
6. democratic-csi needs nothing: its config works on both, the API key in
   the image is the CORE key, the guard does nothing on CORE.
7. Open an issue with what failed. The snapshot and the image stay.

Last resort, only with a console (graphics card in place of the network
card, onboard NIC has no CORE driver, so no network either): clean-install
CORE 13.0-U6.7 from ISO and upload the saved configuration.

## Error handling

| Operation | Failure | Recoverable | Result and logging |
| --- | --- | --- | --- |
| `nas-check.py` API call | timeout, connection refused, TLS error, 401, 5xx | yes, retry after the cause | exit 2, endpoint and status on stderr |
| `nas-check.py` check | a value differs | depends; the runbook names the fix | `FAIL <check>: <expected> != <found>`, exit 1 |
| `nas-maintenance.sh plan` | unknown owner, active NAS Job | yes, wait or handle by hand | exit 3 before any change |
| `nas-maintenance.sh down` | wait timeout | yes, inspect, re-run `status` | exit 1, leftovers listed; the state file is complete |
| `nas-maintenance.sh up` | workload not Ready in 20 min | yes | Argo CD restored anyway, exit 1, list |
| `canary` | any step | yes | objects deleted, exit 1, the step named |
| `canary --hold-guard` | target not limited in 15 min | yes, check the guard Job's log | objects deleted, exit 1 |
| `nas-boot-image.sh` | internal disk, wrong size, plist mismatch | yes, pick the right disk | exit 3 before any read or write |
| `nas-boot-image.sh verify` | hash mismatch | yes, read again | exit 1; the SSD does not go back until it matches |
| guard | bad `ISCSI_AUTH_NETWORKS` | no, config error | exit 1 before any call, `error` log |
| guard | API error or 401 | yes | exit 1, `error` log; `KubeJobFailed`, then `NASiSCSITargetOpen` after 1 h |
| exporter optional endpoint | any error | yes | `info` log once per state change, metric absent |
| Update file | SHA-256 mismatch | yes, download again | do not upload |
| Update | CORE refuses U1 for its version | yes | update CORE to 13.0-U6.8, retry |
| Update | no network after a reboot | rollback (U1) or previous boot environment (U2-U4) | stop rule |

## Invariants and who enforces them

- **No pool feature upgrade**: the runbook never runs one; `nas-check.py`'s
  `features` check after every update proves it; rollback step 0 refuses
  without it. The check is on the Mac because the NAS UI only offers the
  button, it does not prevent the click.
- **Immich data untouched**: `nas-maintenance.sh` only scales Immich's
  workloads and hibernates `immich-db`; no script or step names the
  `immich-data` PV or zvol; the snapshot is recursive on the pool.
- **iSCSI limited to the four nodes**: the guard (continuous), the
  exporter gauge and alert (detection), `nas-check.py` (the window).
- **No secret in output**: `nas-check.py` redacts before writing and never
  prints the key; the guard logs names and networks only; the
  configuration file, certificate keys and boot image stay in
  `~/homelab-backups/`.
- **Argo CD restored**: `up` restores the recorded sync policies even when
  a workload times out.

## Testability

- Unit (pytest): `nas-check.py` normalisation and every check against
  CORE- and SCALE-shaped fixtures (written by hand from the API reference
  and the 2026-11-16 records' shapes, no real values), including the
  feature comparison and the redaction; the guard's decision (which
  targets to PUT, the env validation, the CORE no-op) with a fake HTTP
  layer; the exporter's optional endpoint and the new gauge on both
  shapes (`tests/test_truenas_exporter.py`).
- Bash tests (`tests/bash/`): `nas-maintenance.sh plan`, `down` and `up`
  against a fake `kubectl` that serves recorded JSON, checking the actions,
  the state file, the order of the Argo CD changes (root, layers, leaves),
  the guard's suspension, a Succeeded backup pod ignored, and the exit
  codes; `nas-boot-image.sh` against fake `diskutil`, `dd` and `shasum`,
  checking each refusal.
- Rule test: `NASiSCSITargetOpen` in `tests/prometheus/nas_test.yaml`.
- CI: repo policy (`alert-tests`, `alert-runbooks`, CronJob lists),
  render, Kyverno, kubeconform.
- Live, on CORE before the window: `nas-check.py --expect core`, the
  canary, the guard's no-op log. On SCALE: the window's checks.
- Not testable before the window: the update chain itself and the
  rollback; the boot image is the safety for both. The BMC flash and the
  cold boot of all four nodes; the etcd snapshot and the SD-card image
  are their safety.

## Edge cases

- **A backup runs at 09:00**: `plan` exits 3; wait for it.
- **The guard races a new target's first login**: the login happens
  before or after the limit; both are from a node, both succeed.
- **The migrated configuration keeps group 1's networks on the targets**:
  the guard finds nothing to change.
- **TrueNAS raises its own alerts after U4** (pool upgrade available, REST
  deprecation, new SMB preset): shown in `truenas_alerts`, not paged;
  none is acted on in the window.
- **The onboard NIC gets a DHCP address**: SCALE does not configure
  interfaces absent from the migrated configuration; it stays down and
  unused.
- **NAS clock on US Pacific time**: unchanged; every time in the runbook is
  UTC or Zurich.
- **The Mac's disk space**: the boot image is 120 GB raw and a few GB
  compressed (the boot pool is mostly empty); `gzip -1` keeps it fast.
- **A household member uses SMB during the window**: the share is down
  with the rest; the household notice covers it.

## To settle at implementation

1. The download URL and SHA-256 of each update file (task 6), from the
   release pages linked in the Software Status page.
2. `sshConnection.username` and whether the config enables sudo (task 3),
   read from the decrypted Secret in memory.
3. The exact Deployment and CronJob list `plan` prints on the day; the
   design fixes the rules, not the list.
4. The network policy of `nas-iscsi-guard` (task 5): an egress rule to
   `192.168.1.228:443` like the exporter's, in the same file.

## Why it is like this

The UI update path is the only documented one that needs no console, and
this NAS has none. Its cost is four updates instead of one. The way back
is an image of the CORE boot SSD rather than a boot environment, because
TrueNAS documents the migration as one-way for boot environments; an image
restores CORE exactly and needs only a USB adapter. democratic-csi keeps
`freenas-iscsi` because every existing volume was created by it; the
API-only driver is experimental and would change the volume layer and the
storage platform in one window. The iSCSI limit moves into the cluster
because SCALE only knows it per target and democratic-csi does not set
it.
