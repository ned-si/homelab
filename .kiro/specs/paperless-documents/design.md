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
phone app ──member's API token────────────────────────────────────────┐
member A's devices ──Syncthing folder of A──▶ NFS inbox  A/ ─┐        │
member B's devices ──Syncthing folder of B──▶ NFS inbox  B/ ─┼polling─┤
scanner ──scan to mail──▶ mailbox ◀──IMAPS every 10 min──────┼────────┤
                                                             ▼        ▼
                                                Paperless (consume, OCR fra+deu+eng,
                                                matching, workflows: owner, source, sharing)
                                                         │
             02:00 paperless-export ─────────────────────┤ document_exporter --passphrase ─▶ PVC paperless-export
             02:30 paperless-backup ── consistent SQLite copy + media + data + export ─▶ restic paperless/media
             monthly backup-verify ── restore paperless-export ─▶ throwaway Paperless (no worker), document_importer, counts
             every 6 h paperless-canary ── generated PDF ─▶ API ─▶ search ─▶ Pushgateway
```

## Ways in

### Phone

A Paperless client app with a per-member API token. Members log in through
Keycloak and have no local password, so the token (web UI, My Profile, API
token) is the only credential the app holds; revoking it cuts off one phone.
Candidates, chosen in task 8 with open question 6:

| App | Platforms | Upload | Share sheet |
| --- | --- | --- | --- |
| Paperless Mobile | Android, iOS | camera scan, files | yes |
| Swift Paperless | iOS | camera scan, files | yes |
| PaperNext | Android, iOS | camera scan, files | check |
| QuickScan | iOS | scanner app with Paperless API upload | yes |

The task checks that the chosen app logs in with a token against 3.4.1,
then records the choice and the setup in `docs/paperless.md`. A workflow
tags uploads through the API `source:phone`; the owner is the token's user.

### Inbox folders

A TrueNAS dataset `homelab/k8s/nfs/paperless-inbox`, exported over NFS to
the four node addresses only (`192.168.1.247`, `.238`, `.239`, `.240`),
mounted by two static PersistentVolumes with `Retain`, as in
`infrastructure/nfs-storage/nfs-volumes.yaml`:

- in `syncthing`, at `/var/syncthing/paperless-inbox`;
- in `paperless`, at `/data/consume` (replacing the iSCSI
  `paperless-consume`, which stays `Retain` until a later issue releases
  it), with `PAPERLESS_CONSUMER_POLLING=30` (inotify does not see NFS
  changes) and `PAPERLESS_CONSUMER_RECURSIVE=true`.

Layout: one subdirectory `<member>/` per member. Syncthing replicates a
whole folder to every device it is shared with, so each subdirectory is its
own Syncthing folder (`/var/syncthing/paperless-inbox/<member>`), shared
only with that member's devices. A file member A drops never reaches member
B's devices, not even as a version. The folders are defined in the
Syncthing GUI and live in its `config.xml` (backed up as
`syncthing-identity`), so no member name is in git.

Both pods run as uid 1000 (Syncthing `PUID`, Paperless `USERMAP_UID`
default), so files keep one owner. A workflow per member (trigger
"Consumption started", source "Consume folder", path filter
`*/<member>/*`) sets the owner and tags `source:folder`. The member names
are personal data: the workflows that carry them come from the SOPS part of
the configuration ([Configuration as code](#configuration-as-code)).

Paperless deletes a file once consumed, and Syncthing propagates the
deletion to that member's devices. Each of the member's devices keeps it in
"trash can" file versioning for 30 days (open question 10); the cluster's
side of the folder has no versioning.

Rejected: one Syncthing folder for the whole inbox with per-member
subdirectories. It is one share to set up instead of one per member, but it
copies every member's documents, private ones included, to every member's
devices and keeps them 30 days in versioning. Rejected: a second Syncthing
inside the `paperless` namespace sharing the iSCSI consume volume. It avoids
NFS, but adds a device identity to pair on every device and a second
protocol address and port forward. Rejected: a bridge Job that uploads from
the Syncthing volume through the API; more code for the same result.

### Mail

A dedicated mailbox (open question 4), never a member's own. Paperless
stores its mail account in its database; the configuration Job creates it
from the SOPS Secret `paperless-mail` (host, port 993, user, app password,
the household sender addresses). One mail rule per member: filter "from"
the member's addresses, attachments only (PDF and images), action "move to
folder `Processed`", owner set by a workflow filtered on that rule, tags
`source:mail` and `inbox`. Mail from anyone else matches no rule and stays
unread. `PAPERLESS_EMAIL_TASK_CRON` keeps its default, every 10 minutes.

The sender filter compares the `From` header, which a sender can forge.
Anyone who knows the address could then place a document in a member's
archive and feed a crafted PDF to Ghostscript and Tesseract. Mitigations:

- the address is never published: it lives only in SOPS and the members'
  address books;
- the provider rejects inbound mail that fails DMARC alignment, so a forged
  household sender on a domain with a `p=reject` policy does not arrive
  (a selection criterion for open question 4);
- every mail document carries `inbox` until a member reviews it;
- the parsers run in the Paperless container: unprivileged, Kyverno
  baseline, egress limited by the CiliumNetworkPolicy.

The residual risk (a provider that accepts a forged sender, a leaked
address) gets a row in `docs/threat-model.md` in the closing task.

The CiliumNetworkPolicy `paperless` gets one egress rule: TCP 993 to the
world (the provider's address is not stable enough for a CIDR).

### Scanner

Only if there is one (open question 5). Scan to mail uses the mailbox with
the scanner's sender address in a rule tagged `source:scan`. Scan to a
network folder uses an SMB share of the inbox dataset, limited to the
scanner's address and its own TrueNAS user, writing to `scanner/`. With no
scanner, the phone app is the scanner and this part becomes a `deferred`
issue.

## Settings

Environment changes in `apps/paperless/deployment.yaml`:

| Variable | Value | Why | Task |
| --- | --- | --- | --- |
| `PAPERLESS_OCR_LANGUAGE` | `fra+deu+eng` (order from open question 3) | the household's languages; all three are in the image, so `PAPERLESS_OCR_LANGUAGES` stays unset | 2 |
| `PAPERLESS_TIME_ZONE` | `Europe/Zurich` | creation dates near midnight land on the right day | 2 |
| `PAPERLESS_DATE_ORDER` | `DMY` | explicit (today's default) | 2 |
| `PAPERLESS_FILENAME_FORMAT` | `{{ owner_username }}/{{ created_year }}/{{ document_type }}/{{ created }} {{ correspondent }} {{ title }}` | readable files in the media volume and the export | 2 |
| `PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS` | `household` | first login lands in the household group; set once the group exists | 4 |
| `PAPERLESS_CONSUMER_POLLING` | `30` | NFS inbox | 7 |
| `PAPERLESS_CONSUMER_RECURSIVE` | `true` | per-member subdirectories | 7 |

Setting the file name format renames existing files on disk. With one
document today that is free, and restic stores renamed files without new
data, which is why it comes before the import.

## Taxonomy proposal

**This is a proposal for the operator to adjust** (open questions 1 and 2).
Names are in English; the matching keywords cover French, German and
English.

### Matching rules for the keywords

- Algorithm `Any`, case-insensitive. Paperless splits the match string on
  spaces and matches whole words, so a phrase is written in double quotes:
  `"ticket de caisse"`, never `ticket de caisse` (which would match every
  French document through `de`).
- A document type gets only specific keywords. Generic words (`statement`,
  `policy`, `manual`, `attestation`, `contrat`, `certificat`) are left out:
  they appear in letters of every type.
- No keyword belongs to two document types. When several types match,
  Paperless keeps the first by name, so an overlap would make the result
  depend on spelling. The unit tests of `apply.py` fail on an unquoted
  phrase in an `Any` rule and on a keyword shared by two types.

### Document types and retention

| Type | Matching (`Any`, case-insensitive) | Retain |
| --- | --- | --- |
| Invoice | `facture Rechnung invoice` | 5 years |
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

"Forever" means no `Retain until` date. A nightly run of the configuration
script sets `Retain until` = creation date + the type's period on documents
that have a type and no date, and the saved view "Retention expired" lists
the documents past it. Deleting stays a person's decision; deleted
documents stay in the trash for 30 days (`EMPTY_TRASH_DELAY`).

### Tags

| Group | Tags |
| --- | --- |
| Area | `housing`, `car`, `health`, `finance`, `insurance`, `work`, `utilities`, `telecom`, `travel`, `family` |
| State | `inbox` (Paperless' inbox tag, removed after review), `to-pay`, `tax-relevant` |
| Source | `source:phone`, `source:folder`, `source:mail`, `source:scan`, `source:import`, `import:<source>` |

Area tags match on keywords under the same rules (for example `utilities`:
`électricité Strom electricity "eau potable" Wasserversorgung`); `to-pay`
matches a Swiss QR-bill with a `Regex`
(`Zahlteil|Section paiement|Payment part|Sezione pagamento`);
`tax-relevant` is added by a workflow to the types Tax, Statement, Payslip
and Insurance. The `import:<source>` and folder-name tags of the import are
created by the import script, not by members (see [Import](#import)).

### Custom fields

`Retain until` (date), `Amount` (monetary, CHF), `Due date` (date),
`Tax year` (integer).

### Storage paths: none

The proposal uses no storage paths. The global `PAPERLESS_FILENAME_FORMAT`
already gives one tree per owner, year and document type, which is the
layout the export and a reader without Paperless need. A storage path would
override that per document, and matching would have to choose it right
every time; a wrong choice only moves files, but it makes the tree harder
to read. If a type needs a different layout (open question 1), a storage
path for that type is added in git like the other objects.

### Correspondents

Kept in Paperless only, never in git: they are real names. Examples of the
kind: a bank, the health insurer, the cantonal tax office, the landlord, a
utility, a payroll office. Members create them and set their match text
(name, IBAN, UID number) in the UI.

### Saved views

Inbox (`inbox`), To pay (`to-pay`, by `Due date`), Tax year (`tax-relevant`,
by `Tax year`), Retention expired (`Retain until` before today), Recently
added. Owned by `automation`, shared with the group `household`, shown on
its dashboard.

## Matching and workflows

Explicit matching first (`Any` keywords, `Regex` for the QR-bill), because
the automatic classifier needs training data the archive does not have. A
type or tag moves to `Auto` in git once 20 documents carry it.

| Workflow | Trigger, filter | Actions |
| --- | --- | --- |
| owner-folder-`<member>` | Consumption started, consume folder, path `*/<member>/*` | owner `<member>`, tag `source:folder` |
| owner-mail-`<member>` | Consumption started, mail rule of `<member>` | owner `<member>`, tags `source:mail`, `inbox` |
| source-phone | Consumption started, API upload | tag `source:phone` |
| share-household | Document added | view and change for group `household` |
| private-types | Document added, type Medical or Payslip | remove the `household` permissions |
| tax-relevant | Document added, type Tax, Statement, Payslip or Insurance | tag `tax-relevant` |

`share-household` and `private-types` follow open question 8.

## Configuration as code

Git owns the document types, tags, custom fields, storage paths (none
today), saved views and workflows. Members change documents and
correspondents only; the group `household` has view rights on the rest and
no change rights, so a sync never reverts a member's edit. A new tag or a
better keyword is an issue or a PR (an agent can do it). The alternative,
an apply script that only creates, is open question 2.

`apps/paperless/config/paperless.json`: the objects above, with the
workflows that carry no personal data. The SOPS Secret `paperless-config`
holds the personal part (members, their inbox subdirectories, their sender
addresses) as one key, `config.json`, whose single encrypted value is a
JSON document. SOPS here encrypts values and leaves keys readable, so no
member name is ever a key.

`apps/paperless/config/apply.py` (Python stdlib, `urllib` and `json`) reads
both and upserts through the API by name: it creates what is missing and
updates what differs. It deletes nothing: an object that is in Paperless
but not in the configuration is reported, and a person removes it, because
removing a tag or type strips it from every document. It never touches
correspondents. It runs:

- as an Argo CD PostSync Job after each sync of `paperless`;
- nightly in `--retention` mode (the `Retain until` dates).

Failure semantics. A failed PostSync hook marks the sync failed, and the
automatic rollback reverts the merge. That is intended for a configuration
error (the API answers `400` on a bad object): a broken configuration does
not stay on `main`. A transient error must not revert an unrelated merge,
so the Job first waits for `/api/` to answer (up to 10 minutes, with
backoff, which covers a Paperless restart from the same sync) and retries
`5xx` and connection errors three times before it fails. The nightly
`--retention` run fails into `KubeJobFailed` like every Job.

It authenticates as the Paperless user `automation` with an API token in
the SOPS Secret `paperless-automation`, created once with `manage.py` and
sealed with `scripts/seal-secrets-from-env.sh`. Mail accounts, mail rules
and workflows are model permissions a normal user can hold; what needs
superuser is the `--retention` pass, which sets a custom field on every
document, private ones included, and object permissions would hide those
from a normal user. So the token can read and change every document, and
it works on the public `/api/`. `docs/secrets.md` records that reach, and
`ci/secret-rotation.tsv` its rotation. Unit tests in `tests/` against a
fake API, like the Keycloak realm tests.

Rejected: configuring everything in the UI. It works, but the backup is the
only record and nothing reviews a change. Rejected: correspondents in git,
even SOPS-encrypted: the names would be in every clone's history, and they
change as letters arrive.

## Access

Login stays as it is: Keycloak, groups `admins` and `family`. Inside
Paperless:

| Who | Paperless account | Sees |
| --- | --- | --- |
| A member (Keycloak `family` or `admins`) | created on first login, group `household` (rights in Requirement 9.2) | own documents, documents shared with `household` |
| The operator | the operator's own member account, with the superuser flag set by hand | everything |
| `nedsi-admin` | local superuser, break-glass | everything; password in `paperless-secrets` |
| `automation` | superuser, API token only | everything (the `--retention` pass) |
| `canary` | no group, API token only | its own canary documents |

The 5 existing accounts predate the group: task 4 adds the member accounts
among them to `household` (from the member list in `paperless-config`)
before it sets `PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS`, which only acts at
signup.

Group sync from Keycloak (`PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS`) is not
needed: Keycloak already decides who logs in, and one Paperless group
covers the household.

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
5. Copy the export to the operator's Mac under `~/homelab-backups/` (outside
   git) for the selection, then delete the scratch namespace and volume.

This also proves the restic copy restores, which is what is left once the
zvols go. If the Seafile tools cannot run on the restored data, the
fallback is a read-only pod on the two zvols themselves, which is why the
task targets Friday 2026-11-13 and keeps Monday 2026-11-16 as a buffer. The
pull request updates "Seafile removed" in `docs/decisions.md` with the
outcome.

### Other sources and the import script

`scripts/paperless-import.py` (stdlib): walks a local directory, uploads
each file through `/api/documents/post_document/` with the token of the
member who owns the batch, tags `source:import`, `import:<source>` and one
tag per folder name, follows each consumption task to its result, and
writes a local report (created, duplicate, failed with reason). It prints
counts only. Re-running it is safe: Paperless refuses duplicates by
checksum. Batches go in during the day, a few hundred files at a time, so
OCR does not starve the node.

The script lands in its own task and PR. The batches run afterwards, and
one PR records the counts of every batch in `docs/paperless.md`; it opens
when the operator's selection is imported.

## Backups, export and restore

| Job | When | What |
| --- | --- | --- |
| `paperless-export` (new) | 02:00 | paperless image, co-scheduled with the pod (RWO volumes), `document_exporter /export --use-filename-format --delete --no-progress-bar --passphrase "$PASSPHRASE"` into PVC `paperless-export` (`iscsi-retain`), then `export-meta.json` with the live document count |
| `paperless-backup` (changed) | 02:30 | init container with the paperless image, `paperless-data` mounted read-write on the pod's node: Python's SQLite backup API (`sqlite3.connect(...).backup(...)`, SQLite 3.46.1 in the image) into an emptyDir at `/db/db.sqlite3`, then `PRAGMA integrity_check` on the copy; then restic with read-only mounts: `/db` (tag `paperless-db`), `/media` (`paperless-media`), `/data` minus `db.sqlite3*`, index and thumbnails (`paperless-data`), and `/export` (`paperless-export`) |
| `restore-paperless` (new, `backup-verify`) | monthly | restore the latest `paperless-export` into a scratch volume and run, in one pod with no web server and no Celery worker or beat: `migrate` on an empty SQLite, `document_importer --passphrase`, a document count through `manage.py shell`; pass when imported = `manifest.json` = `export-meta.json` and one restored PDF opens; push the result like the other restore tests |

Why read-write. The live database is in WAL mode. A reader of a WAL
database needs write access to the `-shm` file, so the backup API on a
read-only mount either fails or reads without the WAL's recent pages. The
init container mounts `paperless-data` read-write, which the RWO volume
allows on the same node, and SQLite's own locking then gives a consistent
copy while Paperless keeps writing. Rejected: running the copy inside the
live pod with `kubectl exec`, as `scripts/dump-databases.sh` does from the
Mac; it would give a CronJob `pods/exec` rights in the namespace.

The export passphrase is in the SOPS Secret `paperless-export` (key
`passphrase`), with a copy in `backup-verify` for the restore test. It
encrypts only the sensitive fields of `manifest.json` (the mail account
password, social account tokens): the documents and all other metadata stay
plain, so the export is readable without the passphrase. Losing it loses
only the mail credential in old exports, which a new app password replaces.

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
`restic-data-targets.txt` already covers the repository. The new CronJobs
go into `ci/active-cronjobs.txt` and, for the backup,
`backup-slo-targets.yaml`.

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

The canary covers API, queue, OCR and index. The transport legs (Syncthing,
mail polling) are tested by hand once in their tasks; the 10-page and mail
numbers of Requirement 10 are checked there too.

The CiliumNetworkPolicies get the canary's egress to the Pushgateway
(`backup-verify`, TCP 9091) and its ingress there.

## Risks

- **The paperless image as uid 1000.** The new Jobs run the image's
  commands directly as uid 1000 instead of its root entrypoint, for the
  Kyverno baseline. The files are owned by uid 1000, so it should work;
  each task checks it, and a PolicyException is the fallback, as for the
  Deployment.
- **The read-write backup mount.** The init container can write to the
  live database volume. It runs only the backup API (which writes nothing
  to the source beyond SQLite's lock state) and `integrity_check` on the
  copy; the restic container keeps read-only mounts.
- **OCR load.** Three languages slow OCR. The RK1 has 8 cores; a bulk
  import runs in daytime batches and the canary shows the effect.
- **NFS.** The inbox depends on the NAS like the media library; a NAS
  outage already pages (`HomelabNASUnreachable`, `HomelabNASDown`).
- **Forged mail.** See [Mail](#mail); the residual risk is in
  `docs/threat-model.md`.
