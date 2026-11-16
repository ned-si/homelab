# Tasks: nas-on-truenas-scale

One PR per task, in order, each carrying `Spec: nas-on-truenas-scale#<task>`;
tasks 7 and 10 are live work, ticked with their date in the next PR.
Requirement numbers in brackets. Tasks 1 to 6 change nothing the NAS or
the cluster can notice on CORE beyond their own checks; task 7 is the
window, on a weekday with the operator at home. The defaults are in
[requirements.md](requirements.md#decided-defaults). The PR or tick of
task 10 sets the spec `done` and closes #1305.

- [ ] 1. `scripts/nas-check.py` with `--record`, `--expect core|scale`,
      `--baseline`, `--quiesced`, `--snapshot`, `--features-file`,
      `--only`, the redaction, the SMB and NFS-service normalisation, and
      pytest tests on CORE-, 24.04- and 25.10-shaped fixtures;
      `scripts/nas-boot-image.sh` (`read`, `verify`, `restore`) with bash
      tests against fake `diskutil`, `dd` and `shasum`. Run on CORE:
      record the baseline under `~/homelab-backups/nas/`, `--expect core`
      all PASS. Record from `pool/dataset` which datasets sit under an
      exported path and decide the extra exports (or none). Re-read each
      source in design.md's Research table and record the date. From the
      record and a debug file (operator, CORE UI): confirm the hardware
      table (every PCI device has a Linux driver), no jails or plugins,
      the tunables, init/shutdown scripts, cron jobs and users (no name
      starting with a digit, no user account below UID 1000, root not
      locked), deprecated services stopped. A blocker found here stops
      the spec until it is resolved. [1.3, 1.4, 1.5, 4.2-4.5]
- [ ] 2. `scripts/nas-maintenance.sh` (`plan` with the daily backup set,
      `down` in the root, layers, leaves order with the guard suspended,
      `up` with the restart of non-Ready workloads, `canary
      [--hold-guard]` with the non-empty NFS checks, `status`) with the
      bash tests against a fake `kubectl`, including a Succeeded backup
      pod; the canary objects' labels and the `backup-verify` namespace's
      policies allow them (Kyverno and network policy checked in CI). Run
      `plan` and `canary` live on CORE: both exit 0. Check once live, on
      CORE, that `spec.replicas: 0` on the `Prometheus` CR scales its
      StatefulSet to 0 (else the `spec.paused` fallback). [3.1, 3.2, 4.1,
      4.3]
- [ ] 3. democratic-csi config: `zfs.cli.paths` removed from
      `infrastructure/secrets/democratic-csi-iscsi.sops.yaml` (re-sealed),
      the `.example` template updated (paths, `allowInsecure` comment);
      if the SSH user uses sudo, the Linux paths added to its allowed sudo
      commands on CORE. After the merge: controller and node restarted,
      `canary` passes on CORE. [4.1]
- [ ] 4. `truenas-exporter`: `smart/test/results` optional, its test
      cases, the observability table updated. Check: `truenas_up` 1 on
      CORE. [5.2]
- [ ] 5. iSCSI limit on SCALE: CronJob `nas-iscsi-guard`
      (`platform/truenas-exporter/iscsi_guard.py`, env
      `ISCSI_AUTH_NETWORKS`, network policy), the gauge
      `truenas_iscsi_targets_unrestricted`, alert `NASiSCSITargetOpen`
      with its runbook, rule test and alerts README entry, the CronJob in
      `ci/active-cronjobs.txt` and `ci/non-backup-cronjobs.txt`, pytest
      tests. Check: on CORE the guard logs `core, nothing to do` and the
      gauge reads 0. [4.2, 5.3]
- [ ] 6. `docs/runbooks/nas-scale-migration.md` from
      [design.md, Runbook](design.md#runbook) and
      [Rollback](design.md#rollback), with each update file's URL and
      SHA-256, linked from `docs/runbooks/README.md`. [1.1, 1.2, 2.1-2.5,
      3.3, 6.1-6.3, 7.1-7.4]
- [ ] 7. The window (no PR; operator present, weekday from 09:00 Zurich,
      date chosen by the operator): the runbook from "The day before" to
      "Unfreeze". Check: acceptance criteria 1-3 and 5-9 (Renovate
      excepted until task 10); the next morning, criterion 4. The run's report lists every fix applied
      from the runbook's list. [1-7]
- [ ] 8. After the window: `truenas-exporter` drops `smart/test/results`
      and `truenas_disk_smart_*`; `NASSmartTestFailed` removed with its
      runbook, rule test and table rows; any endpoint that failed on
      25.10.8 fixed; on the NAS, the CORE paths removed from the SSH
      user's sudo commands (if task 3 added the Linux ones), then the
      canary again. [5.2, 5.4]
- [ ] 9. Docs for the new state: `README.md`, `docs/architecture.md`,
      `docs/runbooks/cold-start.md` (NAS facts: version, interface name,
      onboard NIC), `docs/runbooks/alerts/HomelabNASDown.md` (SCALE UI
      paths), `docs/runbooks/nfs-hardening.md`, `docs/observability.md`
      (API keys bound to users, REST deprecation), `docs/threat-model.md`
      and `docs/decisions.md` where they name CORE, `.kiro/steering/tech.md`.
      The local `homelab-context` skill is updated outside git. [1.3]
- [ ] 10. Close the rollback window, 48 h after task 7: destroy
      `homelab@pre-scale-<yyyymmdd>` recursively (operator confirms),
      delete the boot image, keep the configuration file and the baseline
      records, lift the freeze on new PVCs, `gh workflow enable
      renovate-next.yaml` (AC 9). A docs PR ticks it and sets the
      spec `done` with its `closed` date; #1305 closes. [6.1]
