# Design: paperless-documents

## Current state (read-only, 2026-11-03)

| What | Value |
| --- | --- |
| Image | `ghcr.io/paperless-ngx/paperless-ngx:3.4.1`, one replica, SQLite, Valkey queue |
| URL, login | `archive.lilalala.com`, Keycloak only (`PAPERLESS_REDIRECT_LOGIN_TO_SSO`, auto signup), groups `admins` and `family` (`access.conf`, PR #468) |
| Volumes | `paperless-data` 4Gi (27M used), `paperless-media` 100Gi (1 MiB used), `paperless-consume` 10Gi (empty), all iSCSI |
| Content | 1 document, 0 correspondents, document types, tags, storage paths, workflows, mail accounts; 5 user accounts |
| OCR | `eng` only; the image ships `deu eng fra ita osd spa` |
| Time zone, dates | `UTC`, `DMY` |
| File names | default (`FILENAME_FORMAT` unset: numeric names) |
| Ways in | web upload only; no mail account, no scanner path, nothing writes to the consume volume |
| Backup | `paperless-backup` 02:30 to restic `paperless/media` (tags `paperless-media`, `paperless-data`), monthly `paperless-prune`; the SQLite file is copied live (the restic image has no `sqlite3`), so it can be torn (#746) |
| Restore test | `backup-verify` weekly sample: `paperless-media`, `paperless-data` with `/data/db.sqlite3`; monthly pack read |
| Network | CiliumNetworkPolicy `paperless`: ingress from the Gateway, egress DNS, intra-namespace, TCP 443 to the world |

## Shape

```
phone app ──API token──────────────┐
Mac / phone ──Syncthing──▶ NFS inbox (paperless-inbox) ──polling──┐
scanner ──scan to mail──▶ mailbox ◀──IMAPS every 10 min──┐        │
                                                         ▼        ▼
                                                Paperless (consume, OCR fra+deu+eng,
                                                matching, workflows: owner, source, sharing)
                                                         │
             02:00 paperless-export ─────────────────────┤ document_exporter ─▶ PVC paperless-export
             02:30 paperless-backup ── consistent SQLite copy + media + data + export ─▶ restic paperless/media
             monthly backup-verify ── restore paperless-export ─▶ throwaway Paperless, document_importer, counts
             every 6 h paperless-canary ── generated PDF ─▶ API ─▶ search ─▶ Pushgateway
```

## Ways in

### Phone

A Paperless client app with a per-member API token. Members log in through
Keycloak and have no local password, so the token (web UI, My Profile, API
token) is the only credential the app holds; revoking it cuts off one phone.
Candidates, chosen in task 8 with open question 5:

| App | Platforms | Upload | Share sheet |
| --- | --- | --- | --- |
| Paperless Mobile | Android, iOS | camera scan, files | yes |
| Swift Paperless | iOS | camera scan, files | yes |
| PaperNext | Android, iOS | camera scan, files | check |
| QuickScan | iOS | scanner app with Paperless API upload | yes |

The task checks that the chosen app logs in with a token against 3.4.1,
then records the choice and the setup in `docs/paperless.md`. A workflow
tags uploads through the API `source:phone`; the owner is the token's user.

### Inbox folder

A TrueNAS dataset `homelab/k8s/nfs/paperless-inbox`, exported over NFS to
the four node addresses only (`192.168.1.247`, `.238`, `.239`, `.240`),
mounted by two static PersistentVolumes with `Retain`, as in
`infrastructure/nfs-storage/nfs-volumes.yaml`:

- in `syncthing`, at `/var/syncthing/paperless-inbox`, shared as the
  Syncthing folder `paperless-inbox` with the members' devices;
- in `paperless`, at `/data/consume` (replacing the iSCSI
  `paperless-consume`, which stays `Retain` until a later issue releases
  it), with `PAPERLESS_CONSUMER_POLLING=30` (inotify does not see NFS
  changes) and `PAPERLESS_CONSUMER_RECURSIVE=true`.

Both run as uid 1000 (Syncthing `PUID`, Paperless `USERMAP_UID` default), so
files keep one owner. Layout: `<member>/` per member. A workflow per member
(trigger "Consumption started", source "Consume folder", path filter
`*/<member>/*`) sets the owner and tags `source:folder`. The member names
are personal data: the workflows that carry them come from the SOPS part of
the configuration ([Configuration as code](#configuration-as-code)).

Paperless deletes a file once consumed, and Syncthing propagates the
deletion to the devices. Each device keeps it in "trash can" file
versioning for 30 days (open question 9).

Rejected: a second Syncthing inside the `paperless` namespace sharing the
iSCSI consume volume. It avoids NFS, but adds a device identity to pair on
every device and a second protocol address and port forward. Rejected: a
bridge Job that uploads from the Syncthing volume through the API; more code
for the same result.

### Mail

A dedicated mailbox (open question 3), never a member's own. Paperless
stores its mail account in its database; the configuration Job creates it
from the SOPS Secret `paperless-mail` (host, port 993, user, app password,
the household sender addresses). One mail rule per member: filter "from"
the member's addresses, attachments only (PDF and images), action "move to
folder `Processed`", owner set by a workflow filtered on that rule, tag
`source:mail`. Mail from anyone else matches no rule and stays unread.
`PAPERLESS_EMAIL_TASK_CRON` keeps its default, every 10 minutes.

The CiliumNetworkPolicy `paperless` gets one egress rule: TCP 993 to the
world (the provider's address is not stable enough for a CIDR).

### Scanner

Only if there is one (open question 4). Scan to mail uses the mailbox with
the scanner's sender address in a rule tagged `source:scan`. Scan to a
network folder uses an SMB share of the inbox dataset, limited to the
scanner's address and its own TrueNAS user, writing to `scanner/`. With no
scanner, the phone app is the scanner and this part becomes a `deferred`
issue.

## Settings

Environment changes in `apps/paperless/deployment.yaml`:

| Variable | Value | Why |
| --- | --- | --- |
| `PAPERLESS_OCR_LANGUAGE` | `fra+deu+eng` (order from open question 2) | the household's languages; all three are in the image, so `PAPERLESS_OCR_LANGUAGES` stays unset |
| `PAPERLESS_TIME_ZONE` | `Europe/Zurich` | creation dates near midnight land on the right day |
| `PAPERLESS_DATE_ORDER` | `DMY` | explicit (today's default) |
| `PAPERLESS_FILENAME_FORMAT` | `{{ owner_username }}/{{ created_year }}/{{ document_type }}/{{ created }} {{ correspondent }} {{ title }}` | readable files in the media volume and the export |
| `PAPERLESS_CONSUMER_POLLING` | `30` | NFS inbox |
| `PAPERLESS_CONSUMER_RECURSIVE` | `true` | per-member subfolders |
| `PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS` | `household` | first login lands in the household group |

Setting the file name format renames existing files on disk. With one
document today that is free, and restic stores renamed files without new
data, which is why it comes before the import.

## Taxonomy proposal

**This is a proposal for the operator to adjust** (open question 1). Names
are in English; the matching keywords cover French, German and English.

### Document types and retention

| Type | Matching (`Any`, case-insensitive) | Retain |
| --- | --- | --- |
| Invoice | facture, Rechnung, invoice | 5 years |
| Receipt | quittance, ticket de caisse, Quittung, Kassenbon, receipt | 2 years |
| Statement | relevé, extrait de compte, Kontoauszug, Auszug, statement | 10 years |
| Tax | déclaration d'impôt, taxation, Steuererklärung, Veranlagung, tax return | 10 years |
| Payslip | fiche de salaire, décompte de salaire, Lohnabrechnung, Lohnausweis, payslip | forever |
| Insurance | police, attestation d'assurance, Versicherungspolice, Police, policy | forever |
| Contract | contrat, Vertrag, contract, agreement | forever |
| Medical | ordonnance, rapport médical, Arztbericht, Rezept, medical report | 10 years |
| Official | acte, certificat, attestation, Urkunde, Bescheinigung, certificate | forever |
| Warranty | garantie, Garantieschein, warranty, manual | forever |
| Letter | courrier, Brief, letter (fallback, no keywords: set by hand) | 5 years |

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

Area tags match on keywords (for example `utilities`: électricité,
Strom, electricity, Wasser, eau); `to-pay` matches a Swiss QR-bill
(`Zahlteil`, `Section paiement`, `Payment part`); `tax-relevant` is added
by a workflow to the types Tax, Statement, Payslip and Insurance.

### Custom fields

`Retain until` (date), `Amount` (monetary, CHF), `Due date` (date),
`Tax year` (integer).

### Correspondents

Kept in Paperless only, never in git: they are real names. Examples of the
kind: a bank, the health insurer, the cantonal tax office, the landlord, a
utility, a payroll office. Each gets its match text (name, IBAN, UID
number) in the UI.

### Saved views

Inbox (`inbox`), To pay (`to-pay`, by `Due date`), Tax year (`tax-relevant`,
by `Tax year`), Retention expired (`Retain until` before today), Recently
added. Shown on the dashboard for the group `household`.

## Matching and workflows

Explicit matching first (`Any` keywords, `Regex` for the QR-bill), because
the automatic classifier needs training data the archive does not have. A
type or tag moves to `Auto` in git once 20 documents carry it.

| Workflow | Trigger, filter | Actions |
| --- | --- | --- |
| owner-folder-`<member>` | Consumption started, consume folder, path `*/<member>/*` | owner `<member>`, tag `source:folder` |
| owner-mail-`<member>` | Consumption started, mail rule of `<member>` | owner `<member>`, tag `source:mail` |
| source-phone | Consumption started, API upload | tag `source:phone` |
| share-household | Document added | view and change for group `household` |
| private-types | Document added, type Medical or Payslip | remove the `household` permissions |
| tax-relevant | Document added, type Tax, Statement, Payslip or Insurance | tag `tax-relevant` |

`share-household` and `private-types` follow open question 7.

## Configuration as code

`apps/paperless/config/paperless.json`: document types, tags, custom
fields, saved views and the workflows without personal data. The SOPS
Secret `paperless-config` holds the personal part: members, their
subfolders, their sender addresses. `apps/paperless/config/apply.py`
(Python stdlib, `urllib` and `json`) reads both and upserts through the API
by name: it creates what is missing and updates what differs. It deletes
nothing: an object that is in Paperless but not in the configuration is
reported, and a person removes it, because removing a tag or type strips it
from every document. It runs:

- as an Argo CD PostSync Job after each sync of `paperless`;
- nightly in `--retention` mode (the `Retain until` dates).

It authenticates as the Paperless user `automation` (superuser: mail
accounts and workflows need it) with an API token in the SOPS Secret
`paperless-automation`, created once with `manage.py` and sealed with
`scripts/seal-secrets-from-env.sh`; it goes into `docs/secrets.md` and
`ci/secret-rotation.tsv`. Unit tests in `tests/` against a fake API, like
the Keycloak realm tests.

Rejected: configuring everything in the UI. It works, but the backup is the
only record and nothing reviews a change. Rejected: correspondents in git,
even SOPS-encrypted: the names would be in every clone's history, and they
change as letters arrive.

## Access

Login stays as it is: Keycloak, groups `admins` and `family`. Inside
Paperless:

| Who | Paperless account | Sees |
| --- | --- | --- |
| A member | created on first login, group `household` (view, add, change documents and taxonomy; no users, mail, settings) | own documents, documents shared with `household` |
| The operator | superuser | everything |
| `nedsi-admin` | local superuser, break-glass | everything; password in `paperless-secrets` |
| `automation` | superuser, API token only | configuration |
| `canary` | no group, API token only | its own canary documents |

Group sync from Keycloak (`PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS`) is not
needed: Keycloak already decides who logs in, and one Paperless group
covers the household.

The API is public at `archive.lilalala.com/api/` and accepts tokens without
Keycloak; that is what the phone apps need. Task 9 checks whether it also
accepts the local admin password over basic auth from the internet; if so,
that is a new issue (security), not part of this spec.

## Import

### Seafile archive (deadline 2026-11-16)

Seafile stored files as hash-named blocks; the MariaDB dump maps them to
libraries and files ([backups.md](../../../docs/backups.md#consistency-per-tag)).
Both snapshots are needed.

1. A scratch namespace with the verifier credentials and a scratch iSCSI
   volume, as in [How to restore](../../../docs/backups.md#how-to-restore)
   (a live write: the task's brief allows it).
2. `restic restore 34f34ea0` (dump) and `8838dac0` (data and
   `seafile/conf/`).
3. One pod: `mariadb:10.11` loading the dump, and the Seafile 11 server
   image with the restored `conf/` running `seaf-fsck.sh --export
   /export`, which writes every library as plain files.
4. Inventory on the volume: file count, total size, count per extension.
   The counts go into the pull request; the list of names only to the
   operator.
5. Copy the export to the operator's Mac under `~/homelab-backups/` (outside
   git) for the selection, then delete the scratch namespace and volume.

This also proves the restic copy restores, which is what is left once the
zvols go. If the Seafile tools cannot run on the restored data, the
fallback is a read-only pod on the two zvols themselves, which is why the
task must finish before 2026-11-16. The pull request updates
"Seafile removed" in `docs/decisions.md` with the outcome.

### Other sources and the import script

`scripts/paperless-import.py` (stdlib): walks a local directory, uploads
each file through `/api/documents/post_document/` with the token of the
member who owns the batch, tags `source:import`, `import:<source>` and one
tag per folder name, follows each consumption task to its result, and
writes a local report (created, duplicate, failed with reason). It prints
counts only. Re-running it is safe: Paperless refuses duplicates by
checksum. Batches go in during the day, a few hundred files at a time, so
OCR does not starve the node.

## Backups, export and restore

| Job | When | What |
| --- | --- | --- |
| `paperless-export` (new) | 02:00 | paperless image, co-scheduled with the pod (RWO volumes), `document_exporter /export --use-filename-format --delete --no-progress-bar` into PVC `paperless-export` (`iscsi-retain`), then `export-meta.json` with the live document count |
| `paperless-backup` (changed) | 02:30 | init container with the paperless image: `sqlite3.connect(...).backup(...)` (Python's SQLite backup API; the image has SQLite 3.46.1) into an emptyDir; then restic: the consistent copy (tag `paperless-db`), `/media`, `/data` minus `db.sqlite3`, index and thumbnails, and `/export` (tag `paperless-export`) |
| `restore-paperless` (new, `backup-verify`) | monthly | restore the latest `paperless-export`, start a throwaway Paperless on SQLite in a scratch volume, `migrate`, `document_importer`, count documents; pass when imported = `manifest.json` = `export-meta.json`, one restored PDF opens; push the result like the other restore tests |

The export is where "never locked in" comes from: `restic restore --tag
paperless-export` gives plain files and a JSON manifest without Paperless.
restic deduplicates the export against the originals in `/media`, so it
adds little to the bucket.

The export lives on iSCSI, not on an NFS share the Mac could browse,
because the NAS exports are open to the whole LAN today (#721) and the
export is every document in plain files. The flags are checked against
`document_exporter --help` of 3.4.1 in the task.

The `paperless-data` sample in `restic-targets.txt` changes its required
file to the consistent copy; `paperless-export` is added with
`/export/manifest.json`. `restic-data-targets.txt` already covers the
repository. The new CronJobs go into `ci/active-cronjobs.txt` and, for the
backup, `backup-slo-targets.yaml`.

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
- **SQLite journal mode.** A backup through the SQLite API on a read-only
  mount works with the rollback journal, not with WAL. The task checks the
  journal mode first.
- **OCR load.** Three languages slow OCR. The RK1 has 8 cores; a bulk
  import runs in daytime batches and the canary shows the effect.
- **NFS.** The inbox depends on the NAS like the media library; a NAS
  outage already pages (`HomelabNASUnreachable`, `HomelabNASDown`).
