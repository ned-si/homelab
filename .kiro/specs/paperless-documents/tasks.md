# Tasks: paperless-documents

One PR per task, in order unless a task says otherwise; each is safe on its
own. Tasks that restart Paperless or write to the cluster or the NAS run on
a weekday, during the day (Zurich). Open questions are in
[requirements.md](requirements.md#open-questions); a task that depends on
one waits for its answer.

## Open

- [ ] 1. **Seafile archive, before the zvols may go on 2026-11-17 (target
      Friday 2026-11-13, buffer Monday 2026-11-16).** In a scratch
      namespace and volume: `restic ls -l 8838dac0` and the `RepoFileCount`
      and `RepoSize` rows of the MariaDB dump in `34f34ea0`; if libraries
      hold files, restore `8838dac0` and export them with `seaf-fsck.sh
      --export`. Record file count, total size and count per extension in
      the PR, copy any export to `~/homelab-backups/` on the operator's Mac,
      delete the scratch objects. Update "Seafile removed" in
      `docs/decisions.md` with the outcome. If it cannot run in time, the PR
      extends the zvol retention date instead (open question 13).
      Independent of the other tasks. [6.1, 6.4]
- [ ] 2. Settings: `PAPERLESS_OCR_LANGUAGE` (open question 3),
      `PAPERLESS_TIME_ZONE=Europe/Zurich`, `PAPERLESS_DATE_ORDER=DMY`,
      `PAPERLESS_FILENAME_FORMAT`. Check: a French, a German and an English
      test page are OCRed and findable; the one existing document is renamed
      on disk. [5.1, 5.6]
- [ ] 3. Configuration as code: `apps/paperless/config/paperless.json`
      (document types, tags, custom fields, saved views, the workflows
      without personal data, from the answers to open questions 1 and 2),
      `apply.py` with pytest against a fake API (including the unquoted
      phrase and keyword overlap checks, the wait for `/api/` and the retry
      on `5xx`), the user `automation` and its token in SOPS
      `paperless-automation` (`docs/secrets.md` with the token's reach,
      `ci/secret-rotation.tsv`), the PostSync Job and the nightly
      `--retention` CronJob (`ci/active-cronjobs.txt`). Check: a second run
      reports 0 changes. [5.2, 5.3, 5.4, 5.5]
- [ ] 4. Access: the group `household` and its permissions (no change
      rights on types, tags, custom fields, workflows), the member list in
      SOPS `paperless-config` (one encrypted `config.json` value), the
      existing member accounts added to `household`, then
      `PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS=household`, the
      `share-household` and `private-types` workflows (open question 8).
      Check: a matrix with throwaway users (member A, member B, a Keycloak
      `admins` member without the superuser flag) over a shared and a
      private document, users deleted afterwards. `docs/paperless.md`
      "Access". [9.1, 9.2, 9.3, 9.4]
- [ ] 5. Consistent backup and export, after #953 merges: the init
      container with `paperless-data` read-write and the SQLite backup API
      (tag `paperless-db`, `db.sqlite3*` excluded from `paperless-data`),
      the `paperless-export` CronJob and PVC with `--passphrase` from SOPS
      `paperless-export`, `/export` in the restic backup,
      `restic-targets.txt` (`paperless-data` required file
      `celerybeat-schedule.db`, new `paperless-db` and `paperless-export`
      lines), `docs/backups.md` rows. Takes the Paperless part of #746; the
      issue keeps Jellyfin and Grafana. [7.1, 7.2, 7.5, 8.1, 8.3]
- [ ] 6. Restore test: `restore-paperless` in `backup-verify` (`migrate`,
      `document_importer --passphrase` and a count in one pod with no web
      server, worker or beat; no TCP 993 egress; counts equal, one PDF
      opens), the passphrase copy in `backup-verify`, its alert, promtool
      test and runbook. Check: one manual run passes, one with a corrupted
      manifest fails and the alert test fires. [7.3, 7.4, 8.2]
- [ ] 7. Inbox folders: the TrueNAS dataset
      `homelab/k8s/nfs/paperless-inbox` and its NFS export to the four nodes
      (operator, or an agent given the TrueNAS API key), the static PVs and
      PVCs in `paperless` and `syncthing`, the mounts,
      `PAPERLESS_CONSUMER_POLLING=30`, `PAPERLESS_CONSUMER_RECURSIVE=true`,
      the `owner-folder-<member>` workflows, one Syncthing folder per member
      subdirectory shared only with that member's devices, with 30-day trash
      can versioning on those devices (open question 10). Check: a file
      dropped on member A's Mac is findable within 5 minutes, owned by A,
      and never appears on member B's devices; an NFS mount from the Mac is
      refused. [2.1, 2.2, 2.3, 2.4, 10.1]
- [ ] 8. Phone and API: the client app (open question 6), per-member API
      tokens, the `source-phone` workflow, the setup in `docs/paperless.md`.
      Check: one camera scan and one share-sheet upload per platform in use,
      findable within 5 minutes; a revoked token gets `401`. Also check
      whether `/api/` accepts the local admin password over basic auth from
      the internet; if it does, open a security issue. [1.1, 1.2, 1.3, 10.1]
- [ ] 9. Mail: the mailbox (open question 4, a provider that enforces DMARC
      on inbound mail), SOPS `paperless-mail`, the mail account and
      per-member rules through `apply.py`, egress TCP 993 in the
      CiliumNetworkPolicy `paperless`. Check: a forwarded attachment from a
      household address is findable within 15 minutes, tagged `inbox`, and
      the mail is in `Processed`; a mail from another address is left
      unread. [3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 10.2]
- [ ] 10. Scanner (open question 5): scan to mail through task 9's mailbox,
      or an SMB share of the inbox dataset limited to the scanner. Check: a
      10-page scan is findable within 5 minutes (15 by mail), tagged
      `source:scan`. With no scanner, this task becomes a `deferred` issue.
      [4.1, 4.2, 10.1]
- [ ] 11. Ingest canary: `paperless-canary`, the user `canary` and its
      token in SOPS, the network policy to the Pushgateway,
      `PaperlessIngestFailing` and `PaperlessIngestSlow` with promtool
      tests and runbooks. Check: a week of canary results on the Data
      protection dashboard. [10.3, 10.4]
- [ ] 12. Import script: `scripts/paperless-import.py` with pytest (upload,
      tags, task follow-up, the local report, counts only on stdout).
      [6.2, 6.4]
- [ ] 13. Import batches: the batches the operator selects (the Seafile
      export of task 1 and the sources of open question 7), run during the
      day; one PR records the counts of every batch (in = created +
      duplicates + failed) and the failure reasons in `docs/paperless.md`,
      opened when the selection is imported; the file-level reports stay
      local. [6.2, 6.3, 6.4]
- [ ] 14. Close: `docs/paperless.md` complete (ways in, taxonomy, access,
      export, restore), the README Services row, the `docs/threat-model.md`
      documents row (forged mail sender, the `automation` token's reach),
      the media-home area spec updated with how Paperless works now; then
      header `status: done`, `closed:`, issue #732 closed.
