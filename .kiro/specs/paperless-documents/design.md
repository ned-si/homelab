# Design: paperless-documents

## Current state (read-only, 2026-11-03)

| What | Value |
| --- | --- |
| Image | `ghcr.io/paperless-ngx/paperless-ngx:3.4.1`, one replica, SQLite (journal mode `wal`), Valkey queue |
| URL, login | `archive.lilalala.com`, Keycloak only (`PAPERLESS_REDIRECT_LOGIN_TO_SSO`, auto signup), groups `admins` and `family` (`access.conf`, PR #468) |
| Volumes | `paperless-data` 4Gi (27M used), `paperless-media` 100Gi (1 MiB used), `paperless-consume` 10Gi (empty), all iSCSI |
| Content | 1 document, 0 correspondents, document types, tags, storage paths, workflows; 5 user accounts |
| OCR | `eng` only; the image ships `deu eng fra ita osd spa` |
| Time zone, dates | `UTC`, `DMY` |
| File names | default (`FILENAME_FORMAT` unset: numeric names) |
| Ways in | web upload only; nothing writes to the consume volume |
| Backup | `paperless-backup` 02:30 to restic `paperless/media` (tags `paperless-media`, `paperless-data`), monthly `paperless-prune`; the restic image has no `sqlite3`, so the `paperless-db` branch never runs and `db.sqlite3` is copied live inside `paperless-data`, where it can be torn (#746) |
| Restore test | `backup-verify` weekly sample: `paperless-media`, `paperless-data` with `/data/db.sqlite3`; monthly pack read |
| Network | CiliumNetworkPolicy `paperless`: ingress from the Gateway, egress DNS, intra-namespace, TCP 443 to the world; audit mode only (`enforce-default-deny` off in both directions), so it blocks nothing. `backup-verify` has no policy |

## Shape

```
editor ──Keycloak──▶ web app (phone or computer browser) ──upload──┐
operator's Mac ──scripts/paperless-import.py, one-off──────────────┤
                                                                   ▼
                       Paperless (consume, OCR fra+eng+spa+deu, matching,
                       workflows: view = readers, private)
                                              │
             02:30 paperless-backup, one Job, in order:
                   1. consistent SQLite copy
                   2. document_exporter --passphrase ─▶ PVC paperless-export
                   3. restic: db + media + data + export ─▶ restic paperless/media
             monthly backup-verify ── restore paperless-export ─▶ throwaway Paperless (no worker), document_importer, counts
             every 6 h paperless-canary ── generated PDF ─▶ API ─▶ search ─▶ Pushgateway
reader ──Keycloak──▶ web app, view only
```

## Way in: the web app

The editor uploads through the Paperless web app at
`https://archive.lilalala.com` (operator decision, 2026-11-03), logged in
through Keycloak like every app. On a computer: the upload button or drag
and drop onto the dashboard. On a phone: the same page in the browser,
whose file picker offers a file or a new photo from the camera. Nothing is
installed on the phone and no credential is stored there beyond the
browser's Keycloak session.

The web app uploads through `/api/documents/post_document/` with the
logged-in session, so every upload is owned by the uploader: the editor.
The reader has no add right, so an upload with the reader's session is
refused. No other way in is built: the consume volume stays as it is, and
another way in is a new issue.

No source tag. There is one way in, and imported documents carry
`import:<source>` (see [Import](#import)), so a document without it came
through the web app; a `source:web` tag would add nothing.

## Settings

Environment changes in `apps/paperless/deployment.yaml`:

| Variable | Value | Why | Task |
| --- | --- | --- | --- |
| `PAPERLESS_OCR_LANGUAGE` | `fra+eng+spa+deu` (decided 2026-11-03) | the household's languages, most frequent first: Tesseract treats the first as primary; all four are in the image, so `PAPERLESS_OCR_LANGUAGES` stays unset | 1 |
| `PAPERLESS_TIME_ZONE` | `Europe/Zurich` | creation dates near midnight land on the right day | 1 |
| `PAPERLESS_DATE_ORDER` | `DMY` | explicit (today's default) | 1 |
| `PAPERLESS_FILENAME_FORMAT` | `{{ created_year }}/{{ document_type }}/{{ created }} {{ correspondent }} {{ title }}` | readable files in the media volume and the export | 1 |

`PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS` stays unset: a new Keycloak login
gets no group, and the configuration Job puts listed accounts into their
group ([Access](#access)).

Setting the file name format renames existing files on disk. With one
document today that is free, and restic stores renamed files without new
data, which is why it comes before the import.

## Taxonomy

Decided: the operator approved this taxonomy as proposed on 2026-11-03.
Names are in English; the matching keywords cover French, German and English.
Spanish documents are rare, so the editor types them by hand; Spanish
keywords and corpus texts are added in git if they become common.

### Matching rules for the keywords

- Algorithm `Any`, case-insensitive. Paperless splits the match string on
  spaces and matches whole words, so a phrase is written in double quotes:
  `"ticket de caisse"`, never `ticket de caisse` (which would match every
  French document through `de`).
- A phrase with an apostrophe is a `Regex` with `['’]`, because PDFs and
  OCR output use both the straight (U+0027) and the typographic (U+2019)
  apostrophe. Tax and Insurance therefore use `Regex`.
- A document type gets only specific keywords. Generic words (`facture`,
  `Rechnung`, `invoice`, `statement`, `policy`, `attestation`, `contrat`,
  `certificat`) are left out: they appear in letters of every type. A bank
  statement or a premium notice often says `facture` or `Rechnung`, and a
  payslip may say `invoice` in a footer.
- When several types match, Paperless keeps the first by name, so a
  collision is decided by the alphabet, not by the document. Two tests in
  `apply.py`'s suite keep collisions out:
  - no keyword belongs to two document types, and every phrase in an `Any`
    rule is quoted;
  - a corpus of synthetic sample texts in `tests/paperless/corpus/`, at
    least one per type in French, German and English, written to include
    the generic words above (a statement that mentions `facture`, a payslip
    whose footer says `invoice`), plus a Swiss QR-bill in each language
    (receipt part headed `Récépissé`, `Empfangsschein`, `Receipt`) and some
    texts with `’`. Each text names its expected type, or none. The test
    runs Paperless' `Any` rule (whole words, case-insensitive, quoted
    phrases) and the `Regex` rules over each text and fails when the
    matched types differ from the expected one. The texts are invented: no
    real document content.

### Document types and retention

| Type | Matching (`Any`, case-insensitive) | Retain |
| --- | --- | --- |
| Invoice | `"numéro de facture" Rechnungsnummer "invoice number" "invoice no"` | 5 years |
| Receipt | `quittance "ticket de caisse" Quittung Kassenbon "till receipt" "sales receipt"` (no bare `receipt`: an English QR-bill's receipt part is headed "Receipt") | 2 years |
| Statement | `"relevé de compte" "extrait de compte" Kontoauszug "bank statement"` | 10 years |
| Tax | `Regex`: `\b(déclaration d['’]impôts?\|décision de taxation\|steuererklärung\|veranlagungsverfügung\|tax return)\b` | 10 years |
| Payslip | `"fiche de salaire" "décompte de salaire" "certificat de salaire" Lohnabrechnung Lohnausweis payslip` | forever |
| Insurance | `Regex`: `\b(police d['’]assurance\|attestation d['’]assurance\|versicherungspolice\|versicherungsnachweis\|insurance policy)\b` | forever |
| Contract | `"contrat de bail" "contrat de travail" Mietvertrag Arbeitsvertrag "rental agreement" "employment contract"` | forever |
| Medical | `"ordonnance médicale" "rapport médical" Arztbericht Arztzeugnis "medical report"` | 10 years |
| Official | `"acte de naissance" "acte de mariage" "certificat de domicile" Geburtsurkunde Wohnsitzbestätigung "birth certificate"` | forever |
| Warranty | `"certificat de garantie" Garantieschein "warranty card"` | forever |
| Letter | none: set by hand (the fallback) | 5 years |

A bill with a Swiss QR payment part and no invoice number gets no type from
matching; it still gets `to-pay` (below), which is what the editor acts on.
The corpus test decides whether a keyword is specific enough; the table
changes when a corpus text shows a collision.

"Forever" means no `Retain until` date. A nightly run of the configuration
script recomputes `Retain until` on every document from its current type
and creation date: creation date + the type's period, or no date for a
"forever" type or a document without a type. It writes only the documents
whose date differs, so a document re-typed from Receipt to Contract loses
its date, and one whose creation date is corrected gets a new one, by the
next morning. A date set by hand is overwritten: there is no manual
override. The saved view "Retention expired" lists the documents past
their date. Deleting stays a person's decision; deleted
documents stay in the trash for 30 days (`EMPTY_TRASH_DELAY`).

### Tags

| Group | Tags |
| --- | --- |
| Area | `housing`, `car`, `health`, `finance`, `insurance`, `work`, `utilities`, `telecom`, `travel`, `family` |
| State | `inbox` (Paperless' inbox tag, removed after review), `to-pay`, `tax-relevant`, `private` |
| Import | `import:<source>`, one per import source (no source tags: [Way in](#way-in-the-web-app)) |

Area tags match on keywords under the same rules (for example `utilities`:
`électricité Strom electricity "eau potable" Wasserversorgung`); `to-pay`
matches a Swiss QR-bill with a `Regex`
(`Zahlteil|Section paiement|Payment part|Sezione pagamento`);
`tax-relevant` is added by a workflow to the types Tax, Statement, Payslip
and Insurance. `private` never matches: the editor sets it. The
`import:<source>` tags are in `paperless.json` like every other tag, one per
import source, and `apply.py` creates them without
an owner; the import script only attaches them (see [Import](#import)).

### Custom fields

`Retain until` (date), `Amount` (monetary, CHF), `Due date` (date),
`Tax year` (integer).

### Storage paths: none

The taxonomy uses no storage paths. The global `PAPERLESS_FILENAME_FORMAT`
already gives one tree per year and document type, which is the layout the
export and a reader without Paperless need. A storage path would override
that per document, and matching would have to choose it right every time.
If a type needs a different layout, a storage path for that type is added
in git like the other objects.

### Correspondents

Kept in Paperless only, never in git: they are real names. Examples of the
kind: a bank, the health insurer, the cantonal tax office, the landlord, a
utility, a payroll office. The editor creates them and sets their match
text (name, IBAN, UID number) in the UI.

### Saved views

Inbox (`inbox`), To pay (`to-pay`, by `Due date`), Tax year (`tax-relevant`,
by `Tax year`), Retention expired (`Retain until` before today), Recently
added. Created without an owner, so both groups see them, and shown on the
dashboard. Through 2.x, saved views were listed per owner and dashboard
visibility was a per-user UI setting; task 2 checks this on 3.4.1, and if
it still holds, `apply.py` creates one copy of each view per listed
account, owned by that account.

## Matching and workflows

Explicit matching first (`Any` keywords, `Regex` for the QR-bill), because
the automatic classifier needs training data the archive does not have. A
type or tag moves to `Auto` in git once 20 documents carry it.

Sharing default, decided by the operator on 2026-11-03: a document is
visible to the reader by default, and the `private` tag hides it. The
workflows below implement that.

Workflows run in the order of their `order` field; `private` is last, so
nothing after it gives the view back.

| Order | Workflow | Trigger, filter | Actions |
| --- | --- | --- | --- |
| 10 | share | Consumption started, sources Web UI (the web app) and API upload (the import script, the canary) | view for group `readers` (the owner stays the uploader) |
| 20 | tax-relevant | Document added, type Tax, Statement, Payslip or Insurance | tag `tax-relevant` |
| 90 | private | Document added and Document updated, has tag `private` | remove view and change for group `readers` |

The `private` workflow fires on every edit of a private document, so
setting the tag at any time hides the document from the readers. Removing
the tag does not give the view back by itself: the nightly configuration
run reconciles the readers' view on every document (view for `readers` if
and only if the document has no `private` tag), so a document made public
again is readable the next morning, or at once through the document's
permissions dialog. The same pass reverts the other direction: removing
the readers' view in the permissions dialog lasts until the next night, so
the `private` tag is the only way to hide a document, and
`docs/paperless.md` says so. No workflow sets the owner: every upload is
made as the editor (or as `canary`), so the uploader is already the right
owner.

## Configuration as code

Git owns the document types, tags, custom fields, storage paths (none
today), saved views and workflows. The editor changes documents and
correspondents; both groups have view rights on the types, tags, custom
fields and saved views, none on workflows, and no change rights, so a sync
never reverts an edit made in the UI. A new tag or a
better keyword is an issue or a PR, which an agent can do.

`apps/paperless/config/paperless.json`: the objects above, workflows
included. The SOPS Secret `paperless-config` holds the personal part (the
editor's and the reader's usernames) as one key, `config.json`, whose single
encrypted value is a JSON document. SOPS here encrypts values and leaves
keys readable, so no username is ever a key.

`apps/paperless/config/apply.py` (Python stdlib, `urllib` and `json`) reads
both and upserts through the API by name: it creates what is missing and
updates what differs. It deletes nothing: an object that is in Paperless
but not in the configuration is reported, and a person removes it, because
removing a tag or type strips it from every document.

Object permissions. Paperless gives every object created through the API
its caller as owner unless the request sets `owner: null`, and an owned
object is hidden from users without a grant on it. `apply.py` therefore:

- creates and updates document types, tags, custom fields and saved views
  with `owner: null`, so every account with the model's view permission
  sees them (both groups do; unlisted accounts have no model permissions);
- puts the listed accounts into `editors` and `readers`, and removes
  accounts that are no longer listed from both;
- reports every account other than `nedsi-admin`, `automation` and
  `canary` that has the superuser flag or direct model permissions;
- grants view for `readers` on every correspondent that lacks it, without
  reading or changing names (a permissions-only pass, so names stay out of
  git and out of the Job's log);
- in the nightly run, reconciles the `readers` view on documents with the
  `private` tag, as described in [Matching and workflows](#matching-and-workflows).

Its unit tests assert the `owner` and `set_permissions` fields of every
request it sends.

It runs:

- as an Argo CD PostSync Job after each sync of `paperless`;
- nightly in `--nightly` mode (the `Retain until` recomputation, the
  correspondent and document permission passes).

Failure semantics. A failed PostSync hook marks the sync failed, and the
automatic rollback reverts the merge. That is intended for a configuration
error (the API answers `400` on a bad object): a broken configuration does
not stay on `main`. A transient error must not revert an unrelated merge,
so the Job first waits for `/api/` to answer (up to 10 minutes, with
backoff, which covers a Paperless restart from the same sync) and retries
`5xx` and connection errors three times before it fails. The nightly run
fails into `KubeJobFailed` like every Job.

It authenticates as the Paperless user `automation` with an API token in
the SOPS Secret `paperless-automation`, created once with `manage.py` and
sealed with `scripts/seal-secrets-from-env.sh`. The nightly passes change
private documents, and only a superuser sees every document regardless of
object permissions, so `automation` is a superuser: its token can read and
change every document, and it works on the public `/api/`.
`docs/secrets.md` records that reach, and `ci/secret-rotation.tsv` its
rotation. The alternative without a token is weighed in
[Known limits](#known-limits). Unit tests in `tests/` against a fake API, like the Keycloak realm
tests.

Rejected: configuring everything in the UI. It works, but the backup is the
only record and nothing reviews a change. Rejected: correspondents in git,
even SOPS-encrypted: the names would be in every clone's history, and they
change as letters arrive. Rejected: relying on the editor's "default
permissions" profile setting for correspondents; it depends on a UI
setting nothing checks.

## Access

Login stays as it is: Keycloak, groups `admins` and `family`. Inside
Paperless there are two roles:

| Who | Paperless account | Rights | Sees |
| --- | --- | --- | --- |
| Editor (the operator) | own Keycloak account, group `editors`, no superuser flag | view, add, change, delete documents and correspondents; view types, tags, custom fields, saved views | every document (owner of all) |
| Reader | own Keycloak account, group `readers` | view documents, correspondents, types, tags, custom fields, saved views | every document without `private` |
| Any other Keycloak login | created on first login, no group | none | nothing |
| `nedsi-admin` | local superuser, break-glass | all | everything; password in `paperless-secrets` |
| `automation` | superuser, API token only | all | everything (the nightly passes) |
| `canary` | no group; its own model permissions to add, view and delete documents | as listed | its own canary documents |

Neither group has rights on users, groups, workflows or settings. The
editor's day-to-day account is not a superuser, so a stolen editor session
reaches documents and correspondents only; administration goes through
`nedsi-admin`.

The 5 existing accounts predate the groups. Task 3 puts the editor's and
the reader's accounts into their groups from the list in `paperless-config`,
lists the superuser flag and direct model permissions of every account,
and clears both on every account other than `nedsi-admin`, `automation`
and `canary` (the editor's included), the same exemptions as `apply.py`'s
report. `automation` keeps its superuser flag, which the PostSync Job and
the nightly passes need, and `canary` (task 6) keeps its direct
permissions.
Before the flag goes, task 3 proves the break-glass path: `nedsi-admin`
reaches the admin with `PAPERLESS_REDIRECT_LOGIN_TO_SSO` set. If the
redirect hides the local login, the recovery is `python3 manage.py shell`
in the Paperless container (`kubectl exec` over the tailnet) to set the
flag back, and `docs/paperless.md` records it. The
other accounts keep no group and see nothing; deleting them is left to the
operator, since it cannot be undone.

Measured in task 3 (3.4.2): the redirect to Keycloak is the login page's
JavaScript, which `?loggedout=1` turns off, so `nedsi-admin` logs in with
the local form at `/accounts/login/?loggedout=1` and reaches `/admin/`;
`docs/paperless.md` records both that and the `manage.py shell` fallback.
Of the 4 accounts then, only `nedsi-admin` and `automation` had the
superuser flag and none had direct permissions, so nothing was cleared.
The editor's account had no permission at all, which is why it saw only an
empty dashboard and its profile: the web app needs at least
`view_uisettings`.

Group permissions (`groups` in `paperless.json`, upserted by `apply.py`
before the workflows that name them):

| Group | Model permissions |
| --- | --- |
| `editors` | view, add, change, delete: document, correspondent, note; view: document type, tag, custom field, saved view, global statistics; view and change: file tasks; view, add, change: UI settings |
| `readers` | view: document, correspondent, note, document type, tag, custom field, saved view; view, add, change: UI settings (each account's own dashboard choices) |

The member list names each account by Paperless username or by email,
matched case-insensitively, and never matches `nedsi-admin`, `automation`
or `canary`. The email is there because Paperless picks the username at
the first Keycloak login, and a listed person may not have logged in yet:
`apply.py` counts such an entry as not found, and the first run after the
login (the nightly one, or the next PostSync) adds the account. An entry
that matches two accounts fails the run. Paperless refuses a consumption
trigger without a file name, path or mail rule filter, so `share` filters
on the file name `*`.

Which saved views sit on the dashboard is a per-account UI setting
(`saved_views.dashboard_views_visible_ids`), which only the account's own
session can write through `/api/ui_settings/`; `apply.py` leaves it to each
person, and `docs/paperless.md` says where to set it.

What one editor removes. With every document owned by one account, the
document's owner can always see every type, tag and correspondent, so
matching never misses an object because of its owner. There is no second
owner whose correspondents the first cannot see: the web app and the
import script both upload as the editor. The remaining visibility question
is the reader's, and `owner: null` on the taxonomy plus the correspondent
pass answer it.

Group sync from Keycloak (`PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS`) is not
needed: Keycloak decides who logs in, and the member list in SOPS decides
the Paperless role.

The API is public at `archive.lilalala.com/api/`, because the web app runs
on it. Task 3 checks whether it also accepts the local admin password over
basic auth from the internet; if so, that is a new security issue, not
part of this spec.

## Import

The local import directory is `~/homelab-backups/paperless-import/`, one
subdirectory per source (whatever the operator adds: a Mac folder, a cloud
drive download, an external disk). The subdirectory name, which goes into
git and so must be generic (`mac`, `drive`), becomes the `import:<source>`
tag. Task 7 adds the tags of the
sources present then to `paperless.json`; a source added later gets its
tag in a one-line PR before its batch. `apply.py` creates them without an
owner, so the reader sees them and the editor needs no right to create
tags.

`scripts/paperless-import.py` (stdlib): walks one source subdirectory,
looks up `import:<source>` by name and stops before the first upload if it
is missing, uploads each file through `/api/documents/post_document/` with
the tag, as the editor (an API token of the editor's account, read from the
environment, created in the web UI for the batches of task 8 and deleted
after the last one), follows each consumption task to its result, and
writes a local report
(path, document id, created, duplicate, failed with reason). Folder names
do not become tags: they would add unreviewed tags owned by the editor,
which the reader cannot see and `apply.py` reports as unmanaged; the path
in the local report keeps the old structure. It prints counts only. Re-running
it is safe: the script skips content already in Paperless (below). Batches go
in during the day, a few hundred files at a time, so OCR does not starve the
node.

Measured on 3.4.2 in task 7: Paperless consumes a duplicate (it only logs
a warning) unless `PAPERLESS_CONSUMER_DELETE_DUPLICATES` is set, which this
deployment does not set. The script therefore skips a file itself when a
document with its SHA-256 (Paperless' checksum) already exists, through the
API filter `checksum__iexact`, or when the same content came earlier in the
run and went in; a task that still reports `duplicate_of` counts as a
duplicate too. It uploads one file at a time and waits for its task, and
`--limit N` stops after N uploads, so a batch is one run and the next run
skips what is in. The upload is never retried: a `5xx` or a timeout can
come after Paperless queued the file, so the file is reported failed and
the next run's checksum lookup decides. The import directory was still
empty when task 7 landed, so no `import:` tag exists yet; each source's
batch adds its tag to `paperless.json` first (#1093).

The script lands in its own task and PR. The batches run afterwards, and
one PR records the counts of every batch in `docs/paperless.md`.

## Backups, export and restore

| Job | When | What |
| --- | --- | --- |
| `paperless-backup` (changed) | 02:30 | Init container 1, paperless image, `paperless-data` read-write on the pod's node: Python's SQLite backup API (`sqlite3.connect(...).backup(...)`, SQLite 3.46.1 in the image) into an emptyDir at `/db/db.sqlite3`, then `PRAGMA integrity_check` on the copy. Init container 2, paperless image, reading the copy, never the live database: `PAPERLESS_DATA_DIR=/db` (the writable emptyDir, so the copy's `-shm` file and Paperless' log directory can be written), `PAPERLESS_CONSUMPTION_DIR=/db/consume` (empty), `paperless-media` read-only at `/media`; `document_exporter --skip-checks /export --use-filename-format --delete --no-progress-bar --passphrase "$PASSPHRASE"` into PVC `paperless-export` (`iscsi-retain`, 100Gi), then `export-meta.json` with the document count from the same `/db` copy. Main container, restic with read-only mounts: `/db` (tag `paperless-db`), `/media` (`paperless-media`), `/data` minus `db.sqlite3*`, index and thumbnails (`paperless-data`), and `/export` (`paperless-export`) |
| `restore-paperless` (new, `backup-verify`) | monthly | restore the latest `paperless-export` into a scratch volume and run, in one pod with no web server and no Celery worker or beat: `migrate` on an empty SQLite, `document_importer --passphrase`, a document count through `manage.py shell`; pass when imported = `manifest.json` = `export-meta.json` and one restored PDF opens; push the result like the other restore tests |

Why one Job. Init containers run in order and each must succeed before the
next starts, so restic only ever snapshots a finished export, however long
the export takes after an import batch or on its first run. A failed export
fails the Job, which pages through `KubeJobFailed` and shows on the backup
SLO. The three containers already share the node affinity and the volumes.
Rejected: a separate export CronJob before the backup; it races the backup
when the export runs long.

Why read-write. The live database is in WAL mode. A reader of a WAL
database needs write access to the `-shm` file, so the backup API on a
read-only mount either fails or reads without the WAL's recent pages. The
first init container mounts `paperless-data` read-write, which the RWO
volume allows on the same node, and SQLite's own locking then gives a
consistent copy while Paperless keeps writing.

Why the exporter reads the copy. The copy keeps WAL mode, so its reader
also needs a writable directory, which the emptyDir gives. The copy, the
export and the `export-meta.json` count then come from one point in time,
so an upload at 02:30 cannot make the restore test's
counts differ. Paperless' startup path check also wants a writable media
root, and `/media` stays read-only: the exporter runs with Django's
`--skip-checks`. Task 4 verifies on 3.4.1 that `document_exporter` accepts
`--skip-checks` and starts with these mounts; if not, the fallback is
`paperless-media` read-write in init container 2 (same node, RWO).
Measured on 3.4.2 in task 4: `--skip-checks` is accepted, but the exporter
holds `media.lock` in the media root for the whole export and fails with
`EROFS` on a read-only mount, so init container 2 mounts `paperless-media`
read-write and the export waits for the app's own file moves. Paperless
also refuses to load its settings without `PAPERLESS_SECRET_KEY`, so init
container 2 reads it from `paperless-secrets`. A new volume's root belongs
to root and Kyverno denies a root container in the Job, so the Deployment
mounts `paperless-export` at `/usr/src/paperless/export`, which the image's
root init chowns to uid 1000. One
edge remains: a row in the copy whose file is gone from `/media` by the
time the exporter reaches it. That happens when a document is purged from
the trash, or renamed on disk by `PAPERLESS_FILENAME_FORMAT` after an edit
of its title, correspondent, type or date, between the copy and the end of
the export. Only the canary purges at once, and its schedule avoids 02:00
to 04:00; an edit at that hour is rare. The Job sets `backoffLimit: 1`, so
it reruns once from a fresh copy; a second failure pages through
`KubeJobFailed`.

The counts. `export-meta.json`, `manifest.json` and the restore test's
import count all count the documents the exporter exports. Paperless' trash
is a soft delete, and the default document manager hides trashed
documents, so the count in `export-meta.json` uses that manager, the same
set the exporter walks. Task 5 checks on 3.4.1 that the exporter skips the
trash, and runs its check with a non-empty trash.
Measured in task 5 (3.4.2): the exporter does not skip the trash. With one
document in the trash, `manifest.json` held 3 documents, `export-meta.json`
2, and the import restored the trashed one as trashed (2 visible). The
restore test therefore counts the manifest's documents without
`deleted_at`, so all three counts leave the trash out.

Size. The export holds the same kinds of files as `paperless-media`
(originals, archived PDFs, thumbnails), so `paperless-export` gets the same
size, 100Gi on `iscsi-retain`, and grows with it; the PVC filling alerts
cover both. Rejected: running the copy
inside the live pod with `kubectl exec`, as `scripts/dump-databases.sh` does
from the Mac; it would give a CronJob `pods/exec` rights in the namespace.

The export passphrase is in the SOPS Secret `paperless-export` (key
`passphrase`), with a copy in `backup-verify` for the restore test, and no
other copy. It encrypts only the sensitive fields of `manifest.json` (the
social account tokens of the Keycloak logins): the documents and all other
metadata stay plain, so the export is readable without the passphrase.
Losing it loses only those fields in old exports, which a new Keycloak
login replaces.

The restore test runs no web server, worker or beat: it needs only
`migrate`, the importer and a count. If `document_importer` needs a
broker, task 5 adds a throwaway Valkey in the same pod, still with no
worker.
Measured in task 5 (3.4.2): Paperless' Django cache is Redis, so even
`migrate` fails without one; the CronJob `backup-verify-paperless` runs a
Valkey native sidecar on `127.0.0.1`, without persistence. The importer
rebuilds the search index and needs `index/` to exist in the data
directory. The scratch volume is an ephemeral `iscsi` claim of 200Gi (twice
`paperless-export`: the restored export plus the imported copy; the zvols
are sparse), deleted with the pod, so the CronJob keeps one Job of each
outcome.

The export is where "never locked in" comes from: `restic restore --tag
paperless-export` gives plain files and a JSON manifest without Paperless.
restic deduplicates the export against the originals in `/media`, so it
adds little to the bucket.

The export lives on iSCSI, not on an NFS share the Mac could browse,
because the NAS exports are open to the whole LAN today (#721) and the
export is every document in plain files. The flags are checked against
`document_exporter --help` of 3.4.1 in the task.

`restic-targets.txt` after task 4:

```
paperless-media|s3:paperless/media|paperless-media|
paperless-data|s3:paperless/media|paperless-data|/data/celerybeat-schedule.db
paperless-db|s3:paperless/media|paperless-db|/db/db.sqlite3
paperless-export|s3:paperless/media|paperless-export|/export/manifest.json
```

`paperless-data` drops `/data/db.sqlite3` (excluded now) for
`celerybeat-schedule.db`, which Paperless rewrites constantly.
`restic-data-targets.txt` already covers the repository. The schedule of
`paperless-backup` does not change, so `ci/active-cronjobs.txt` and
`backup-slo-targets.yaml` keep their entries.

## Findable within N minutes

The canary `paperless-canary` (every 6 hours at 01:00, 07:00, 13:00 and
19:00, clear of the 02:30 backup; paperless image, user `canary`): draws a
one-page image with a random 12-digit number in a large font (digits only,
so no look-alike letters such as `0/O` or `1/l/I`), converts it to PDF
(PIL and `img2pdf`, both in the image) so OCR has to read it, uploads it,
polls `/api/documents/?query=<number>` until found, records the seconds,
deletes the document and empties it from the trash, and pushes
`paperless_canary_success` and `paperless_canary_duration_seconds` to the
Pushgateway in `backup-verify`. Two alerts, each with a promtool test and a
runbook: `PaperlessIngestFailing` (no success for 13 hours) and
`PaperlessIngestSlow` (above 300 s twice in a row). Both `action: human`.

The canary uploads through the API as `canary`, with the API token in the
SOPS Secret `paperless-canary`, so it owns its page and can delete it. The
`share` workflow lets the readers see the page for the minutes it exists;
it is a generated page with a random number, so that is accepted.

The canary covers the API, the queue, OCR and the index: the path a web
upload takes once it leaves the browser. The 10-page number of
Requirement 7.1 is checked by hand in task 1.

The CiliumNetworkPolicy `paperless` gets the canary's egress to the
Pushgateway (`backup-verify`, TCP 9091), so the allow-list is complete when
egress enforcement is switched on. `backup-verify` has no policy, so there
is no ingress rule to add. The CronJob is listed in
`ci/active-cronjobs.txt`.

## Risks

- **The paperless image as uid 1000.** The new containers run the image's
  commands directly as uid 1000 instead of its root entrypoint, for the
  Kyverno baseline. The files are owned by uid 1000, so it should work;
  each task checks it, and a PolicyException is the fallback, as for the
  Deployment.
- **The read-write backup mount.** The first init container can write to
  the live database volume. It runs only the backup API (which writes
  nothing to the source beyond SQLite's lock state) and `integrity_check`
  on the copy. The export container reads the copy in the writable
  emptyDir and mounts only `paperless-media`, read-only; restic mounts
  everything read-only.
- **Backup window.** The export now runs inside the backup Job, so a long
  export delays the snapshot. The backup SLO's freshness window (24 h)
  absorbs it; a Job that runs past its `activeDeadlineSeconds` fails and
  pages.
- **OCR load.** Four languages make Tesseract slower per page than one,
  and the RK1 (8 arm64 cores) runs everything else too. Tesseract loads
  all four models for every page, and the Deployment sets no memory
  request or limit. Task 1 measures the OCR time and the container's peak
  memory for one page and for a 10-page file with `fra+eng+spa+deu`
  against `fra` alone, and sets a memory request from the result; the canary watches the
  5-minute limit; a bulk import runs in daytime batches. If pages run too
  slow, dropping the least used language is one line in git.

## Known limits

- **The `automation` token works on the public `/api/`.** A leaked token
  reads and changes every document from the internet. The alternative
  without a token is a Django script in a Job pod that mounts
  `paperless-data` read-write on the Paperless node, like init container 1.
  It is not taken for now: the script would write to the live SQLite
  database as a second process and depend on Paperless' internal models,
  which change between majors, while the REST API is versioned and
  `apply.py` is unit-tested against a fake of it. The PostSync Job also
  needs no node affinity with the token. The token lives only in SOPS, is
  rotated through `ci/secret-rotation.tsv`, and its reach is recorded in
  `docs/secrets.md` and `docs/threat-model.md`. Moving the nightly passes
  in-cluster is a new issue if the trade-off changes.
