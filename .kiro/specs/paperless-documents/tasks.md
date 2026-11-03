# Tasks: paperless-documents

One PR per task, in order unless a task says otherwise; each is safe on its
own. Tasks that restart Paperless or write to the cluster or the NAS run on
a weekday, during the day (Zurich). Open questions and decided defaults are
in [requirements.md](requirements.md#open-questions); task 3 waits for the
taxonomy answer and task 9 for the mailbox answer. Tasks 2 and 4 ship the
proposed answers to the languages and sharing questions when none comes.

## Open

- [ ] 1. **Seafile archive, before the zvols may go on 2026-11-17 (target
      Friday 2026-11-13, buffer Monday 2026-11-16).** In a scratch
      namespace and volume: `restic ls -l 8838dac0` and the `RepoFileCount`
      and `RepoSize` rows of the MariaDB dump in `34f34ea0`; if libraries
      hold files, restore `8838dac0` and export them with `seaf-fsck.sh
      --export`. Record file count, total size and count per extension in
      the PR, copy any export to
      `~/homelab-backups/paperless-import/seafile/` on the operator's Mac,
      delete the scratch objects. Update "Seafile removed" in
      `docs/decisions.md` with the outcome. If it cannot finish by Monday
      2026-11-16, the PR extends the zvol retention date instead.
      Independent of the other tasks. [6.1, 6.4]
- [ ] 2. Settings: `PAPERLESS_OCR_LANGUAGE=fra+deu+eng` (open question 3),
      `PAPERLESS_TIME_ZONE=Europe/Zurich`, `PAPERLESS_DATE_ORDER=DMY`,
      `PAPERLESS_FILENAME_FORMAT`. Check: a French, a German and an English
      test page are OCRed and findable; the one existing document is renamed
      on disk. [5.1, 5.6]
- [ ] 3. Configuration as code: `apps/paperless/config/paperless.json`
      (document types, tags, custom fields, saved views, the workflows
      without personal data, from the answer to open question 1),
      `apply.py` with pytest against a fake API: the unquoted phrase and
      shared keyword checks, the synthetic FR/DE/EN corpus in
      `tests/paperless/corpus/` (each text matches exactly its expected
      type, a QR-bill per language none; texts with `’`), the
      `owner: null` and `set_permissions` fields of every request, the
      correspondent and document permission passes, the wait for `/api/`
      and the retry on `5xx`. The user `automation` and its token in SOPS
      `paperless-automation` (`docs/secrets.md` with the token's reach,
      `ci/secret-rotation.tsv`), the PostSync Job and the nightly
      `--nightly` CronJob (`ci/active-cronjobs.txt`). Check: a second run
      reports 0 changes; a saved view with `owner: null` is listed and can
      go on the dashboard for both groups on 3.4.1, or `apply.py` creates
      one copy per listed account. [5.2, 5.3, 5.4, 5.5, 9.5]
- [ ] 4. Access: the groups `editors` and `readers` and their permissions,
      the member list in SOPS `paperless-config` (one encrypted
      `config.json` value), the editor's and the reader's accounts put into
      their groups by `apply.py`, the superuser flag removed from the
      editor's account once `nedsi-admin` is proven to reach the admin with
      `PAPERLESS_REDIRECT_LOGIN_TO_SSO` set (else the `manage.py shell`
      recovery is recorded in `docs/paperless.md`), the `owner`, `share-api` and `private` workflows
      (`private` last). Check: a matrix with a throwaway reader and a
      throwaway unlisted account: the reader sees a consumed document and a
      correspondent the editor created (after a configuration run), cannot
      upload (`403`) or change anything; a document tagged `private` at
      upload, and one tagged `private` later, disappear for the reader; a
      document whose `private` tag is removed is readable again after the
      nightly run; the unlisted account sees nothing. Users deleted
      afterwards. `docs/paperless.md` "Access". [1.4, 9.1, 9.2, 9.3, 9.4,
      9.5]
- [ ] 5. Consistent backup with the export: in
      `paperless-backup`, init container 1 with `paperless-data` read-write
      and the SQLite backup API (tag `paperless-db`, `db.sqlite3*` excluded
      from `paperless-data`), init container 2 running `document_exporter
      --skip-checks --passphrase` (SOPS `paperless-export`) on the `/db`
      copy (`PAPERLESS_DATA_DIR=/db`, `paperless-media` read-only, the
      `export-meta.json` count from the same copy) into the new PVC
      `paperless-export` (100Gi, `iscsi-retain`), then restic with
      `/export` added;
      `restic-targets.txt` (`paperless-data` required file
      `celerybeat-schedule.db`, new `paperless-db` and `paperless-export`
      lines), `docs/backups.md` rows. Check: `document_exporter` on 3.4.1
      accepts `--skip-checks` and starts with these mounts (else
      `paperless-media` read-write in init container 2); a manual run
      snapshots all four tags; a run with a wrong passphrase variable fails
      before restic starts. Takes the Paperless part of #746; the issue keeps Jellyfin and
      Grafana. [7.1, 7.2, 7.5, 8.1, 8.3]
- [ ] 6. Restore test: `restore-paperless` in `backup-verify` (`migrate`,
      `document_importer --passphrase` and a count in one pod with no web
      server, worker or beat; no TCP 993 egress; counts equal, one PDF
      opens), the passphrase copy in `backup-verify`, its alert, promtool
      test and runbook. Check: one manual run passes, one with a corrupted
      manifest fails and the alert test fires. [7.3, 7.4, 8.2]
- [ ] 7. Inbox folder: the TrueNAS dataset
      `homelab/k8s/nfs/paperless-inbox` and its NFS export to the four nodes
      (operator, or an agent given the TrueNAS API key), the static PVs and
      PVCs in `paperless` and `syncthing`, the mounts,
      `PAPERLESS_CONSUMER_POLLING=30`, the `source-folder` workflow, one
      Syncthing folder shared with the editor's devices, with 30-day trash
      can versioning on those devices. Check: a file dropped on the Mac is
      findable within 5 minutes, owned by the editor, readable by the
      reader, and in the Mac's `.stversions`; an NFS mount from the Mac is
      refused. [2.1, 2.2, 2.3, 2.4, 10.1]
- [ ] 8. Phone and API: the client app (first in the design table that logs
      in with a token against 3.4.1), the editor's API token, the
      `source-phone` workflow, the setup in `docs/paperless.md`. Check: one
      camera scan and one share-sheet upload, findable within 5 minutes and
      owned by the editor; a revoked token gets `401` (Paperless keeps one
      token per user, so the new token then goes to every device of the
      editor and to the import script). Also check whether
      `/api/` accepts the local admin password over basic auth from the
      internet; if it does, open a security issue. [1.1, 1.2, 1.3, 10.1]
- [ ] 9. Mail: the mailbox (open question 2), SOPS `paperless-mail`, the
      mail account and one mail rule per household sender address
      through `apply.py`, the `source-mail` workflow,
      egress TCP 993 in the CiliumNetworkPolicy `paperless`. Check: a
      forwarded attachment from a household address is findable within 15
      minutes, owned by the editor, tagged `inbox`, and the mail is in
      `Processed`; a mail from another address is left unread. The PR lists
      the DMARC policy of each household sender domain. [3.1, 3.2, 3.3,
      3.4, 3.5, 3.6, 10.2]
- [ ] 10. Scanner (planned, optional, after task 9): if a scanner is in
      use, scan to mail through the mailbox, the mail rule `scanner` and
      the `source-scan` workflow. If there is none when task 14 starts,
      task 14 ticks this task as not needed. Check: a 10-page scan is findable
      within 15 minutes, owned by the editor, tagged `source:scan`.
      [4.1, 4.2, 10.2]
- [ ] 11. Ingest canary: `paperless-canary`, the user `canary` with its own
      add, view and delete document permissions, its token in SOPS, the
      network policy to the Pushgateway, `PaperlessIngestFailing` and
      `PaperlessIngestSlow` with promtool tests and runbooks. Check: a week
      of canary results on the Data protection dashboard. [10.3, 10.4]
- [ ] 12. Import script: `scripts/paperless-import.py` with pytest (upload
      with the editor's token, tags, task follow-up, the local report,
      counts only on stdout). [6.2, 6.4]
- [ ] 13. Import batches: every source subdirectory under
      `~/homelab-backups/paperless-import/`, the Seafile export first, run
      during the day; one PR records the counts of every batch (in =
      created + duplicates + failed) and the failure reasons in
      `docs/paperless.md`, opened when the batches are imported; the
      file-level reports stay local. [6.2, 6.3, 6.4]
- [ ] 14. Close: `docs/paperless.md` complete (ways in, taxonomy, access,
      export, restore), the README Services row, the `docs/threat-model.md`
      documents row (forged mail sender, `p=none` sender domains, the
      `automation` token's reach), the media-home area spec updated with how
      Paperless works now; then header `status: done`, `closed:`, issue #732
      closed.
