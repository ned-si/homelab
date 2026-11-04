# Tasks: paperless-documents

One PR per task, in order unless a task says otherwise; each is safe on its
own. Tasks that restart Paperless or write to the cluster or the NAS run on
a weekday, during the day (Zurich). No question is open; the decisions are
in [requirements.md](requirements.md#decided-defaults).

## Done

- [x] 1. Settings: `PAPERLESS_OCR_LANGUAGE=fra+eng+spa+deu`,
      `PAPERLESS_TIME_ZONE=Europe/Zurich`, `PAPERLESS_DATE_ORDER=DMY`,
      `PAPERLESS_FILENAME_FORMAT`. Check: a French, an English, a Spanish
      and a German test page, uploaded through the web app (one from a
      phone browser with a camera photo, the others from a computer), are
      OCRed and findable; a 10-page file uploaded through the web app is
      findable within 5 minutes [7.1]; the OCR time and the container's
      peak memory (`container_memory_working_set_bytes`) for one page and
      for the 10-page file, with the four languages and with `fra` alone,
      are in the PR, and the Deployment gets a memory request from them;
      the one existing document is renamed on disk. [1.1, 2.1, 2.6]
      (#1009; the phone-camera upload is #1008)

## Open
- [ ] 2. Configuration as code: `apps/paperless/config/paperless.json`
      (document types, tags, custom fields, saved views and workflows, the
      approved [taxonomy](design.md#taxonomy)), `apply.py` with pytest
      against a fake API: the unquoted phrase and shared keyword checks, the
      synthetic FR/DE/EN corpus in `tests/paperless/corpus/` (each text
      matches exactly its expected type, a QR-bill per language none; texts
      with `’`), the `owner: null` and `set_permissions` fields of every
      request, the correspondent and document permission passes, the
      `Retain until` recomputation (a Receipt re-typed to Contract loses
      its date, a moved creation date moves it, an untyped document has
      none), the wait for `/api/` and the retry on `5xx`. The user
      `automation` and its API token in SOPS `paperless-automation`
      (`docs/secrets.md` with the token's reach, `ci/secret-rotation.tsv`),
      the PostSync Job and the nightly `--nightly` CronJob
      (`ci/active-cronjobs.txt`). Check: a second run reports 0 changes; a
      saved view with `owner: null` is listed and can go on the dashboard
      for both groups on 3.4.1, or `apply.py` creates one copy per listed
      account. [2.2, 2.3, 2.4, 2.5, 6.5]
- [ ] 3. Access: the groups `editors` and `readers` and their permissions,
      the member list in SOPS `paperless-config` (one encrypted
      `config.json` value), the editor's and the reader's accounts put into
      their groups by `apply.py`, the superuser flag and direct model
      permissions of every account listed in the PR (counts and flags, no
      usernames) and cleared on every account other than `nedsi-admin`,
      `automation` and `canary`, the editor's included, once `nedsi-admin`
      is proven to reach the admin with `PAPERLESS_REDIRECT_LOGIN_TO_SSO`
      set (else the `manage.py shell` recovery is recorded in
      `docs/paperless.md`), the `share` and `private` workflows (`private`
      last). Check: `automation` keeps its superuser flag and the next
      PostSync run of `apply.py` passes; a web upload by the editor is
      owned by the editor; a matrix with a throwaway reader and a throwaway
      unlisted account: the reader sees an uploaded document and a
      correspondent the editor created (after a configuration run), cannot
      upload (`403`) or change anything; a document uploaded through the
      web app and then tagged `private` by the editor disappears for the
      reader; a
      document whose `private` tag is removed is readable again after the
      nightly run; the unlisted account sees nothing. Users deleted
      afterwards. Also check whether `/api/` accepts the local admin
      password over basic auth from the internet; if it does, open a
      security issue. `docs/paperless.md` "Access", which says the
      `private` tag is the only way to hide a document. [1.2, 1.3, 6.1,
      6.2, 6.3, 6.4, 6.5]
- [ ] 4. Consistent backup with the export: in
      `paperless-backup`, init container 1 with `paperless-data` read-write
      and the SQLite backup API (tag `paperless-db`, `db.sqlite3*` excluded
      from `paperless-data`), init container 2 running `document_exporter
      --skip-checks --passphrase` (SOPS `paperless-export`) on the `/db`
      copy (`PAPERLESS_DATA_DIR=/db`, `paperless-media` read-only, the
      `export-meta.json` count from the same copy) into the new PVC
      `paperless-export` (100Gi, `iscsi-retain`), then restic with
      `/export` added; `backoffLimit: 1` on the Job;
      `restic-targets.txt` (`paperless-data` required file
      `celerybeat-schedule.db`, new `paperless-db` and `paperless-export`
      lines), `docs/backups.md` rows. Check: `document_exporter` on 3.4.1
      accepts `--skip-checks` and starts with these mounts (else
      `paperless-media` read-write in init container 2); a manual run
      snapshots all four tags; a run with a wrong passphrase variable fails
      before restic starts. Takes the Paperless part of #746; the issue
      keeps Jellyfin and Grafana. [4.1, 4.2, 4.5, 5.1, 5.3]
- [ ] 5. Restore test: `restore-paperless` in `backup-verify` (`migrate`,
      `document_importer --passphrase` and a count in one pod with no web
      server, worker or beat; counts equal over the exported documents,
      one PDF opens), the passphrase copy in `backup-verify`, its alert,
      promtool test and runbook. Check: the exporter on 3.4.1 skips
      trashed documents; one manual run with a non-empty trash passes, one
      with a corrupted manifest fails and the alert test fires. [4.3, 4.4,
      5.2]
- [ ] 6. Ingest canary: `paperless-canary`, the user `canary` with its own
      add, view and delete document permissions, its API token in SOPS
      `paperless-canary`, the digits-only number in a large font, the
      egress rule to the Pushgateway in the CiliumNetworkPolicy
      `paperless`, `paperless/paperless-canary` in
      `ci/active-cronjobs.txt`, `PaperlessIngestFailing` and
      `PaperlessIngestSlow` with promtool tests and runbooks. Check: a week
      of canary results on the Data protection dashboard. [7.2, 7.3]
- [ ] 7. Import script: `scripts/paperless-import.py` with pytest (upload
      as the editor with the tag, the stop when `import:<source>` is
      missing, task follow-up, the local report, counts only on stdout),
      and the `import:<source>` tags of the sources present in
      `paperless.json` (generic names). [3.1, 3.3]
- [ ] 8. Import batches: every source subdirectory under
      `~/homelab-backups/paperless-import/`, run during the day with an
      API token of the editor's account created for the batches and
      deleted after the last one; a source added after task 7 gets its
      `import:<source>` tag in a one-line PR before its batch; one PR records the counts of every batch (in = created +
      duplicates + failed) and the failure reasons in `docs/paperless.md`,
      opened when the batches are imported; the file-level reports stay
      local. [3.1, 3.2, 3.3]
- [ ] 9. Close: `docs/paperless.md` complete (the web upload, taxonomy,
      access, export, restore), the README Services row, the
      `docs/threat-model.md` documents row (the `automation` token's reach,
      open egress from `paperless` while it is in audit mode), the
      media-home area spec updated with how Paperless works now; then
      header `status: done`, `closed:`, issue #732 closed.
