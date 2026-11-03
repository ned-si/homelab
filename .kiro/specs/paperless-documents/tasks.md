# Tasks: paperless-documents

One PR per task, in order unless a task says otherwise; each is safe on its
own. Tasks that restart Paperless or write to the cluster or the NAS run on
a weekday, during the day (Zurich). Open questions are in
[requirements.md](requirements.md#open-questions); a task that depends on
one waits for its answer.

## Open

- [ ] 1. **Seafile archive, before 2026-11-16 (last weekday: Friday
      2026-11-13).** Restore restic snapshots `34f34ea0` and `8838dac0` into
      a scratch namespace and volume, export the libraries to plain files
      with `seaf-fsck.sh --export`, record file count, total size and count
      per extension in the PR, copy the export to `~/homelab-backups/` on
      the operator's Mac, delete the scratch objects. Update "Seafile
      removed" in `docs/decisions.md` with the outcome. If it cannot run in
      time, the PR extends the zvol retention date instead (open question
      11). Independent of the other tasks. [6.1, 6.4]
- [ ] 2. Settings: `PAPERLESS_OCR_LANGUAGE` (open question 2),
      `PAPERLESS_TIME_ZONE=Europe/Zurich`, `PAPERLESS_DATE_ORDER=DMY`,
      `PAPERLESS_FILENAME_FORMAT`, `PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS=household`.
      Check: a French, a German and an English test page are OCRed and
      findable; the one existing document is renamed on disk. [5.1, 5.6, 9.2]
- [ ] 3. Configuration as code: `apps/paperless/config/paperless.json`
      (document types, tags, custom fields, saved views, the workflows
      without personal data, from the taxonomy answer to open question 1),
      `apply.py` with pytest against a fake API, the user `automation` and
      its token in SOPS `paperless-automation` (`docs/secrets.md`,
      `ci/secret-rotation.tsv`), the PostSync Job and the nightly
      `--retention` CronJob (`ci/active-cronjobs.txt`). Check: a second run
      reports 0 changes. [5.2, 5.3, 5.4, 5.5]
- [ ] 4. Access: the group `household` and its permissions, the
      per-member part in SOPS `paperless-config`, the `share-household` and
      `private-types` workflows (open question 7). Check: a matrix with
      throwaway users (member A, member B, an admin) over a shared and a
      private document, users deleted afterwards. `docs/paperless.md`
      "Access". [9.1, 9.2, 9.3, 9.4]
- [ ] 5. Consistent backup and export, after #953 merges: the SQLite copy
      through the backup API (journal mode checked first), the
      `paperless-export` CronJob and PVC, `/export` in the restic backup,
      `restic-targets.txt` (`paperless-data` required file,
      `paperless-export`), `docs/backups.md` rows. Takes the Paperless part
      of #746; the issue keeps Jellyfin and Grafana. [7.1, 7.2, 7.5, 8.1, 8.3]
- [ ] 6. Restore test: `restore-paperless` in `backup-verify` (import into a
      throwaway Paperless, counts equal, one PDF opens), its alert, promtool
      test and runbook. Check: one manual run passes, one with a corrupted
      manifest fails and the alert test fires. [7.3, 7.4, 8.2]
- [ ] 7. Inbox folder: the TrueNAS dataset `homelab/k8s/nfs/paperless-inbox`
      and its NFS export to the four nodes (operator, or an agent given the
      TrueNAS API key), the static PVs and PVCs in `paperless` and
      `syncthing`, the mounts, `PAPERLESS_CONSUMER_POLLING=30`,
      `PAPERLESS_CONSUMER_RECURSIVE=true`, the `owner-folder-<member>`
      workflows, the Syncthing folder with 30-day trash can versioning on
      the devices (open question 9). Check: a file dropped on the Mac is
      findable within 5 minutes and owned by its member; an NFS mount from
      the Mac is refused. [2.1, 2.2, 2.3, 2.4, 10.1]
- [ ] 8. Phone: the client app (open question 5), per-member API tokens,
      the `source-phone` workflow, the setup in `docs/paperless.md`. Check:
      one camera scan and one share-sheet upload per platform in use,
      findable within 5 minutes; a revoked token gets `401`. [1.1, 1.2, 1.3, 10.1]
- [ ] 9. Mail: the mailbox (open question 3), SOPS `paperless-mail`, the
      mail account and per-member rules through `apply.py`, egress TCP 993
      in the CiliumNetworkPolicy `paperless`. Check: a forwarded attachment
      from a household address is findable within 15 minutes and the mail
      is in `Processed`; a mail from another address is left unread. Also
      check whether `/api/` accepts the local admin password from the
      internet; if it does, open a security issue. [3.1, 3.2, 3.3, 3.4, 3.5, 10.2]
- [ ] 10. Scanner (open question 4): scan to mail through task 9's mailbox,
      or an SMB share of the inbox dataset limited to the scanner. Check: a
      10-page scan is findable within 5 minutes (15 by mail), tagged
      `source:scan`. With no scanner, this task becomes a `deferred` issue.
      [4.1, 4.2, 10.1]
- [ ] 11. Ingest canary: `paperless-canary`, the user `canary` and its
      token in SOPS, the network policy to the Pushgateway,
      `PaperlessIngestFailing` and `PaperlessIngestSlow` with promtool
      tests and runbooks. Check: a week of canary results on the Data
      protection dashboard. [10.3, 10.4]
- [ ] 12. Import: `scripts/paperless-import.py` with pytest, then the
      batches the operator selects (the Seafile export of task 1 and the
      sources of open question 6), each with its counts (in = created +
      duplicates + failed) in the PR and the file-level report kept local.
      [6.2, 6.3, 6.4]
- [ ] 13. Close: `docs/paperless.md` complete (ways in, taxonomy, access,
      export, restore), the README Services row, `docs/threat-model.md`
      documents row, the media-home area spec updated with how Paperless
      works now; then header `status: done`, `closed:`, issue #732 closed.
