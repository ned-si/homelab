# Design: paperless-documents

## Current state (read-only, 2026-11-03)

| What | Value |
| --- | --- |
| Image | `ghcr.io/paperless-ngx/paperless-ngx:3.4.1`, one replica, SQLite (journal mode `wal`), Valkey queue |
| URL, login | `archive.lilalala.com`, Keycloak only (`PAPERLESS_REDIRECT_LOGIN_TO_SSO`, auto signup), groups `admins` and `family` (`access.conf`, PR #468) |
| Volumes | `paperless-data` 4Gi (27M used), `paperless-media` 100Gi (1 MiB used), `paperless-consume` 10Gi (empty), all iSCSI |
| Content | 1 document, 0 correspondents, document types, tags, storage paths, workflows, mail accounts; 5 user accounts |
| OCR | `eng` only; the image ships `deu eng fra ita osd spa` |
| Time zone, dates | `UTC`, `DMY` |
| File names | default (`FILENAME_FORMAT` unset: numeric names) |
| Ways in | web upload only; no mail account, no scanner path, nothing writes to the consume volume |
| Backup | `paperless-backup` 02:30 to restic `paperless/media` (tags `paperless-media`, `paperless-data`), monthly `paperless-prune`; the restic image has no `sqlite3`, so the `paperless-db` branch never runs and `db.sqlite3` is copied live inside `paperless-data`, where it can be torn (#746) |
| Restore test | `backup-verify` weekly sample: `paperless-media`, `paperless-data` with `/data/db.sqlite3`; monthly pack read |
| Network | CiliumNetworkPolicy `paperless`: ingress from the Gateway, egress DNS, intra-namespace, TCP 443 to the world |

## Shape

```
editor's phone app ──editor's API token───────────────────────────────┐
editor's devices ──Syncthing folder──▶ NFS inbox ──polling────────────┤
scanner (if any) ──scan to mail──▶ mailbox ◀──IMAPS every 10 min──────┤
                                                                      ▼
                                  Paperless (consume, OCR fra+eng+deu, matching,
                                  workflows: owner = editor, view = readers, private)
                                                         │
             02:30 paperless-backup, one Job, in order:
                   1. consistent SQLite copy
                   2. document_exporter --passphrase ─▶ PVC paperless-export
                   3. restic: db + media + data + export ─▶ restic paperless/media
             monthly backup-verify ── restore paperless-export ─▶ throwaway Paperless (no worker), document_importer, counts
             every 6 h paperless-canary ── generated PDF ─▶ API ─▶ search ─▶ Pushgateway
reader ──Keycloak──▶ web UI or app, view only
```

## Ways in

Every way in belongs to the editor, and every document gets the same owner,
the editor: the `owner` workflow sets it for the consume folder and mail,
and API uploads use the editor's token. The reader files nothing.

### Phone

A Paperless client app with an API token. Users log in through Keycloak
and have no local password, so the token (web UI, My Profile, API token) is
the only credential the app holds; revoking it cuts off one phone. The
editor is not a superuser, so a stolen phone token cannot reach users,
groups or settings. The reader may use the same app with a token of the
reader's own account, which can only read. The first app in this table that
logs in with a token against 3.4.1 on the editor's phone is used (task 8):

| App | Platforms | Upload | Share sheet |
| --- | --- | --- | --- |
| Paperless Mobile | Android, iOS | camera scan, files | yes |
| Swift Paperless | iOS | camera scan, files | yes |
| PaperNext | Android, iOS | camera scan, files | check |
| QuickScan | iOS | scanner app with Paperless API upload | yes |

Task 8 records the choice and the setup in `docs/paperless.md`. A workflow
tags uploads through the API `source:phone`.

### Inbox folder

A TrueNAS dataset `homelab/k8s/nfs/paperless-inbox`, exported over NFS to
the four node addresses only (`192.168.1.247`, `.238`, `.239`, `.240`),
mounted by two static PersistentVolumes with `Retain`, as in
`infrastructure/nfs-storage/nfs-volumes.yaml`:

- in `syncthing`, at `/var/syncthing/paperless-inbox`;
- in `paperless`, at `/data/consume` (replacing the iSCSI
  `paperless-consume`, which stays `Retain` until a later issue releases
  it), with `PAPERLESS_CONSUMER_POLLING=30` (inotify does not see NFS
  changes).

The dataset is one Syncthing folder, shared with the editor's devices only.
It is defined in the Syncthing GUI and lives in its `config.xml` (backed up
as `syncthing-identity`). Both pods run as uid 1000 (Syncthing `PUID`,
Paperless `USERMAP_UID` default), so files keep one owner.

Paperless deletes a file once consumed, and Syncthing propagates the
deletion to the editor's devices. Each device keeps it in "trash can" file
versioning for 30 days; the cluster's side of the folder has no versioning.

Rejected: a second Syncthing inside the `paperless` namespace sharing the
iSCSI consume volume. It avoids NFS, but adds a device identity to pair on
every device and a second protocol address and port forward. Rejected: a
bridge Job that uploads from the Syncthing volume through the API; more
code for the same result.

### Mail

A dedicated mailbox (open question 2), never anyone's own. Paperless stores
its mail account in its database; the configuration Job creates it from the
SOPS Secret `paperless-mail` (host, port 993, user, app password, the
household sender addresses). One mail rule: filter "from" the household
addresses, attachments only (PDF and images), action "move to folder
`Processed`", tags `source:mail` and `inbox`. Mail from anyone else matches
no rule and stays unread. `PAPERLESS_EMAIL_TASK_CRON` keeps its default,
every 10 minutes.

The sender filter compares the `From` header, which a sender can forge.
Anyone who knows the address could then place a document in the archive and
feed a crafted PDF to Ghostscript and Tesseract. Mitigations:

- the address is never published: it lives only in SOPS and the
  household's address books;
- the provider honours DMARC on inbound mail, so a forged sender on a
  household domain that publishes `p=quarantine` or `p=reject` does not
  arrive. Domains with `p=none`, which large free-mail providers publish,
  get no protection from DMARC; the mail task's PR lists the policy of each
  household sender domain;
- every mail document carries `inbox` until the editor reviews it;
- the parsers run in the Paperless container: unprivileged, Kyverno
  baseline, egress limited by the CiliumNetworkPolicy.

The residual risk (a sender domain with `p=none`, a provider that accepts a
forged sender, a leaked address) gets a row in `docs/threat-model.md` in the
closing task.

The CiliumNetworkPolicy `paperless` gets one egress rule: TCP 993 to the
world (the provider's address is not stable enough for a CIDR).

### Scanner

None is assumed: the phone app is the scanner, and task 10 becomes a
`deferred` issue. A scanner that turns up uses scan to mail through the
mailbox, through a second mail rule `scanner` filtered on the scanner's
sender address and a workflow on that rule that tags `source:scan`. The owner comes from the `owner` workflow, as for all
mail. Scan to an SMB folder is left out: it needs an SMB share and a
NAS user for one device.

## Settings

Environment changes in `apps/paperless/deployment.yaml`:

| Variable | Value | Why | Task |
| --- | --- | --- | --- |
| `PAPERLESS_OCR_LANGUAGE` | `fra+eng+deu` | the household's languages; all three are in the image, so `PAPERLESS_OCR_LANGUAGES` stays unset | 2 |
| `PAPERLESS_TIME_ZONE` | `Europe/Zurich` | creation dates near midnight land on the right day | 2 |
| `PAPERLESS_DATE_ORDER` | `DMY` | explicit (today's default) | 2 |
| `PAPERLESS_FILENAME_FORMAT` | `{{ created_year }}/{{ document_type }}/{{ created }} {{ correspondent }} {{ title }}` | readable files in the media volume and the export | 2 |
| `PAPERLESS_CONSUMER_POLLING` | `30` | NFS inbox | 7 |

`PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS` stays unset: a new Keycloak login
gets no group, and the configuration Job puts listed accounts into their
group ([Access](#access)).

Setting the file name format renames existing files on disk. With one
document today that is free, and restic stores renamed files without new
data, which is why it comes before the import.

## Taxonomy proposal

**This is a proposal for the operator to adjust** (open question 1). Names
are in English; the matching keywords cover French, German and English.

### Matching rules for the keywords

- Algorithm `Any`, case-insensitive. Paperless splits the match string on
  spaces and matches whole words, so a phrase is written in double quotes:
  `"ticket de caisse"`, never `ticket de caisse` (which would match every
  French document through `de`).
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
    whose footer says `invoice`). The test runs Paperless' `Any` rule (whole
    words, case-insensitive, quoted phrases) over each text and fails when a
    text matches zero types or more than one. The texts are invented: no
    real document content.

### Document types and retention

| Type | Matching (`Any`, case-insensitive) | Retain |
| --- | --- | --- |
| Invoice | `"numéro de facture" Rechnungsnummer "invoice number" "invoice no"` | 5 years |
| Receipt | `quittance "ticket de caisse" Quittung Kassenbon receipt` | 2 years |
| Statement | `"relevé de compte" "extrait de compte" Kontoauszug "bank statement"` | 10 years |
| Tax | `"déclaration d'impôt" "décision de taxation" Steuererklärung Veranlagungsverfügung "tax return"` | 10 years |
| Payslip | `"fiche de salaire" "décompte de salaire" "certificat de salaire" Lohnabrechnung Lohnausweis payslip` | forever |
| Insurance | `"police d'assurance" "attestation d'assurance" Versicherungspolice Versicherungsnachweis "insurance policy"` | forever |
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
script sets `Retain until` = creation date + the type's period on documents
that have a type and no date, and the saved view "Retention expired" lists
the documents past it. Deleting stays a person's decision; deleted
documents stay in the trash for 30 days (`EMPTY_TRASH_DELAY`).

### Tags

| Group | Tags |
| --- | --- |
| Area | `housing`, `car`, `health`, `finance`, `insurance`, `work`, `utilities`, `telecom`, `travel`, `family` |
| State | `inbox` (Paperless' inbox tag, removed after review), `to-pay`, `tax-relevant`, `private` |
| Source | `source:phone`, `source:folder`, `source:mail`, `source:scan`, `source:import`, `import:<source>` |

Area tags match on keywords under the same rules (for example `utilities`:
`électricité Strom electricity "eau potable" Wasserversorgung`); `to-pay`
matches a Swiss QR-bill with a `Regex`
(`Zahlteil|Section paiement|Payment part|Sezione pagamento`);
`tax-relevant` is added by a workflow to the types Tax, Statement, Payslip
and Insurance. `private` never matches: the editor sets it. The
`import:<source>` and folder-name tags of the import are created by the
import script (see [Import](#import)).

### Custom fields

`Retain until` (date), `Amount` (monetary, CHF), `Due date` (date),
`Tax year` (integer).

### Storage paths: none

The proposal uses no storage paths. The global `PAPERLESS_FILENAME_FORMAT`
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
dashboard.

## Matching and workflows

Explicit matching first (`Any` keywords, `Regex` for the QR-bill), because
the automatic classifier needs training data the archive does not have. A
type or tag moves to `Auto` in git once 20 documents carry it.

Workflows run in the order of their `order` field; `private` is last, so
nothing after it gives the view back.

| Order | Workflow | Trigger, filter | Actions |
| --- | --- | --- | --- |
| 10 | owner | Consumption started, consume folder and mail fetch | owner = the editor; view for group `readers` |
| 15 | share-api | Consumption started, API upload | view for group `readers` (the owner stays the uploader) |
| 20 | source-folder | Consumption started, consume folder | tag `source:folder` |
| 30 | source-mail | Consumption started, mail rule | tags `source:mail`, `inbox` |
| 40 | source-phone | Consumption started, API upload | tag `source:phone` |
| 50 | source-scan | Consumption started, the mail rule `scanner` (only with a scanner) | tag `source:scan` |
| 60 | tax-relevant | Document added, type Tax, Statement, Payslip or Insurance | tag `tax-relevant` |
| 90 | private | Document added and Document updated, has tag `private` | remove view and change for group `readers` |

The `private` workflow fires on every edit of a private document, so
setting the tag at any time hides the document from the readers. Removing
the tag does not give the view back by itself: the nightly configuration
run reconciles the readers' view on every document (view for `readers` if
and only if the document has no `private` tag), so a document made public
again is readable the next morning, or at once through the document's
permissions dialog. The workflow that carries the editor's username comes
from the SOPS part of the configuration
([Configuration as code](#configuration-as-code)).

## Configuration as code

Git owns the document types, tags, custom fields, storage paths (none
today), saved views and workflows. The editor changes documents and
correspondents; both groups have view rights on the rest and no change
rights, so a sync never reverts an edit made in the UI. A new tag or a
better keyword is an issue or a PR, which an agent can do.

`apps/paperless/config/paperless.json`: the objects above, with the
workflows that carry no personal data. The SOPS Secret `paperless-config`
holds the personal part (the editor's and the reader's usernames, the
household sender addresses) as one key, `config.json`, whose single
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
- grants view for `readers` on every correspondent that lacks it, without
  reading or changing names (a permissions-only pass, so names stay out of
  git and out of the Job's log);
- in the nightly run, reconciles the `readers` view on documents with the
  `private` tag, as described in [Matching and workflows](#matching-and-workflows).

Its unit tests assert the `owner` and `set_permissions` fields of every
request it sends.

It runs:

- as an Argo CD PostSync Job after each sync of `paperless`;
- nightly in `--nightly` mode (the `Retain until` dates, the correspondent
  and document permission passes).

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
rotation. Unit tests in `tests/` against a fake API, like the Keycloak realm
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
| Editor (the operator) | own Keycloak account, group `editors`, no superuser flag | view, add, change, delete documents and correspondents; view types, tags, custom fields, saved views, mail rules | every document (owner of all) |
| Reader | own Keycloak account, group `readers` | view documents, correspondents, types, tags, custom fields, saved views | every document without `private` |
| Any other Keycloak login | created on first login, no group | none | nothing |
| `nedsi-admin` | local superuser, break-glass | all | everything; password in `paperless-secrets` |
| `automation` | superuser, API token only | all | everything (the nightly passes) |
| `canary` | no group; its own model permissions to add, view and delete documents | as listed | its own canary documents |

Neither group has rights on users, groups, workflows, mail accounts or
settings. The editor's day-to-day account is not a superuser, so a lost
phone token reaches documents and correspondents only; administration goes
through `nedsi-admin`.

The 5 existing accounts predate the groups. Task 4 puts the editor's and
the reader's accounts into their groups from the list in `paperless-config`
and removes the superuser flag from the editor's account if it is set. The
other accounts keep no group and see nothing; deleting them is left to the
operator, since it cannot be undone.

What one editor removes. With every document owned by one account, the
document's owner can always see every type, tag and correspondent, so
matching never misses an object because of its owner. There is no second
owner whose correspondents the first cannot see, and the scanner needs no
owner of its own: the consume folder and mail get the editor from the
`owner` workflow, and API uploads (the phone, the import script) use the
editor's token. The remaining
visibility question is the reader's, and `owner: null` on the taxonomy plus
the correspondent pass answer it.

Group sync from Keycloak (`PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS`) is not
needed: Keycloak decides who logs in, and the member list in SOPS decides
the Paperless role.

The API is public at `archive.lilalala.com/api/` and accepts tokens without
Keycloak; that is what the phone apps need. Task 8 (phone and API) checks
whether it also accepts the local admin password over basic auth from the
internet; if so, that is a new security issue, not part of this spec.

## Import

### Seafile archive (deadline: before 2026-11-17)

`docs/backups.md` lists `seafile/shared` at 0.7 MiB, so the archive is
probably close to empty. Task 1 starts with the cheap step and stops early
if there is nothing to export.

1. A scratch namespace with the verifier credentials and a scratch iSCSI
   volume, as in [How to restore](../../../docs/backups.md#how-to-restore)
   (a live write: the task's brief allows it).
2. Inventory: `restic ls -l 8838dac0` (block count and bytes per library
   directory) and `restic restore 34f34ea0` (the MariaDB dump), then read
   the `RepoFileCount` and `RepoSize` rows from the dump text. No MariaDB
   needed. The counts go into the pull request.
3. If no library holds files: record that, delete the scratch objects, done.
4. Otherwise `restic restore 8838dac0` (data and `seafile/conf/`) and one
   pod: `mariadb:10.11` loading the dump, and the Seafile 11 server image
   with the restored `conf/` running `seaf-fsck.sh --export /export`, which
   writes every library as plain files. File count, total size and count per
   extension go into the pull request; the list of names only to the
   operator.
5. Copy the export to the operator's Mac under
   `~/homelab-backups/paperless-import/seafile/` (outside git), then delete
   the scratch namespace and volume.

This also proves the restic copy restores, which is what is left once the
zvols go. If the Seafile tools cannot run on the restored data, the
fallback is a read-only pod on the two zvols themselves, which is why the
task targets Friday 2026-11-13 and keeps Monday 2026-11-16 as a buffer. If
neither works by then, the pull request extends the zvol retention date in
`docs/decisions.md` instead. Otherwise it updates "Seafile removed" there
with the outcome.

### Other sources and the import script

The local import directory is `~/homelab-backups/paperless-import/`, one
subdirectory per source (`seafile/` from task 1, then whatever the operator
adds: a Mac folder, a cloud drive download, scanned boxes). The subdirectory
name becomes the `import:<source>` tag.

`scripts/paperless-import.py` (stdlib): walks one source subdirectory,
uploads each file through `/api/documents/post_document/` with the editor's
token, tags `source:import`, `import:<source>` and one tag per folder name,
follows each consumption task to its result, and writes a local report
(created, duplicate, failed with reason). It prints counts only. Re-running
it is safe: Paperless refuses duplicates by checksum. Batches go in during
the day, a few hundred files at a time, so OCR does not starve the node.

The script lands in its own task and PR. The batches run afterwards, and
one PR records the counts of every batch in `docs/paperless.md`.

## Backups, export and restore

| Job | When | What |
| --- | --- | --- |
| `paperless-backup` (changed) | 02:30 | Init container 1, paperless image, `paperless-data` read-write on the pod's node: Python's SQLite backup API (`sqlite3.connect(...).backup(...)`, SQLite 3.46.1 in the image) into an emptyDir at `/db/db.sqlite3`, then `PRAGMA integrity_check` on the copy. Init container 2, paperless image: `document_exporter /export --use-filename-format --delete --no-progress-bar --passphrase "$PASSPHRASE"` into PVC `paperless-export` (`iscsi-retain`), then `export-meta.json` with the live document count. Main container, restic with read-only mounts: `/db` (tag `paperless-db`), `/media` (`paperless-media`), `/data` minus `db.sqlite3*`, index and thumbnails (`paperless-data`), and `/export` (`paperless-export`) |
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
consistent copy while Paperless keeps writing. Rejected: running the copy
inside the live pod with `kubectl exec`, as `scripts/dump-databases.sh` does
from the Mac; it would give a CronJob `pods/exec` rights in the namespace.

The export passphrase is in the SOPS Secret `paperless-export` (key
`passphrase`), with a copy in `backup-verify` for the restore test, and no
other copy. It encrypts only the sensitive fields of `manifest.json` (the
mail account password, social account tokens): the documents and all other
metadata stay plain, so the export is readable without the passphrase.
Losing it loses only the mail credential in old exports, which a new app
password replaces.

The restore test runs no worker and no beat, so the imported mail account
is never polled. The `backup-verify` CiliumNetworkPolicy gets no TCP 993
egress either. If `document_importer` needs a broker, task 6 adds a
throwaway Valkey in the same pod, still with no worker.

The export is where "never locked in" comes from: `restic restore --tag
paperless-export` gives plain files and a JSON manifest without Paperless.
restic deduplicates the export against the originals in `/media`, so it
adds little to the bucket.

The export lives on iSCSI, not on an NFS share the Mac could browse,
because the NAS exports are open to the whole LAN today (#721) and the
export is every document in plain files. The flags are checked against
`document_exporter --help` of 3.4.1 in the task.

`restic-targets.txt` after task 5:

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

`apps/paperless/backup.yaml` is also being changed by #953 (read-only root
filesystem); task 5 starts after it merges.

## Findable within N minutes

The canary `paperless-canary` (every 6 hours, paperless image, user
`canary`): draws a one-page image with a random token, converts it to PDF
(PIL and `img2pdf`, both in the image) so OCR has to read it, uploads it,
polls `/api/documents/?query=<token>` until found, records the seconds,
deletes the document and empties it from the trash, and pushes
`paperless_canary_success` and `paperless_canary_duration_seconds` to the
Pushgateway in `backup-verify`. Two alerts, each with a promtool test and a
runbook: `PaperlessIngestFailing` (no success for 13 hours) and
`PaperlessIngestSlow` (above 300 s twice in a row). Both `action: human`.

The canary uploads through the API as `canary`, so it owns its page and can
delete it: the `owner` workflow only acts on the consume folder and mail.
`share-api` lets the readers see the page for the minutes it exists; it is
a generated page with a random token, so that is accepted.

The canary covers API, queue, OCR and index. The transport legs (Syncthing,
mail polling) are tested by hand once in their tasks; the 10-page and mail
numbers of Requirement 10 are checked there too.

The CiliumNetworkPolicies get the canary's egress to the Pushgateway
(`backup-verify`, TCP 9091) and its ingress there.

## Risks

- **The paperless image as uid 1000.** The new containers run the image's
  commands directly as uid 1000 instead of its root entrypoint, for the
  Kyverno baseline. The files are owned by uid 1000, so it should work;
  each task checks it, and a PolicyException is the fallback, as for the
  Deployment.
- **The read-write backup mount.** The first init container can write to
  the live database volume. It runs only the backup API (which writes
  nothing to the source beyond SQLite's lock state) and `integrity_check`
  on the copy; the export container and restic keep read-only mounts of
  `paperless-data` and `paperless-media`.
- **Backup window.** The export now runs inside the backup Job, so a long
  export delays the snapshot. The backup SLO's freshness window (24 h)
  absorbs it; a Job that runs past its `activeDeadlineSeconds` fails and
  pages.
- **OCR load.** Three languages slow OCR. The RK1 has 8 cores; a bulk
  import runs in daytime batches and the canary shows the effect.
- **NFS.** The inbox depends on the NAS like the media library; a NAS
  outage already pages (`HomelabNASUnreachable`, `HomelabNASDown`).
- **Forged mail.** See [Mail](#mail); the residual risk is in
  `docs/threat-model.md`.
