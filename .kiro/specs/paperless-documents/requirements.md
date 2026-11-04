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
tags, storage paths or workflows, and 5 user accounts. OCR is English only
and the time zone is UTC. Paperwork ends up scattered and gets lost.

This spec makes Paperless the one home for the household's documents:
uploads through the Paperless web app at `https://archive.lilalala.com`
from a phone or a computer, OCR in French, English, Spanish and German, a
taxonomy with matching rules, the import of existing documents, access
through Keycloak for one editor and one reader, backups whose restore is
tested end to end, and a plain-file export so the documents are never
locked in.

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
- Any way in other than the web app and the one-off import (operator
  decision, 2026-11-03). Another one is a new issue.

## Glossary

- **Document**: a file Paperless consumed: the original, its archived PDF/A,
  the OCR text and its metadata.
- **Web app**: the Paperless web UI at `https://archive.lilalala.com`, in a
  phone or computer browser, logged in through Keycloak.
- **Findable**: the document's text is returned by a full-text search in the
  web UI or the API.
- **Taxonomy**: the correspondents, document types, tags and custom fields
  Paperless assigns to documents. Storage paths are not used: one global
  file name format places every file (Requirement 2.6).
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
  superuser; administration goes through `nedsi-admin`.

## Requirements

### Requirement 1: Documents arrive through the web app

**User story:** As the editor, I want to upload a photo or a PDF from my
phone or my computer through the Paperless web app, so paper gets filed the
moment it arrives.

#### Acceptance criteria

1. THE editor SHALL be able to upload through the web app at
   `https://archive.lilalala.com`, logged in through Keycloak: from a phone
   browser (a file, or a photo taken through the browser's file picker) and
   from a computer (the upload button or drag and drop). (test: one upload
   of each kind)
2. WHEN the editor uploads a document, THE document SHALL be owned by the
   editor and viewable by the group `readers` (Requirement 6.4).
3. THE reader SHALL NOT be able to upload: the upload is refused. (test:
   `403`)

### Requirement 2: OCR, dates and taxonomy fit the household

**User story:** As the editor, I want documents in French, English,
Spanish and German read correctly and filed by who sent them and what they
are, so search and filters work without manual typing.

#### Acceptance criteria

1. Paperless SHALL OCR with `PAPERLESS_OCR_LANGUAGE=fra+eng+spa+deu`,
   and SHALL use the time zone `Europe/Zurich` and day-month-year dates.
2. THE document types, tags, custom fields, workflows and saved views SHALL
   be defined in git and applied by a Job, idempotently; a run on an
   unchanged configuration changes nothing. Git owns them: the editor and
   the readers get view rights on the document types, tags, custom fields
   and saved views, no rights on workflows (Requirement 6.2), and no change
   rights on any of them, so the Job never reverts an edit made in the UI.
   (test: the apply script's unit tests and a second run reporting 0
   changes)
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
   none for documents kept forever or without a type; a saved view SHALL
   list the documents whose date has passed. THE date SHALL be recomputed
   every night from the document's current type and creation date, so a
   re-typed or re-dated document gets the right date (or none) by the next
   morning; a date set by hand is overwritten. Deleting stays a manual act.
   (test: the apply script's unit tests re-type a Receipt to a Contract,
   which clears the date, and move a creation date, which moves it)
6. THE stored file names SHALL be readable: year, document type, date,
   correspondent and title, from one global `PAPERLESS_FILENAME_FORMAT`; no
   storage paths.

### Requirement 3: Existing documents are imported

**User story:** As the editor, I want the documents I already have in
Paperless, so there is one place to look.

#### Acceptance criteria

1. THE files the operator places in the local import directory (any local
   folder, one subdirectory per source) SHALL be
   imported by a script through the API, owned by the editor, tagged
   `import:<source>`. The tag is defined in git and created by the
   configuration Job without an owner, like every tag; the import script
   only attaches it and stops before the first upload if the source's tag
   does not exist. Folder names do not become tags; each file's path stays
   in the local report.
2. AFTER each import batch, THE number of files in SHALL equal the documents
   created plus the duplicates Paperless refused plus the failures, and
   every failure SHALL be listed for the operator. One pull request records
   the counts and failure reasons of every batch; file names stay in the
   local report.
3. No document content, file name or correspondent name SHALL appear in git,
   a pull request, an issue or a log shipped off the cluster.

### Requirement 4: Backups restore documents and their metadata

**User story:** As the operator, I want proof every month that the documents
and the database restore into a working Paperless, so a backup is never
just files in a bucket.

#### Acceptance criteria

1. THE nightly backup SHALL take a consistent copy of `db.sqlite3` through
   SQLite's backup API, from a read-write mount on the Paperless pod's node
   (the database is in WAL mode), and store it under the tag
   `paperless-db`; the live file and its `-wal` and `-shm` files SHALL be
   excluded from `paperless-data`. (Paperless part of #746)
2. THE nightly backup SHALL run the export (Requirement 5) as a step before
   its restic snapshot, in the same Job, and SHALL store the finished export
   in the restic repository `paperless/media` under the tag
   `paperless-export`; IF the export step fails, THEN no snapshot is taken
   and the Job fails.
3. `backup-verify` SHALL restore the latest `paperless-export` snapshot
   every month and import it into a throwaway Paperless that runs only
   `migrate`, `document_importer` and a document count (no web server, no
   Celery worker or beat), and push the result to the Pushgateway; the
   imported document count SHALL equal the count in the export's
   `manifest.json` and the count in the database copy the export was taken
   from, all three counted over the documents the exporter exports
   (documents in the trash are not counted).
4. IF the restore test fails or has not succeeded for 35 days, THEN an
   alert SHALL page with a runbook.
5. THE weekly sample SHALL cover `paperless-media`, `paperless-data` and
   `paperless-db`, each with a required file that the backup still
   contains.

### Requirement 5: Documents are never locked in

**User story:** As the operator, I want every document and its metadata as
plain files, so I can leave Paperless or read a document without it.

#### Acceptance criteria

1. Every night, the backup Job SHALL run `document_exporter` into the PVC
   `paperless-export`, with the readable file names of Requirement 2.6,
   deleting files of documents that no longer exist, and with
   `--passphrase` from a SOPS Secret so the sensitive fields (the social
   account tokens of the Keycloak logins) are encrypted in `manifest.json`.
   The documents and all other metadata stay plain.
2. A `restic restore` of the tag `paperless-export` SHALL give the
   originals, the archived PDFs and `manifest.json` without running
   Paperless or knowing the passphrase. (test: the monthly restore test
   opens one PDF and parses the manifest)
3. IF the export step fails, THEN the backup Job fails and `KubeJobFailed`
   SHALL page, as for every Job.

### Requirement 6: One editor, one reader

**User story:** As the editor, I want to file every document myself and let
the reader read them, with the same login as every other app.

#### Acceptance criteria

1. Login SHALL stay Keycloak only (groups `admins` and `family`, as in
   `platform/keycloak/realm/access.conf`); the local admin account is
   break-glass only.
2. THE Paperless group `editors` SHALL hold the editor's account and SHALL
   be able to view, add, change and delete documents and correspondents and
   view document types, tags, custom fields and saved views. THE group
   `readers` SHALL be able to view documents, correspondents, document
   types, tags, custom fields and saved views, and nothing else. Neither
   group has rights on users, groups, workflows or settings.
3. THE accounts in each group SHALL come from the member list in SOPS; an
   account created by a Keycloak login that is not on the list SHALL get no
   group and see no document.
4. EVERY document SHALL be owned by the editor and viewable by the group
   `readers`, unless it carries the tag `private`. The one exception is the
   ingest canary's page (Requirement 7.2), owned by the user `canary` for
   the minutes it exists. A new upload is viewable by the readers until the
   editor tags it `private`. WHEN the tag `private` is set, THE `readers`
   view SHALL be removed. THE tag SHALL be the
   only way to hide a document: the nightly run gives the readers' view
   back to every document without `private`, so a hide made in the
   permissions dialog lasts until the next night. (test: a matrix with a
   throwaway reader, as in PR #468, deleted afterwards)
5. THE document types, tags, custom fields and saved views SHALL be created
   without an owner, and every correspondent SHALL be viewable by the group
   `readers`, so the reader sees the same names as the editor. (test: the
   reader sees a correspondent the editor created, after the next
   configuration run)

### Requirement 7: A new document is findable within minutes

**User story:** As the editor, I want a document I just uploaded to show up
in a search right away, so I trust it arrived.

#### Acceptance criteria

1. WHEN a file of up to 10 pages has been uploaded through the web app, THE
   document SHALL be findable within 5 minutes.
2. An ingest canary SHALL upload a generated one-page PDF through the API
   every 6 hours, measure the time until a full-text search finds it,
   delete it and empty it from the trash, and push the result to the
   Pushgateway.
3. IF the canary has not succeeded for 13 hours, or it took longer than the
   limit in 7.1 twice in a row, THEN an alert SHALL page with a runbook.

## Decided defaults

No question is open. The operator decided the rows marked with his name;
the others are defaults with their reason. Each one is a line in git, so
changing it later is one PR.

| Topic | Decision | Reason |
| --- | --- | --- |
| Taxonomy (operator, 2026-11-03) | Approved as proposed: the document types, retention periods, tags, custom fields and saved views in [design](design.md#taxonomy) | Task 2 puts it into `paperless.json` unchanged; a later change is a PR |
| Way in (operator, 2026-11-03) | The web app only, at `https://archive.lilalala.com`, from a phone or a computer; plus the one-off import of existing files | The web app works on the phone, so nothing else is needed day to day |
| Source tags | None. Imported documents carry `import:<source>`; every other document came through the web app | With one way in, and imports already tagged `import:<source>`, a source tag says nothing |
| Who files documents | One editor (the operator), one reader (the other adult of the household) | The operator manages the documents; the reader only reads them |
| Sharing default (operator, 2026-11-03) | Visible to the reader by default: the reader sees every document unless the editor tags it `private`. The web app's upload sends only the file, so a new upload is visible to the reader from consumption until the editor tags it `private` | Household documents concern both adults, and per-type privacy would also hide the reader's own letters; the reverse (private by default, shared by a tag) is one workflow change in git |
| Who edits the taxonomy | Git owns types, tags, custom fields, workflows and saved views; the editor edits documents and correspondents | Changes are reviewed and backed up in git; an agent turns a request into a PR |
| OCR languages (operator, 2026-11-03) | `fra+eng+spa+deu`, in that order | Mostly French and English, sometimes Spanish and German. Tesseract treats the first language as the primary one and falls back to the others in the order given, so the order follows how often each language appears. Four languages make each page slower to OCR on the RK1 than one and load four models; task 1 measures time and peak memory against `fra` alone, the canary watches the time |
| Other sources | Whatever the operator drops into the local import directory, one subdirectory per source | The operator knows where his files are; the script does the rest |
| N minutes | 5 minutes for a file of up to 10 pages | Single-page OCR on the RK1 takes well under a minute; the canary measures every 6 hours |
| Paper originals | No archive serial numbers for now | ASN stickers only pay off when paper is kept in numbered boxes; they can be added later without re-filing |
| Export passphrase | SOPS only, no second copy | It only protects the social account tokens of the Keycloak logins, which a new login replaces |
