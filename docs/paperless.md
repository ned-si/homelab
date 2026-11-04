# Paperless

Paperless-ngx at `https://archive.lilalala.com`, namespace `paperless`. It
holds the household's finished documents: letters, bills, statements,
contracts, certificates. Working documents stay where they are edited. The
way it is built is in the spec
[paperless-documents](../.kiro/specs/paperless-documents/design.md); this page says
how to operate it.

| What | Where |
| --- | --- |
| App | `apps/paperless/deployment.yaml`: one replica, SQLite in `paperless-data`, Valkey queue, OCR `fra+eng+spa+deu`, time zone `Europe/Zurich`, dates `DMY` |
| Taxonomy as code | `apps/paperless/config/paperless.json`, applied by `config/apply.py` (`apply.yaml`) |
| Backup and export | `apps/paperless/backup.yaml`, 02:30 UTC |
| Restore test | `platform/backup-verify/restore-paperless.yaml`, the 3rd of the month |
| Ingest canary | `apps/paperless/canary.yaml`, every 6 hours |
| Import of existing files | `scripts/paperless-import.py`, from the Mac |

## Uploading

The web app is the only way in, besides the one-off import below. Log in at
`https://archive.lilalala.com` through Keycloak, then:

- on a computer: the upload button on the dashboard, or drag and drop files
  onto it;
- on a phone: the same page in the browser; its file picker offers a file or
  a new photo from the camera. Nothing is installed on the phone.

An upload of up to 10 pages is OCRed and findable by a full-text search
within 5 minutes; the ingest canary checks that every 6 hours. Only the
editor can upload: the readers get `403`. A new upload is owned by the editor
and readable by the readers until it is tagged `private`. The mail import is
off (`PAPERLESS_EMAIL_TASK_CRON=disable`) and nothing writes to the consume
volume.

## Filing

Paperless files a document on consumption with matching rules; the editor
reviews what lands in the `inbox` tag and fixes what matching missed.

| Object | Values | Who changes them |
| --- | --- | --- |
| Document types and retention | Invoice 5 years, Receipt 2, Statement 10, Tax 10, Payslip forever, Insurance forever, Contract forever, Medical 10, Official forever, Warranty forever, Letter 5 (set by hand) | git |
| Tags | area: `housing`, `car`, `health`, `finance`, `insurance`, `work`, `utilities`, `telecom`, `travel`, `family`; state: `inbox`, `to-pay` (a Swiss QR-bill), `tax-relevant` (added to Tax, Statement, Payslip, Insurance), `private`; `import:<source>` for imported files | git |
| Custom fields | `Retain until`, `Amount` (CHF), `Due date`, `Tax year` | git |
| Saved views | Inbox, To pay, Tax year, Retention expired, Recently added | git |
| Correspondents | banks, insurers, authorities, landlord: real names, so never in git | the editor, in the UI |

- Matching: each type has specific keywords in French, German and English
  (`Any`, quoted phrases) or a `Regex`; no keyword belongs to two types, and
  a corpus of synthetic texts (`tests/paperless/corpus/`) proves it in CI. A
  type moves to Paperless' automatic classifier only by a change in git,
  once 20 documents carry it.
- `Retain until` is recomputed every night (`paperless-apply-nightly`, 04:40
  UTC) from the type and the creation date; a date set by hand is
  overwritten. "Retention expired" lists what may go. Deleting is a person's
  decision; the trash keeps a document for 30 days.
- File names on disk and in the export:
  `<year>/<document type>/<created> <correspondent> <title>`
  (`PAPERLESS_FILENAME_FORMAT`). No storage paths.
- To change a type, tag, keyword, field or view: edit `paperless.json` and
  merge. The PostSync `paperless-apply` upserts it and deletes nothing; an
  object in Paperless but not in the file is only reported. Removing one is
  done in the UI as `nedsi-admin`, because it strips it from every document.

## Access

Logging in goes through Keycloak only. The Keycloak groups `admins` and
`family` may log in (`platform/keycloak/realm/access.conf`). Paperless
creates an account on the first login, with no group, so a new login sees
an empty dashboard and its profile, nothing else.

Inside Paperless there are two roles:

| Role | Paperless group | Can | Sees |
| --- | --- | --- | --- |
| Editor | `editors` | upload; view, change and delete documents, correspondents and notes; view types, tags, custom fields, saved views, file tasks and statistics | every document (the editor owns them all) |
| Reader | `readers` | view documents, correspondents, notes, types, tags, custom fields and saved views | every document without the `private` tag |
| Any other account | none | nothing | nothing |
| `nedsi-admin` | none, superuser | everything | everything: break-glass only |
| `automation` | none, superuser, API token only | everything | everything: the configuration Jobs |
| `canary` | none, API token only, works on the public `/api/` | add, view and delete documents | its own canary pages, for the minutes they exist |

Neither group has rights on users, groups, workflows, mail or settings. The
types, tags, custom fields, saved views and workflows are owned by git
(`apps/paperless/config/paperless.json`), so neither group may change them.

### Who is in which group

The member list is the SOPS Secret `apps/secrets/paperless-config.sops.yaml`,
key `config.json`, one JSON value:

```json
{"editors": ["<username or email>"], "readers": ["<username or email>"]}
```

An entry matches a Paperless account by username or by the email of the
Keycloak account, in any case. `apply.py` (the PostSync Job
`paperless-apply` and the nightly CronJob `paperless-apply-nightly` at
04:40 UTC) puts the listed accounts into their group and takes every other
account out of both groups. Its log has counts only:

```
group editors: 1 listed account(s) found
group readers: 1 listed account(s) found
accounts: 0 membership change(s); 0 account(s) other than nedsi-admin, automation, canary with the superuser flag or direct permissions
```

A listed person who has not logged in yet shows as `not found (no Paperless
login yet)`. Paperless refuses nothing because of it.

### Add a person

1. In the Keycloak admin console, realm `homelab`, put the user in the group
   `family`.
2. The person logs in once at `https://archive.lilalala.com`. They see an
   empty dashboard: that is expected.
3. Add their email (or Paperless username) to `editors` or `readers`:
   `sops edit apps/secrets/paperless-config.sops.yaml`, open a pull request,
   merge. The PostSync `paperless-apply` adds them.
4. If the entry was already listed before their first login, the next
   nightly run adds them. To do it at once:

   ```sh
   kubectl -n paperless create job --from=cronjob/paperless-apply-nightly paperless-apply-now
   kubectl -n paperless wait --for=condition=complete job/paperless-apply-now --timeout=15m
   kubectl -n paperless logs job/paperless-apply-now
   kubectl -n paperless delete job paperless-apply-now
   ```

   Expected in the log: `group readers: 1 listed account(s) found`.

To remove a person, delete their entry and merge; their account stays,
with no group, and sees nothing. Deleting the account itself is done in
Paperless (Settings, Users & Groups) as `nedsi-admin`; it cannot be undone.

### Sharing and hiding documents

- The workflow `share` gives `readers` view on every document uploaded
  through the web app or the API. The uploader stays the owner. That
  includes the ingest canary's pages (`canary <number>`): the readers can
  see one for the minutes it exists, or until it is deleted by hand when a
  run's cleanup failed.
- The `private` tag is the only way to hide a document from the readers.
  The workflow `private` (the last one) removes their view and change
  rights when a document is added with the tag or edited while it has it.
- Removing the `private` tag makes the document readable again after the
  nightly run, or at once through the document's permissions dialog.
- Removing the readers' view in the permissions dialog without the tag
  lasts only until the nightly run, which gives it back.

### Dashboard

The saved views (Inbox, To pay, Tax year, Retention expired, Recently
added) belong to no account, so both groups see them under Documents,
Views. Which views sit on the dashboard is each person's own UI setting:
Settings, Saved views, "Show on dashboard". Only the person's own session
can write it.

### Break-glass

The editor's account is not a superuser. For administration, log in as
`nedsi-admin` with the password in `paperless-secrets`, key
`PAPERLESS_ADMIN_PASSWORD`, at
`https://archive.lilalala.com/accounts/login/?loggedout=1`. The
`loggedout=1` parameter stops the page's JavaScript redirect to Keycloak
(`PAPERLESS_REDIRECT_LOGIN_TO_SSO`), so the local form stays. The Django
admin is then at `/admin/`.

If that login fails, set the flag back from the pod, over the tailnet:

```sh
kubectl -n paperless exec deploy/paperless -- s6-setuidgid paperless python3 manage.py shell -c \
  "from django.contrib.auth.models import User; u = User.objects.get(username='nedsi-admin'); u.is_superuser = True; u.is_active = True; u.save(); print('ok')"
kubectl -n paperless exec -it deploy/paperless -- s6-setuidgid paperless python3 manage.py changepassword nedsi-admin
```

Expected: `ok`, then the password prompt. Seal the new password in
`paperless-secrets` afterwards ([secrets.md](secrets.md)).

## Importing existing documents

Existing files go in once, from the Mac, with `scripts/paperless-import.py`.

1. Put each source's files in its own directory:
   `~/homelab-backups/paperless-import/<source>/`. The directory name is
   the source and goes into git as the tag `import:<source>`, so it must be
   generic (`mac`, `drive`). Sub-folders are fine; they do not become tags.
2. The tag must exist. None does yet: each source gets its tag in
   `apps/paperless/config/paperless.json` in a one-line PR, merged before
   its batch.
3. In the web app, as the editor: Profile, API Auth Token, create one.
4. Run a batch during the day, a few hundred files at a time:

   ```sh
   PAPERLESS_API_TOKEN=<editor's token> scripts/paperless-import.py ~/homelab-backups/paperless-import/<source> --limit 300
   ```

   Expected: `import:<source>: in <n>, created <c>, duplicates <d>, failed <f>`,
   the failures by reason class, and the path of the local report
   (`~/homelab-backups/paperless-import/.reports/<source>-<UTC>.csv`: one
   row per file with its status, document id and reason). Exit 0 without
   failures, 1 with failures, 2 when it stopped before the first upload
   (missing tag, non-generic name, no token).
5. Run it again until it uploads nothing new: a file whose content is
   already in Paperless counts as a duplicate and is not uploaded. A failed
   upload is not retried within a run, so a server error after Paperless
   queued the file never adds a second copy.
6. Delete the editor's token after the last batch.

Every file is uploaded as the editor with its tag, one at a time, and the
script waits for its consumption. The file names stay in the local report;
the counts of each batch go into this page.

## Backups, export and restore

`paperless/paperless-backup`, 02:30 UTC, one Job in three steps:

1. `db-copy`: a consistent copy of `db.sqlite3` through SQLite's backup API,
   checked with `PRAGMA integrity_check`.
2. `export`: `document_exporter` on that copy into the PVC `paperless-export`:
   the originals, the archived PDFs and `manifest.json`, with the readable
   file names above, plus `export-meta.json` with the document count.
3. `restic`: four snapshots in `paperless/media` on S3, tags
   `paperless-db`, `paperless-media`, `paperless-data`, `paperless-export`.

A failed step fails the Job before restic starts and pages as
`KubeJobFailed`. The export passphrase (Secret `paperless-export`) encrypts
only the social account tokens in `manifest.json`; the documents and every
other field stay plain.

Reading the documents without Paperless: restore the tag `paperless-export`
with the steps in [backups.md](backups.md#how-to-restore), for example
`restic restore latest --tag paperless-export --target <dir>`. The result is
plain PDFs and originals in `<year>/<document type>/` and a JSON manifest.

Every month (the 3rd, 19:00 UTC) `backup-verify/backup-verify-paperless`
restores the newest export and imports it into a throwaway Paperless in its
own pod. It passes when the imported documents, `manifest.json` and
`export-meta.json` count the same and a random PDF opens.
`PaperlessRestoreStale` pages after 35 days without a pass
([runbook](runbooks/alerts/PaperlessRestoreStale.md)). Schedule and
retention: [backups.md](backups.md).

## Ingest canary

`paperless/paperless-canary`, at 01:00, 07:00, 13:00 and 19:00 UTC, as the
user `canary` (token in Secret `paperless-canary`):

1. It uploads a generated one-page PDF with a random 12-digit number.
2. It polls a full-text search for the number every 5 s, for up to 15 minutes.
3. It deletes the page and empties it from the trash.
4. It pushes `paperless_canary_success` and
   `paperless_canary_duration_seconds` to the Pushgateway.

The Homelab / Data protection dashboard shows the last success and the
upload-to-findable time over 7 days. `PaperlessIngestFailing` pages after 13
hours without a success; `PaperlessIngestSlow` pages when two successful
runs in a row take over 5 minutes. Both runbooks are in `docs/runbooks/alerts/`.

Run it by hand:

```sh
kubectl -n paperless create job --from=cronjob/paperless-canary canary-now
kubectl -n paperless wait --for=condition=complete --timeout=25m job/canary-now
kubectl -n paperless logs job/canary-now
kubectl -n paperless delete job canary-now
```

Expected: `PASS findable after <n> s`.

## Why it is like this

- One way in, the web app. It works from a phone browser, so a mail import,
  a scanner folder or an app would add credentials and moving parts for
  nothing day to day. Another way in is a new issue.
- Git owns the taxonomy. Changes are reviewed and kept with the repo; the
  editor files documents and correspondents. Rejected: configuring it in the
  UI, where the backup is the only record.
- Correspondents are not in git: they are real names, and the repository is
  public.
- One editor owns every document, so matching always sees every type, tag
  and correspondent, and the `private` tag is the only rule about what the
  readers see.
- The nightly export makes the archive readable without Paperless. It runs
  inside the backup Job, so restic only ever snapshots a finished export.
- SQLite stays: [runbooks/paperless-postgres.md](runbooks/paperless-postgres.md)
  explains why.
