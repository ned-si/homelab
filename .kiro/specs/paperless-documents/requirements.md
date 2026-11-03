---
kind: change
status: active
created: 2026-11-03
issue: 732
---
# Requirements: paperless-documents

## Introduction

Paperless-ngx runs at `archive.lilalala.com`, but nobody files documents in
it. On 2026-11-03 it held 1 document, no correspondents, document types,
tags, storage paths, workflows or mail accounts, and 5 user accounts. OCR is
English only, the time zone is UTC, the consume folder is a PVC that nothing
writes to, and documents can only get in through the web upload. Paperwork
ends up scattered and gets lost.

This spec makes Paperless the one home for the household's documents: easy
ways in (phone, a synced folder, mail, a scanner if there is one), OCR in
French, English and German, a taxonomy with matching rules, the import of
existing documents, access through Keycloak for one editor and one reader,
backups whose restore is tested end to end, and a plain-file export so the
documents are never locked in.

> **Deadline: the Seafile archive.** The two Seafile zvols may be deleted
> from **Tuesday 2026-11-17** on ("after 2026-11-16",
> [decisions.md](../../../docs/decisions.md#seafile-removed)). Task 1
> inventories and, if it holds files, exports the archive before then. Its
> target is **Friday 2026-11-13**, which leaves Monday 2026-11-16 as a
> buffer weekday. If task 1 cannot finish by Monday 2026-11-16, a pull
> request extends the zvol retention date first. The restic repository
> `seafile/shared` is kept after that date (no prune).

Non-goals:
- Moving Paperless from SQLite to Postgres
  ([runbooks/paperless-postgres.md](../../../docs/runbooks/paperless-postgres.md)
  explains why it stays).
- Two replicas: Paperless runs one replica on `ReadWriteOnce` volumes like
  every app here.
- Working documents. Shared documents being edited stay in Google Docs;
  Paperless holds finished documents.
- Automatic deletion. A retention rule can list what may go; a person
  deletes it.
- More than one person filing documents. One editor files everything; a
  second editor is a new issue.

## Glossary

- **Document**: a file Paperless consumed: the original, its archived PDF/A,
  the OCR text and its metadata.
- **Way in**: a path a file takes to reach Paperless: the phone app, the
  inbox folder, the mailbox, the scanner.
- **Inbox folder**: a Syncthing folder shared with the editor's devices,
  whose files Paperless consumes and then deletes.
- **Findable**: the document's text is returned by a full-text search in the
  web UI or the API.
- **Taxonomy**: the correspondents, document types, tags and custom fields
  Paperless assigns to documents. Storage paths are not used: one global
  file name format places every file (Requirement 5.6).
- **Export**: the output of Paperless' `document_exporter`: the originals,
  the archived versions and a `manifest.json` with all metadata, as plain
  files.
- **Editor**: the one household member who files documents: the operator's
  own Paperless account, in the Paperless group `editors`. It owns every
  document.
- **Reader**: a household member who reads documents and changes nothing,
  in the Paperless group `readers`. Today one person.
- **Superuser**: a Paperless account with the superuser flag: the
  break-glass `nedsi-admin` and the `automation` user. The editor is not a
  superuser, so the editor's API tokens do not carry superuser rights.

## Requirements

### Requirement 1: Documents arrive from the phone

**User story:** As the editor, I want to send a photo or a PDF from my
phone to Paperless, so paper gets filed the moment it arrives.

#### Acceptance criteria

1. THE editor SHALL be able to upload from the phone with a Paperless
   client app, from inside the app (camera scan) and from the share sheet of
   other apps. (test: one upload of each kind)
2. THE app SHALL authenticate with its user's own API token, without
   touching Keycloak. Paperless keeps one token per user, so revoking the
   editor's token after a lost phone cuts off all the editor's devices and
   the import script until each gets the new token. (test: a revoked token
   gets `401`)
3. WHEN a document arrives from the phone, THE document SHALL be owned by
   the editor.
4. A reader's token SHALL only read: an upload with it is refused. (test:
   `403`)

### Requirement 2: Documents arrive from a synced folder

**User story:** As the editor, I want to drop a file into a folder on my
Mac or phone and find it in Paperless, without opening a browser.

#### Acceptance criteria

1. THE cluster SHALL offer one Syncthing inbox folder, shared only with the
   editor's devices, and Paperless SHALL consume every file that appears in
   it.
2. WHEN a file in the inbox folder is consumed, THE document SHALL be owned
   by the editor and tagged `source:folder`.
3. WHEN Paperless has consumed a file, THE file SHALL be removed from the
   inbox folder; the editor's devices keep a copy in their Syncthing
   versioning for 30 days. (test: a dropped file disappears from the Mac's
   folder and is in its `.stversions`)
4. THE volume behind the inbox folder SHALL be reachable only by the four
   cluster nodes, not by the whole LAN. (test: an NFS mount from the Mac is
   refused)

### Requirement 3: Documents arrive by mail

**User story:** As the editor, I want to forward a mail or its attachment
to one address, so bills that come by mail are filed too.

#### Acceptance criteria

1. Paperless SHALL fetch a dedicated mailbox over IMAP (TLS) every 10
   minutes and consume the PDF and image attachments of each mail.
2. Paperless SHALL consume only mail whose sender is a household address,
   with one mail rule per address (a rule filters on one sender);
   everything else stays in the mailbox, unread.
3. WHEN a mail is consumed, THE document SHALL be owned by the editor and
   tagged `source:mail` and `inbox`, and THE mail SHALL be moved to a
   `Processed` folder.
4. THE mailbox credentials SHALL live only in a SOPS Secret; the
   CiliumNetworkPolicy `paperless` SHALL allow IMAPS egress (TCP 993) and
   nothing else new.
5. Paperless SHALL NOT read a household member's personal mailbox.
6. BECAUSE the sender filter trusts the `From` header, THE mailbox address
   SHALL NOT be published anywhere (it lives only in SOPS and the household's
   address books). FOR household sender domains that publish a DMARC policy
   of `p=quarantine` or `p=reject`, THE mailbox provider SHALL honour it, so
   a forged sender on those domains does not arrive. FOR sender domains
   with `p=none` (common for large free-mail providers), a forged sender is
   not stopped by DMARC; that residual risk is recorded in
   `docs/threat-model.md`. (test: the DMARC policy of each household sender
   domain is listed in the mail task's PR)

### Requirement 4: Documents arrive from a scanner

**User story:** As the editor, I want to scan a stack of paper and find it
in Paperless.

#### Acceptance criteria

1. IF the household has a scanner, THEN it SHALL send to Paperless through
   the mailbox (scan to mail), and the document SHALL be owned by the
   editor and tagged `source:scan`.
2. IF the household has no scanner, THEN the phone (Requirement 1) is the
   scanner and no scanner path is built (task 10 is optional).

### Requirement 5: OCR, dates and taxonomy fit the household

**User story:** As the editor, I want documents in French, English and
German read correctly and filed by who sent them and what they are, so
search and filters work without manual typing.

#### Acceptance criteria

1. Paperless SHALL OCR with the languages of open question 3 (default
   `PAPERLESS_OCR_LANGUAGE=fra+deu+eng`), and SHALL use the time zone
   `Europe/Zurich` and day-month-year dates.
2. THE document types, tags, custom fields, workflows and saved views SHALL
   be defined in git and applied by a Job, idempotently; a run on an
   unchanged configuration changes nothing. Git owns them: the editor and
   the readers get view rights on them and no change rights, so the Job
   never reverts an edit made in the UI. (test: the apply script's unit
   tests and a second run reporting 0 changes)
3. Correspondents SHALL NOT be in git: they are real names (banks,
   insurers, authorities). The editor creates and edits them in Paperless;
   they are kept in its backups and in the export.
4. WHEN a document is consumed, THE matching rules SHALL assign its document
   type and tags. Rules start explicit (`Any` with multi-word keywords in
   double quotes, `Regex`); NO keyword SHALL belong to two document types,
   and EVERY sample text of the test corpus (synthetic French, German and
   English texts, at least one per type, plus a Swiss QR-bill in each
   language) SHALL match exactly its expected document type, or none for a
   QR-bill without an invoice number. A document type or tag moves to
   Paperless' automatic classifier (`Auto`) only by a change in git, once
   at least 20 documents carry it. (test: the apply script's unit tests
   fail on an unquoted phrase, a shared keyword or a corpus text whose
   match differs from its expected type)
5. EVERY document SHALL get a `Retain until` date from its document type, or
   none for documents kept forever; a saved view SHALL list the documents
   whose date has passed. Deleting them stays a manual act.
6. THE stored file names SHALL be readable: year, document type, date,
   correspondent and title, from one global `PAPERLESS_FILENAME_FORMAT`; no
   storage paths.

### Requirement 6: Existing documents are imported

**User story:** As the editor, I want the documents I already have in
Paperless, so there is one place to look.

#### Acceptance criteria

1. BEFORE the Seafile zvols may be deleted (from 2026-11-17), THE Seafile
   archive SHALL be inventoried from the restic repository `seafile/shared`
   (snapshots `34f34ea0` and `8838dac0`) and, if it holds files, restored
   and exported to plain files outside git, with its file count and total
   size recorded; or, if that cannot be done by Monday 2026-11-16, THE
   retention date of the Seafile zvols in `docs/decisions.md` SHALL be
   extended in a pull request first.
2. THE files the operator places in the local import directory (the Seafile
   export and any other source, one subdirectory per source) SHALL be
   imported by a script through the API, owned by the editor, tagged
   `source:import` and `import:<source>`, with each folder name of their
   path as a tag.
3. AFTER each import batch, THE number of files in SHALL equal the documents
   created plus the duplicates Paperless refused plus the failures, and
   every failure SHALL be listed for the operator. One pull request records
   the counts and failure reasons of every batch; file names stay in the
   local report.
4. No document content, file name or correspondent name SHALL appear in git,
   a pull request, an issue or a log shipped off the cluster.

### Requirement 7: Backups restore documents and their metadata

**User story:** As the operator, I want proof every month that the documents
and the database restore into a working Paperless, so a backup is never
just files in a bucket.

#### Acceptance criteria

1. THE nightly backup SHALL take a consistent copy of `db.sqlite3` through
   SQLite's backup API, from a read-write mount on the Paperless pod's node
   (the database is in WAL mode), and store it under the tag
   `paperless-db`; the live file and its `-wal` and `-shm` files SHALL be
   excluded from `paperless-data`. (Paperless part of #746)
2. THE nightly backup SHALL run the export (Requirement 8) as a step before
   its restic snapshot, in the same Job, and SHALL store the finished export
   in the restic repository `paperless/media` under the tag
   `paperless-export`; IF the export step fails, THEN no snapshot is taken
   and the Job fails.
3. `backup-verify` SHALL restore the latest `paperless-export` snapshot
   every month and import it into a throwaway Paperless that runs only
   `migrate`, `document_importer` and a document count (no web server, no
   Celery worker or beat, no IMAP egress, so it never polls the real
   mailbox), and push the result to the Pushgateway; the imported document
   count SHALL equal the count in the export's `manifest.json` and the
   count in the database copy the export was taken from.
4. IF the restore test fails or has not succeeded for 35 days, THEN an
   alert SHALL page with a runbook.
5. THE weekly sample SHALL cover `paperless-media`, `paperless-data` and
   `paperless-db`, each with a required file that the backup still
   contains.

### Requirement 8: Documents are never locked in

**User story:** As the operator, I want every document and its metadata as
plain files, so I can leave Paperless or read a document without it.

#### Acceptance criteria

1. Every night, the backup Job SHALL run `document_exporter` into the PVC
   `paperless-export`, with the readable file names of Requirement 5.6,
   deleting files of documents that no longer exist, and with
   `--passphrase` from a SOPS Secret so the sensitive fields (the mail
   account password, social account tokens) are encrypted in
   `manifest.json`. The documents and all other metadata stay plain.
2. A `restic restore` of the tag `paperless-export` SHALL give the
   originals, the archived PDFs and `manifest.json` without running
   Paperless or knowing the passphrase. (test: the monthly restore test
   opens one PDF and parses the manifest)
3. IF the export step fails, THEN the backup Job fails and `KubeJobFailed`
   SHALL page, as for every Job.

### Requirement 9: One editor, one reader

**User story:** As the editor, I want to file every document myself and let
the reader read them, with the same login as every other app.

#### Acceptance criteria

1. Login SHALL stay Keycloak only (groups `admins` and `family`, as in
   `platform/keycloak/realm/access.conf`); the local admin account is
   break-glass only.
2. THE Paperless group `editors` SHALL hold the editor's account and SHALL
   be able to view, add, change and delete documents and correspondents and
   view document types, tags, custom fields, saved views and mail rules. THE
   group `readers` SHALL be able to view documents, correspondents,
   document types, tags, custom fields and saved views, and nothing else.
   Neither group has rights on users, groups, workflows, mail accounts or
   settings.
3. THE accounts in each group SHALL come from the member list in SOPS; an
   account created by a Keycloak login that is not on the list SHALL get no
   group and see no document.
4. EVERY document SHALL be owned by the editor and viewable by the group
   `readers`, unless it carries the tag `private`. The one exception is the
   ingest canary's page (Requirement 10.3), owned by the user `canary` for
   the minutes it exists. WHEN the tag `private`
   is set, at consumption or any time later, THE `readers` view SHALL be
   removed. (test: a matrix with a throwaway reader, as in PR #468, deleted
   afterwards)
5. THE document types, tags, custom fields and saved views SHALL be created
   without an owner, and every correspondent SHALL be viewable by the group
   `readers`, so the reader sees the same names as the editor. (test: the
   reader sees a correspondent the editor created, after the next
   configuration run)

### Requirement 10: A new document is findable within minutes

**User story:** As the editor, I want a document I just sent to show up in
a search right away, so I trust it arrived.

#### Acceptance criteria

1. WHEN a file of up to 10 pages reaches Paperless (the phone upload, the
   inbox folder on the cluster), THE document SHALL be findable within 5
   minutes.
2. WHEN a mail reaches the mailbox (including scan to mail), THE document
   SHALL be findable within 15 minutes (mail is checked every 10 minutes).
3. An ingest canary SHALL upload a generated one-page PDF through the API
   every 6 hours, measure the time until a full-text search finds it,
   delete it and empty it from the trash, and push the result to the
   Pushgateway.
4. IF the canary has not succeeded for 13 hours, or it took longer than the
   limit in 10.1 twice in a row, THEN an alert SHALL page with a runbook.

## Open questions

The operator answers these in the review of this spec; the answer goes into
the requirement or task it names.

1. **Taxonomy** (Requirement 5, [design](design.md#taxonomy-proposal)): the
   proposal is a starting point. Which document types, tags and custom
   fields to keep, rename or add? Which retention periods?
2. **Mailbox** (Requirement 3, task 9): which provider and address for the
   dedicated mailbox (IMAP with an app password, DMARC honoured on inbound
   mail)? Which sender addresses count as household, and what DMARC policy
   does each sender domain publish (`p=none` domains stay a residual risk)?
   Should a mail without attachments be filed too (as an `.eml` document)?
3. **OCR languages** (Requirement 5.1, task 2): the proposed answer is
   `fra+deu+eng`, French first. All three are in the image; each extra
   language slows OCR and can lower accuracy, and a garbled document is the
   signal to revisit. Add Italian (`ita`, also in the image), yes or no?
   Without an answer, task 2 ships the proposed answer.
4. **Sharing default** (Requirement 9.4, task 4): the proposed answer is
   that the reader sees every document unless the editor tags it
   `private`, because household documents concern both adults and
   per-type privacy would also hide the reader's own medical letters. The
   alternative is the reverse: private by default, shared by a tag. Without
   an answer, task 4 ships the proposed answer.

## Decided defaults

Questions the operator has no particular basis to answer are decided here,
with the reason. Each one is a line in git, so changing it later is one PR.

| Topic | Decision | Reason |
| --- | --- | --- |
| Who files documents | One editor (the operator), one reader (the other adult of the household) | The operator manages the documents; the reader only reads them |
| Who edits the taxonomy | Git owns types, tags, custom fields, workflows and saved views; the editor edits documents and correspondents | Changes are reviewed and backed up in git; an agent turns a request into a PR |
| Scanner | None assumed: the phone app is the scanner. Task 10 is a planned, optional task: it runs if a scanner is in use, through scan to mail; otherwise task 14 ticks it as not needed | Scan to mail needs no SMB share or new NAS user |
| Phone app | The first app in the [design table](design.md#phone) that logs in with a token against 3.4.1 on the editor's phone | A working token login is the only hard requirement |
| Other sources | Whatever the operator drops into the local import directory, one subdirectory per source; the Seafile export first | The operator knows where his files are; the script does the rest |
| N minutes | 5 minutes for files, 15 for mail | Single-page OCR on the RK1 takes well under a minute; mail polling adds up to 10 |
| Inbox semantics | A consumed file leaves the inbox folder; devices keep it 30 days in Syncthing versioning | An inbox that empties shows what is filed; versioning covers a mistake |
| Paper originals | No archive serial numbers for now | ASN stickers only pay off when paper is kept in numbered boxes; they can be added later without re-filing |
| Export passphrase | SOPS only, no second copy | It only protects the mail app password, which a new one replaces |
| Seafile fallback | Extend the zvol retention in a PR if task 1 cannot finish by 2026-11-16 | Cheap and reversible; deleting the zvols first is not |
