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
French, German and English, a taxonomy with matching rules, the import of
existing documents, per-member access through Keycloak, backups whose
restore is tested end to end, and a plain-file export so the documents are
never locked in.

> **Deadline: the Seafile archive.** The two Seafile zvols may be deleted
> after **Monday 2026-11-16** ([decisions.md](../../../docs/decisions.md#seafile-removed)).
> Task 1 inventories and exports the archive before then. The last weekday
> for it under the daytime rule is **Friday 2026-11-13**. The restic
> repository `seafile/shared` is kept after that date (no prune), so a
> missed deadline only costs the zvols, provided task 1 has shown that the
> restic copy restores.

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

## Glossary

- **Document**: a file Paperless consumed: the original, its archived PDF/A,
  the OCR text and its metadata.
- **Way in**: a path a file takes to reach Paperless: the phone app, the
  inbox folder, the mailbox, the scanner.
- **Inbox folder**: the Syncthing folder whose files Paperless consumes and
  then deletes.
- **Findable**: the document's text is returned by a full-text search in the
  web UI or the API.
- **Taxonomy**: the correspondents, document types, tags, custom fields and
  storage paths Paperless assigns to documents.
- **Export**: the output of Paperless' `document_exporter`: the originals,
  the archived versions and a `manifest.json` with all metadata, as plain
  files.
- **Member**: a household user in the Keycloak group `family` or `admins`.

## Requirements

### Requirement 1: Documents arrive from the phone

**User story:** As a member, I want to send a photo or a PDF from my phone
to Paperless, so paper gets filed the moment it arrives.

#### Acceptance criteria

1. THE household SHALL be able to upload from the phone with a Paperless
   client app, from inside the app (camera scan) and from the share sheet of
   other apps. (test: one upload per platform in use)
2. EACH member's phone SHALL authenticate with that member's own API token,
   so a lost phone is cut off by revoking one token without touching
   Keycloak or the other members. (test: a revoked token gets `401`)
3. WHEN a document arrives from the phone, THE document SHALL be owned by
   the member whose token uploaded it.

### Requirement 2: Documents arrive from a synced folder

**User story:** As a member, I want to drop a file into a folder on my Mac
or phone and find it in Paperless, without opening a browser.

#### Acceptance criteria

1. THE cluster SHALL offer a Syncthing folder (the inbox folder) with one
   subfolder per member, and Paperless SHALL consume every file that
   appears in it.
2. WHEN a file in a member's subfolder is consumed, THE document SHALL be
   owned by that member and tagged `source:folder`.
3. WHEN Paperless has consumed a file, THE file SHALL be removed from the
   inbox folder; a device keeps a copy in its Syncthing versioning for 30
   days. (test: a consumed file disappears on the device and is in
   `.stversions`)
4. THE volume behind the inbox folder SHALL be reachable only by the four
   cluster nodes (and the scanner, if Requirement 4 uses it), not by the
   whole LAN. (test: an NFS mount from the Mac is refused)

### Requirement 3: Documents arrive by mail

**User story:** As a member, I want to forward a mail or its attachment to
one address, so bills that come by mail are filed too.

#### Acceptance criteria

1. Paperless SHALL fetch a dedicated mailbox over IMAP (TLS) every 10
   minutes and consume the PDF and image attachments of each mail.
2. Paperless SHALL consume only mail whose sender is a household address in
   its mail rule; everything else stays in the mailbox, unread.
3. WHEN a mail is consumed, THE document SHALL be owned by the member whose
   address sent it and tagged `source:mail`, and THE mail SHALL be moved to
   a `Processed` folder.
4. THE mailbox credentials SHALL live only in a SOPS Secret; the
   CiliumNetworkPolicy `paperless` SHALL allow IMAPS egress (TCP 993) and
   nothing else new.
5. Paperless SHALL NOT read a member's personal mailbox.

### Requirement 4: Documents arrive from a scanner

**User story:** As a member, I want to scan a stack of paper and find it in
Paperless.

#### Acceptance criteria

1. IF the household has a scanner, THEN it SHALL send to Paperless through
   the mailbox (scan to mail) or the inbox volume (scan to a network
   folder), whichever it supports, and the document SHALL be tagged
   `source:scan`.
2. IF the household has no scanner, THEN the phone (Requirement 1) is the
   scanner, and this requirement moves to a `deferred` issue.

### Requirement 5: OCR, dates and taxonomy fit the household

**User story:** As a member, I want documents in French, German and English
read correctly and filed by who sent them and what they are, so search and
filters work without manual typing.

#### Acceptance criteria

1. Paperless SHALL OCR with the languages French, German and English
   (`PAPERLESS_OCR_LANGUAGE`, set from the open question below), and SHALL
   use the time zone `Europe/Zurich` and day-month-year dates.
2. THE document types, tags, custom fields, storage paths, workflows and
   saved views SHALL be defined in git and applied by a Job, idempotently;
   a run on an unchanged configuration changes nothing. (test: the apply
   script's unit tests and a second run reporting 0 changes)
3. Correspondents SHALL NOT be in git: they are real names (banks,
   insurers, authorities). They are kept in Paperless, in its backups and in
   the export.
4. WHEN a document is consumed, THE matching rules SHALL assign its document
   type and tags. Rules start explicit (`Any`, `Regex`); a document type or
   tag moves to Paperless' automatic classifier (`Auto`) only by a change in
   git, once at least 20 documents carry it.
5. EVERY document SHALL get a `Retain until` date from its document type, or
   none for documents kept forever; a saved view SHALL list the documents
   whose date has passed. Deleting them stays a manual act.
6. THE stored file names SHALL be readable: owner, year, document type,
   date, correspondent and title (`PAPERLESS_FILENAME_FORMAT`).

### Requirement 6: Existing documents are imported

**User story:** As the operator, I want the documents I already have in
Paperless, so there is one place to look.

#### Acceptance criteria

1. BEFORE 2026-11-16, THE Seafile archive SHALL be restored from the restic
   repository `seafile/shared` (snapshots `34f34ea0` and `8838dac0`) and
   exported to plain files outside git, with its file count and total size
   recorded; or, if that cannot be done by Friday 2026-11-13, THE retention
   date of the Seafile zvols in `docs/decisions.md` SHALL be extended in a
   pull request first.
2. THE files the operator selects from the Seafile export and from the other
   sources (open question 6) SHALL be imported by a script through the API,
   owned by the member they belong to, tagged `source:import` and
   `import:<source>`, with each folder name of their path as a tag.
3. AFTER each import batch, THE number of files in SHALL equal the documents
   created plus the duplicates Paperless refused plus the failures, and
   every failure SHALL be listed for the operator (counts and reasons in the
   pull request, file names only in the local report).
4. No document content, file name or correspondent name SHALL appear in git,
   a pull request, an issue or a log shipped off the cluster.

### Requirement 7: Backups restore documents and their metadata

**User story:** As the operator, I want proof every month that the documents
and the database restore into a working Paperless, so a backup is never
just files in a bucket.

#### Acceptance criteria

1. THE nightly backup SHALL take a consistent copy of `db.sqlite3` through
   SQLite's backup API, not a live file copy. (Paperless part of #746)
2. THE nightly backup SHALL include the export (Requirement 8) in the
   restic repository `paperless/media` under the tag `paperless-export`.
3. `backup-verify` SHALL restore the latest `paperless-export` snapshot
   every month, import it into a throwaway Paperless, and push the result to
   the Pushgateway; the imported document count SHALL equal the count in the
   export's `manifest.json` and the live count at export time.
4. IF the restore test fails or has not succeeded for 35 days, THEN an
   alert SHALL page with a runbook.
5. THE existing weekly sample (`paperless-media`, `paperless-data`) SHALL
   keep running.

### Requirement 8: Documents are never locked in

**User story:** As the operator, I want every document and its metadata as
plain files, so I can leave Paperless or read a document without it.

#### Acceptance criteria

1. Every night, a Job SHALL run `document_exporter` into the PVC
   `paperless-export`, with the readable file names of Requirement 5.6 and
   deleting files of documents that no longer exist.
2. A `restic restore` of the tag `paperless-export` SHALL give the
   originals, the archived PDFs and `manifest.json` without running
   Paperless. (test: the monthly restore test opens one PDF and parses the
   manifest)
3. IF the export Job fails, THEN `KubeJobFailed` SHALL page, as for every
   Job.

### Requirement 9: Each member sees their documents

**User story:** As a member, I want my own documents private and the
household's documents shared, with the same login as every other app.

#### Acceptance criteria

1. Login SHALL stay Keycloak only (groups `admins` and `family`, as in
   `platform/keycloak/realm/access.conf`); the local admin account is
   break-glass only.
2. WHEN a member logs in for the first time, Paperless SHALL create the
   account in the Paperless group `household`, which may view, add and
   change documents and the taxonomy, but not users, mail accounts or
   settings.
3. A document SHALL be owned by the member it came from; a document shared
   with the household SHALL be viewable and changeable by the group
   `household`; a private document SHALL be visible to its owner and to
   `admins` only. (test: a matrix with throwaway users, as in PR #468,
   deleted afterwards)
4. THE default for a new document SHALL be decided by the open question on
   sharing (proposal: shared with the household, except the document types
   `Medical` and `Payslip`).

### Requirement 10: A new document is findable within minutes

**User story:** As a member, I want a document I just sent to show up in a
search right away, so I trust it arrived.

#### Acceptance criteria

1. WHEN a file of up to 10 pages reaches Paperless (the phone upload, the
   inbox folder on the cluster, the scanner), THE document SHALL be findable
   within 5 minutes.
2. WHEN a mail reaches the mailbox, THE document SHALL be findable within
   15 minutes (mail is checked every 10 minutes).
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
   proposal is a starting point. Which document types, tags and storage
   paths to keep, rename or add? Which retention periods?
2. **OCR languages** (5.1): French, German and English, in which order of
   priority (the first is the main language)? Add Italian (installed in the
   image) for mail from other cantons? Every extra language slows OCR and
   can lower accuracy a little.
3. **Mailbox** (Requirement 3): which provider and address for the
   dedicated mailbox, with IMAP and an app password? Which sender addresses
   count as household? Should a mail without attachments be filed too (as an
   `.eml` document)?
4. **Scanner** (Requirement 4): is there a scanner or a printer that scans,
   which model, and does it scan to mail or to an SMB folder?
5. **Phones** (Requirement 1): iOS, Android or both, and which client app
   (candidates in the [design](design.md#phone))?
6. **Other sources** (6.2): where else are documents today (Mac folders,
   cloud drives, mail attachments, paper boxes), and which of them to
   import? Which Seafile files are worth importing once the inventory of
   task 1 shows what is there?
7. **Sharing default** (9.4): shared with the household by default, with
   `Medical` and `Payslip` private? Which members get accounts?
8. **N minutes** (Requirement 10): are 5 minutes for files and 15 for mail
   the right promise?
9. **Inbox semantics** (2.3): may a file disappear from the Mac or phone
   folder once Paperless has it (kept 30 days in Syncthing versioning), or
   should the device keep its copy?
10. **Paper originals**: are paper originals kept after scanning? If yes,
    archive serial numbers (ASN barcode stickers) tie a document to its
    box; if no, nothing to add.
11. **Seafile deadline** (6.1): if task 1 cannot run by Friday 2026-11-13,
    extend the zvol retention, or rely on the restic copy alone?
