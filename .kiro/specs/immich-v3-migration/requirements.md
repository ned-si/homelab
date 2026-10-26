---
kind: change
status: done
created: 2026-10-16
closed: 2026-10-16
---
# Requirements: Immich 3 migration

## Introduction

Immich is held on 2.7.5 because its database still runs the pgvecto.rs vector extension,
which Immich 3 drops in favour of VectorChord. Renovate caps Immich below 3 for that reason
(#225, #287). This feature moves the database to VectorChord and Immich to the latest 3.x,
then removes the cap, with zero loss of photos, videos or metadata.

Non-goals:
- Changing where originals are stored (NAS, PVC `immich-data`), or touching them at all.
- Changing Immich features or settings beyond what 3.x requires.
- Moving Immich's database to the shared CNPG image used by the other apps.

## Glossary

- **Library**: the originals and generated files on the NAS (PVC `immich-data`).
- **Database**: the CNPG cluster `immich-db` (albums, users, faces, search vectors).
- **Baseline**: asset, people and album counts recorded just before the migration.

## Requirements

### Requirement 1: No data loss

**User story:** As the operator, I want every photo, video, album and face kept, so that the
upgrade is invisible apart from new features.

#### Acceptance criteria

1. WHEN the migration finishes, THE system SHALL report image and video counts greater than
   or equal to the baseline.
2. WHEN the migration finishes, THE system SHALL report people and album counts greater than
   or equal to the baseline.
3. THE migration SHALL NOT write to, resize, detach or delete the library volume.
4. WHEN 20 randomly sampled assets are requested, THE system SHALL return each original with
   HTTP 200.

### Requirement 2: Recoverable at every step

**User story:** As the operator, I want a tested way back, so that a failed migration costs
time, not data.

#### Acceptance criteria

1. BEFORE the database image changes, THE system SHALL hold a completed base backup and a
   `pg_dump` whose table of contents lists without error.
2. IF any verification in Requirement 1 or 3 fails and is not fixed within 30 minutes, THEN
   THE operator's automation SHALL restore the database on the old image and roll Immich back
   to 2.7.5.
3. IF auto-rollback opens a revert of the database image change, THEN THE automation SHALL
   close it, because reverting the image alone does not undo the data migration.

### Requirement 3: Features keep working

**User story:** As a user of the phone app, I want search, faces and timelines to work after
the upgrade, so that nothing feels broken.

#### Acceptance criteria

1. WHEN a smart-search query runs, THE system SHALL return results.
2. WHEN the phone app connects, THE server version and features endpoints SHALL answer.
3. WHEN the timeline loads, THE thumbnails SHALL load.
4. WHEN the migration finishes, THE Argo CD app `immich` SHALL be Synced and Healthy, and
   its PostSync smoke check SHALL pass.

### Requirement 4: Stay current afterwards

**User story:** As the operator, I want Immich to update itself again, so that it never falls
this far behind.

#### Acceptance criteria

1. WHEN the migration is verified, THE Renovate cap below Immich 3 SHALL be removed.
2. THE database image SHALL stay excluded from Renovate and pinned by digest, because its
   upgrades can be one-way.
3. THE repo-policy rule guarding the database image SHALL name the new image.

### Requirement 5: Quiet and documented

**User story:** As the operator, I want no pages for a planned migration and a written record
of what happened.

#### Acceptance criteria

1. WHILE the migration runs, THE alerts for namespace `immich` SHALL be silenced.
2. WHEN the migration finishes, THE runbook `docs/runbooks/immich-upgrade.md` SHALL describe
   the versions, the steps taken and how to roll back.
