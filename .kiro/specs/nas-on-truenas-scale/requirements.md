---
kind: change
status: active
created: 2026-11-16
issue: 1305
---
# Requirements: nas-on-truenas-scale

## Introduction

The NAS (`192.168.1.228`) runs TrueNAS CORE 13.0-U6.7. CORE is FreeBSD-based
and in sustaining engineering only: 13.0-U6.8 (2025-07-14) is its last
release, and new work happens on the Linux-based TrueNAS Community Edition,
formerly SCALE (pentest finding L3, #1305). Every PVC (iSCSI through
democratic-csi), the media library and the local photo-library backup (NFS)
and the household's file share (SMB) live on it.

This spec moves the NAS to TrueNAS Community Edition 25.10.8 (Goldeye), the
version TrueNAS recommends for general users on 2026-11-16, on the same
hardware and the same pool, with the cluster kept consistent and a tested way
back to CORE. The operator chose to migrate directly, without updating CORE
to 13.0-U6.8 first (2026-11-16).

Research, with sources, is in [design.md, Research](design.md#research).
The parts that drive the requirements:

- TrueNAS supports two paths from 13.0: a UI update to 24.04 (Dragonfish)
  followed by normal updates (24.10, 25.04, 25.10), or a clean ISO install
  of 25.10 followed by a configuration upload. The clean install needs a
  console. The NAS has none: the CPU has no integrated graphics, and the
  only PCIe slot holds the network card.
- The migration is one-way for the boot device: TrueNAS warns that
  activating a FreeBSD boot environment after it can break the system. A
  way back to CORE therefore needs a copy of the CORE boot device, not a
  boot environment. The pool stays readable by CORE only while no pool
  feature is enabled, so `zpool upgrade` (and the UI's "Upgrade Pool") is
  never run.
- Jails, plugins, tunables, ZFS boot environments, SMB auxiliary
  parameters, rsync tasks and some SSH connections do not migrate. Network
  interfaces are renamed (`igb0` becomes an `en*` name). iSCSI moves from
  `ctld` to SCST, and the per-initiator-group "authorized networks" that
  limit iSCSI to the four nodes today become a per-target setting.
- 25.10 removes the built-in SMART test scheduling and deprecates the REST
  API (removal planned for TrueNAS 27); democratic-csi v1.9.5, the version
  the cluster runs, supports 25.10.

## Glossary

- **NAS**: the TrueNAS host `192.168.1.228`, pool `homelab` (RAIDZ1, five
  Micron 5210 SSDs), boot device a Kingston A400 120 GB SATA SSD.
- **CORE**: TrueNAS CORE 13.0-U6.7, the current OS.
- **Target version**: TrueNAS Community Edition 25.10.8.
- **Window**: the one planned period on a weekday (Monday to Friday,
  daytime Zurich) during which the NAS is migrated, with the operator at
  home.
- **NAS volumes**: every iSCSI PVC (StorageClasses `iscsi`, `iscsi-retain`)
  and every NFS volume on `192.168.1.228`, as a PV or inline.
- **Stateful workloads**: the Deployments, StatefulSets, operator-managed
  sets, CNPG clusters and CronJobs whose pods mount a NAS volume.
- **Boot image**: a byte-for-byte image of the CORE boot SSD, taken during
  the window before the first update.
- **Baseline**: the read-only record of the NAS configuration taken with
  `scripts/nas-check.py --record` on CORE before the window and again after
  quiescing.
- **Four nodes**: `192.168.1.247`, `.238`, `.239`, `.240`.
- **Rollback window**: the 48 hours after the window during which a return
  to CORE stays planned.

## Requirement 1: Supported path to the target version

**User story:** As the operator, I want the NAS on a maintained TrueNAS
release by a path TrueNAS documents, so the pool and its data are safe.

1. THE migration SHALL follow the documented community path: a manual
   update file from CORE to 24.04.2.5, then manual updates to 24.10.2.4,
   25.04.2.6 and 25.10.8, each file checked against its published SHA-256
   before upload.
2. THE migration SHALL start from 13.0-U6.7 without a CORE update
   (operator). IF the CORE updater refuses the 24.04.2.5 file because of
   the CORE version, THEN CORE SHALL be updated to 13.0-U6.8 in the window
   and the migration continue.
3. THE NAS SHALL keep its hardware, its pool `homelab`, its address
   `192.168.1.228` on the Digitus card port (MAC ending `B8:28`), its
   hostname and its TLS certificate.
4. NOBODY SHALL run `zpool upgrade`, the UI's pool upgrade, or enable a
   pool feature during the migration or the rollback window. The enabled
   feature set of `homelab` after the migration SHALL equal the baseline.
5. THE hardware SHALL be checked against the target version before the
   window: CPU, memory, boot device, and a Linux driver for every PCI
   device in the CORE debug file.

## Requirement 2: Nothing is lost

**User story:** As the operator, I want fresh, verified backups and a
pool snapshot before the NAS changes, so any failure is recoverable.

1. BEFORE the first update, every daily backup CronJob (the names in
   `ci/active-cronjobs.txt` containing `-backup`, minus `backup-verify-*`)
   SHALL have a successful run that finished on the window day after
   00:00Z, every CNPG cluster SHALL have an
   on-demand base backup completed in the window, the local database dumps
   (`scripts/dump-databases.sh`) and a Talos etcd snapshot SHALL be taken.
2. AFTER the stateful workloads are stopped and before the first update,
   a recursive ZFS snapshot `homelab@pre-scale-<yyyymmdd>` SHALL exist for
   every dataset and zvol of `homelab`.
3. THE CORE configuration SHALL be saved with its secret seed, together
   with a debug file and the NAS CA and `nas` certificate with their keys,
   to `~/homelab-backups/nas/<yyyymmdd>/` on the Mac, never to git.
4. THE boot image SHALL be taken with the NAS powered off and stored with
   its SHA-256 next to the configuration.
5. THE Immich library (PVC `immich-data`, its zvol) SHALL NOT be read,
   written, moved, re-bound or resized by any step; the recursive snapshot
   is the only operation that includes it.

## Requirement 3: The cluster stays consistent

**User story:** As the operator, I want the apps stopped cleanly while the
NAS reboots and back as before afterwards, so no volume is cut mid-write.

1. BEFORE the NAS is shut down, the stateful workloads SHALL be stopped by
   `scripts/nas-maintenance.sh down`, and no pod SHALL mount a NAS volume,
   no democratic-csi VolumeAttachment SHALL exist and the NAS SHALL report
   no iSCSI session.
2. `scripts/nas-maintenance.sh up` SHALL restore every object it changed
   to its recorded state, including Argo CD automated sync.
3. DURING the window the auto-rollback workflow SHALL be disabled, a
   `cluster` maintenance silence SHALL be active and the healthchecks.io
   heartbeat check SHALL be paused; all three SHALL be restored at the end
   of the window. THE Renovate train SHALL be disabled from the start of
   the window until the rollback window closes (task 10).
4. NO new PVC SHALL be created between the start of the window and the end
   of the rollback window: no PR that adds a PVC merges in that time. IF
   the rollback runs and SCALE has iSCSI targets the quiesced baseline
   does not, THEN each one's PVC SHALL be backed up before the rollback
   and recreated on CORE after it.

## Requirement 4: Storage and shares work as today

**User story:** As the household and the cluster, we want the same shares,
with the same limits, after the migration.

1. democratic-csi SHALL provision, attach, mount, expand and delete iSCSI
   volumes on the target version with driver `freenas-iscsi`, the same
   CSI driver name, release name and StorageClasses, and TLS verified
   against the NAS CA (#1371).
2. Every iSCSI target SHALL accept only the four nodes, including targets
   democratic-csi creates after the migration.
3. Both NFS exports SHALL keep their paths, `hosts` limited to the four
   nodes, empty `networks`, and their `maproot` mapping, and every path
   the cluster mounts SHALL mount from a node.
4. THE SMB share `bits_and_pieces` SHALL keep `hostsallow`
   `192.168.1.0/24` and guest access, and SHALL open from the operator's
   Mac and from the household's two Windows machines.
5. THE web UI SHALL keep the HTTP-to-HTTPS redirect and HSTS (#1306).
6. THE API key democratic-csi and `truenas-exporter` use SHALL work on the
   target version; IF it does not, THEN a new key SHALL replace it through
   SOPS and `ci/secret-rotation.tsv` SHALL record the date.

## Requirement 5: Monitoring knows the new NAS

**User story:** As the operator, I want the NAS alerts to keep working on
the target version, so a NAS problem still pages.

1. `HomelabNASDown` (#1417) SHALL see ports 443, 2049 and 3260 up after
   the window.
2. `truenas-exporter` SHALL report `truenas_up` 1 on CORE and on the
   target version.
3. AN alert SHALL page when an iSCSI target stays open to more than the
   four nodes for an hour.
4. `NASSmartTestFailed` SHALL be removed with its runbook and test once
   the exporter no longer reads SMART self-test results.

## Requirement 6: A way back

**User story:** As the operator, I want a return to CORE that works
without a console, so a failed migration costs hours, not data.

1. UNTIL the end of the rollback window, restoring the boot image onto the
   boot SSD SHALL bring CORE back with pool `homelab` imported, the cluster
   working, and no other change.
2. THE rollback SHALL be refused if the enabled feature set of `homelab`
   differs from the baseline, or, with SCALE unreachable, if the window
   log lacks a passing `features` check after any update.
3. BETWEEN target-version steps, a failed update SHALL be undone by
   activating the previous Linux boot environment.
4. THE boot image SHALL only be written to a disk that matches the
   recorded boot device (size, media name, external).

## Requirement 7: Run with the operator present

**User story:** As the operator, I want one planned window with clear
checks and stop rules, so I know when to continue and when to roll back.

1. THE window SHALL be on a weekday, start at 09:00 Zurich, and follow
   `docs/runbooks/nas-scale-migration.md` step by step.
2. EVERY step SHALL state its check; a failed check that the runbook does
   not fix within 30 minutes SHALL lead to the rollback.
3. IF the runbook's scale-up step (`nas-maintenance.sh up`) has not
   started by 14:00 Zurich, THEN the rollback SHALL start.
4. THE household SHALL be told the day before.

## Non-functional requirements

- No secret in git, in a log or in command output: the API key, the SSH
  key, the configuration file and the certificate keys stay in SOPS or in
  `~/homelab-backups/` (#1371 rules).
- The new scripts are deterministic, read-only by default where possible,
  and unit tested; `nas-maintenance.sh` acts only after printing its whole
  plan.
- Household downtime: one window of about three hours, with every app
  that has a NAS volume or needs Keycloak unavailable.

## Acceptance criteria

1. `scripts/nas-check.py --expect scale --baseline <dir>` exits 0 after the
   window: version 25.10.8, pool `homelab` and the boot pool ONLINE,
   feature set equal to the baseline, services `cifs`, `nfs`,
   `iscsitarget`, `ssh` running and enabled, NFS and SMB limits as in
   requirement 4, the iSCSI target names equal to the baseline and each
   limited to the four nodes, the TLS certificate fingerprint equal to the
   baseline and verified by the CA in `values-iscsi.yaml` with the IP SAN,
   NFSv4 on, HTTPS redirect on and the HSTS header present.
2. The canary (`scripts/nas-maintenance.sh canary`) passes on CORE before
   the window and on the target version before `up`: a 1 GiB `iscsi` PVC is
   bound, mounted, written, read back, expanded to 2 GiB and deleted, and
   its zvol is gone; the four NFS paths mount read-only from a node and
   are non-empty, and `media/` and `torrents/` are non-empty through the
   parent mount.
3. After `up`: every Argo CD Application Synced and Healthy, the eight CNPG
   clusters healthy, `scripts/smoke.sh` green, `probe_success` 1 for
   `192.168.1.228:443`, `:2049` and `:3260` in the `nas-watch` Prometheus,
   `truenas_up` 1.
4. The next nightly run of every backup CronJob, including
   `immich-library-backup-local`, succeeds.
5. `smbutil view -g //192.168.1.228` from the Mac lists `bits_and_pieces`;
   a guest mount writes and deletes a test file; the operator confirms the
   share opens on both Windows machines.
6. `scripts/nas-maintenance.sh canary --hold-guard` exits 0 on the target
   version: the canary's new target is limited to the four nodes by
   `nas-iscsi-guard` within 15 minutes. `NASiSCSITargetOpen` fires in the
   rule test after 1 h.
7. `nas-check.py --expect core --baseline <pre> --snapshot
   pre-scale-<yyyymmdd> --only snapshot` exits 0 before the first update.
8. Before the SSD goes back into the NAS, `nas-boot-image.sh verify`
   exits 0 (a second read has the same SHA-256 as the boot image). The
   full rollback runs only if it is needed.
9. At the end of the window `gh workflow view auto-rollback.yaml` shows
   it enabled, no maintenance silence is active and the healthchecks.io
   check is running again; `renovate-next.yaml` is enabled again in
   task 10.
10. No file in git or in CI logs contains the API key, the SSH key or a
    certificate key (`scripts/leak-check.sh`, gitleaks).

## Out of scope

Each becomes its own issue when it is picked up:

- Moving off the REST API before TrueNAS 27 removes it (exporter, guard,
  democratic-csi).
- democratic-csi's API-only `freenas-api-iscsi` driver (no SSH), which is
  experimental upstream.
- TLS verification in `truenas-exporter` (it skips it today).
- A non-root administrator on the NAS and disabling root password login.
- Removing the failing L2ARC device `nvd0`.
- The NAS time zone (America/Los_Angeles).
- Turning off SMB guest access (the operator's call).
- The BIOS "Restore on AC Power Loss" setting, which still needs a
  console.
- Updating beyond 25.10 (TrueNAS 27 is a release candidate today).

## Decided defaults

Each default holds until the operator says otherwise. Rows marked
"operator" are his answers of 2026-11-16.

| Topic | Default | Reason |
| --- | --- | --- |
| Target | TrueNAS Community Edition 25.10.8 | TrueNAS's "General" recommendation on 2026-11-16; 27 is a release candidate |
| Start version | 13.0-U6.7, no CORE update first (operator) | Deal with the main risk directly; U6.8 only if the updater refuses |
| Path | UI manual updates 24.04.2.5, 24.10.2.4, 25.04.2.6, 25.10.8 | The only documented path without a console |
| Way back | Boot image of the CORE SSD on the Mac, restored with `dd` | Works without a console; a CORE boot environment is not a valid rollback after the migration |
| Rollback window | 48 hours | Two nightly backup cycles; keeps the freeze on new PVCs short |
| Cluster during the window | Stateful workloads stopped by `nas-maintenance.sh` | Five NAS reboots; clean unmounts beat waiting on hard NFS mounts and iSCSI timeouts |
| democratic-csi | Driver `freenas-iscsi`, `zfs.cli.paths` removed (auto-detection) | Same driver as the existing volumes; one config for CORE and SCALE |
| iSCSI limit | Per-target `auth_networks` = the four nodes, kept by CronJob `nas-iscsi-guard` | SCALE has no per-group network limit; democratic-csi does not set it |
| Window | A weekday, 09:00-14:00 Zurich | Operator present; evening service guaranteed by the 14:00 stop rule |
| Window date | The first weekday after tasks 1 to 6 merge (operator to confirm) | Nothing else waits on it |
| Household notice | The operator tells the household the day before: about 3 h without any app that uses storage or login, the SMB share included (operator) | Req 7.4 |
| Boot-image adapter | The operator has or buys a USB-SATA adapter, about CHF 10 (operator to confirm) | The only console-free way back to CORE; without it, the rollback needs a graphics card in place of the network card |
| Heartbeat | healthchecks.io check paused for the window | The main Prometheus, source of `Watchdog`, is scaled to 0 |
| Renovate | `renovate-next` disabled from the window until task 10 | No new PVC in the rollback window |
| Snapshot retention | `homelab@pre-scale-<yyyymmdd>` deleted when the rollback window closes | Space; the backups remain |
