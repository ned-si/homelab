# Paperless: SQLite → Postgres (optional, not done)

**This document describes an option, not the system.** Paperless runs on
**SQLite** and this repo keeps it there deliberately —
`apps/paperless/deployment.yaml` says so at the top, there is no
`apps/paperless/database.yaml`, and step 2 below asks you to create one. Nothing
here has been executed. Do not read it as a description of the running cluster.

## Why it is on SQLite

`PAPERLESS_DBHOST` has never been set, so Paperless has been using SQLite inside
the `paperless-data` volume since it was deployed.

## Why it was not "fixed"

Pointing Paperless at Postgres does **not** migrate the data. It comes up against
an empty database and presents an empty archive, while the real documents sit
untouched in the `paperless-media` volume and the metadata sits orphaned in the
SQLite file. Paperless has no in-place converter.

Doing that silently as part of a refactor looks exactly like data loss. So the
manifest keeps SQLite and this document exists instead.

The backup consequence is handled: `apps/paperless/backup.yaml` copies the SQLite
database through SQLite's own `.backup` API rather than copying bytes from under a
running writer. See [backups.md](../backups.md).

## Is it worth migrating?

Honestly, for a single-user document archive: probably not.

Postgres helps with concurrent writers and large datasets. Paperless has one
writer and a few thousand documents. SQLite on a local iSCSI volume is fine, and
it is one less database to back up and upgrade.

Migrate if you want consistency with the rest of the cluster (everything else is
CloudNativePG), or if you start seeing `database is locked` errors during bulk
OCR.

## How to migrate

The supported path is export → switch → import.

### 1. Export everything

```sh
kubectl -n paperless exec deploy/paperless -- \
  document_exporter /data/media/export --no-progress-bar
```

This writes documents plus a `manifest.json` containing all metadata (tags,
correspondents, document types, users). Verify it is non-trivial in size before
continuing:

```sh
kubectl -n paperless exec deploy/paperless -- du -sh /data/media/export
```

Copy it off the cluster. Do not trust a single copy inside the thing you are
about to change.

### 2. Add a CloudNativePG cluster

Create `apps/paperless/database.yaml` following the pattern in
`apps/mealie/database.yaml`, and add it to `apps/paperless/kustomization.yaml`.

### 3. Point Paperless at it

Add to the Deployment's env, taking credentials from the generated
`paperless-postgresql-app` Secret:

```yaml
- name: PAPERLESS_DBENGINE
  value: postgresql
- name: PAPERLESS_DBHOST
  valueFrom:
    secretKeyRef: { name: paperless-postgresql-app, key: host }
- name: PAPERLESS_DBPORT
  valueFrom:
    secretKeyRef: { name: paperless-postgresql-app, key: port }
- name: PAPERLESS_DBNAME
  valueFrom:
    secretKeyRef: { name: paperless-postgresql-app, key: dbname }
- name: PAPERLESS_DBUSER
  valueFrom:
    secretKeyRef: { name: paperless-postgresql-app, key: username }
- name: PAPERLESS_DBPASS
  valueFrom:
    secretKeyRef: { name: paperless-postgresql-app, key: password }
```

Sync. Paperless starts against an empty Postgres and runs its migrations.

### 4. Import

```sh
kubectl -n paperless exec deploy/paperless -- \
  document_importer /data/media/export --no-progress-bar
```

### 5. Verify, then clean up

Check document count, tags and a few thumbnails in the UI. Only then delete the
old SQLite file (`/data/data/db.sqlite3`) and the export directory.

Keep the export until you are certain. It is the only rollback you have.
