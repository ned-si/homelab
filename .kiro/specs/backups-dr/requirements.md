# Requirements: backups-dr (as-is)

## Introduction

Every app's data is backed up nightly with restic to one versioned S3 bucket;
every CloudNativePG cluster archives WAL continuously and takes a daily base
backup to the same bucket. Restores are tested every week in the cluster, and
old object versions cannot be deleted by anyone in the account. This spec
records that behaviour. Detail: [docs/backups.md](../../../docs/backups.md);
promises (RPO, RTO): [docs/sre.md](../../../docs/sre.md#rpo).

Non-goals:
- The media library (re-acquirable, about 9.5 TB, not backed up).
- The Immich migration itself (`.kiro/specs/immich-v3-migration/`).

## Glossary

- **Fresh**: a backup that succeeded less than 24 hours ago.
- **One-way change**: a database major, a cutover, a node flash, the Immich
  database; it always gets a fresh backup first.

## Requirements

### Requirement 1: Every app's data has an off-site copy

**User story:** As the operator, I want photos, documents and app state
recoverable after losing the cluster or the NAS.

#### Acceptance criteria

1. THE backup CronJobs SHALL run restic nightly to one repository per prefix
   in bucket `ned-si-homelab-backups`, one start per time slot, each ending
   with `restic check`. (schedule in `docs/backups.md`; `kubectl get cronjobs
   -A | grep -E 'backup|prune'`)
2. A backup CronJob SHALL run unsuspended only when listed in
   `ci/active-cronjobs.txt`; any other ships suspended behind its
   `pending-guard`. (repo-policy `cronjob-active`, `cronjob-suspended`,
   `cronjob-guard`)
3. EVERY restic repository SHALL have its lifecycle rule (packs to Glacier
   Instant Retrieval). (`scripts/check-restic-repos.sh` in CI)
4. THE Immich library SHALL also go to a separate restic repository on the
   NAS. (CronJob `immich/immich-library-backup-local`)

### Requirement 2: Postgres to any point in 30 days

**User story:** As the operator, I want every database recoverable to a
recent point, not only to last night.

#### Acceptance criteria

1. EVERY CNPG Cluster SHALL archive WAL through the Barman Cloud plugin and
   have an unsuspended daily `ScheduledBackup` using it. (repo-policy
   `cnpg-backup`)
2. IF a backup fails, no base backup exists for 26 h, WAL archiving fails or
   lags, or the metrics vanish, THEN THE system SHALL page with
   `CNPGBackupFailed`, `CNPGBaseBackupTooOld`, `CNPGWALArchivingFailing`,
   `CNPGWALArchiveLag`, `CNPGBackupMetricsMissing` or `CNPGMetricsAbsent`.
   (`tests/prometheus/cnpg_backups_test.yaml`)
3. THE Renovate config SHALL hold CNPG Postgres majors until a bump also
   moves the plugin's `serverName`. (`.github/renovate.json5`)

### Requirement 3: A backup before every risky sync

**User story:** As the operator, I want a deploy that changes a database to
start from a fresh backup, without backing up on every sync.

#### Acceptance criteria

1. WHEN an app with a database syncs, ITS PreSync hook SHALL back up first,
   unless its last backup is fresh. (`components/presync-backup`,
   `presync-backup.sh`, `MAX_AGE_HOURS` 24)
2. WHEN the database image changes major version, or the app is `immich`,
   THE hook SHALL back up regardless of freshness. (`presync-backup.sh`)
3. IF the backup fails, THEN THE sync SHALL fail. (`presync-backup.sh`)

### Requirement 4: Restores are proven weekly

**User story:** As the operator, I want to know a backup restores before I
need it.

#### Acceptance criteria

1. THE `backup-verify` Application SHALL restore every restic tag (Saturday)
   and every CNPG cluster into a new cluster with row counts equal to the
   source (Sunday), and push results to its Pushgateway.
   (`platform/backup-verify/`, Homelab / Data protection)
2. THE monthly run SHALL read a rotating slice of every repository's packs.
   (`restic check --read-data-subset`,
   `platform/backup-verify/scripts/restic-data-targets.txt`)
3. IF a check fails, has not passed in 8 days, has never passed, or no pack
   read happened in 36 days, THEN THE system SHALL page with
   `BackupVerifyFailed`, `BackupVerifyStale`, `BackupVerifyMissing` or
   `BackupVerifyDataStale`. (`tests/prometheus/backup_verify_test.yaml`)

### Requirement 5: Backups survive a stolen key

**User story:** As the operator, I want no credential, admin included, able
to destroy old backup versions.

#### Acceptance criteria

1. THE bucket policy SHALL deny `s3:DeleteObjectVersion`,
   `s3:PutBucketVersioning` and `s3:DeleteBucket` to every principal.
   (repo-policy `backup-bucket-lock`; daily `tofu` plan for drift)
2. WEEKLY, THE CronJob `backup-verify-lock` SHALL attempt a version delete
   with a key IAM allows and expect the bucket policy to refuse it; IF it
   succeeds or the statement is gone, THEN `BackupLockBroken` SHALL page;
   no pass in 8 days pages `BackupLockCheckStale`.
   (`tests/prometheus/backup_verify_test.yaml`)
3. THE data PersistentVolumes SHALL use reclaim policy `Retain`; new data
   volumes use StorageClass `iscsi-retain`. (`kubectl get pv`, see
   [Reclaim policy](../../../docs/backups.md#reclaim-policy))
4. EVERY PVC SHALL carry `Delete=false,Prune=false`, and no leaf SHALL render
   the photo library PVC `immich/immich-data`. (repo-policy `pvc-sync-options`)
