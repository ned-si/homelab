# Backups

Two tiers with different threat models, and one thing to understand before reading
the table: **none of this is running yet.** The manifests are written; the S3
bucket, the `s3-backup` Secret and several OpenTofu entries do not exist. Until the
[prerequisites](#before-any-of-this-works) are done there is no backup at all.

| Tier | Where | Protects against | Verification |
|---|---|---|---|
| **Local** | TrueNAS, `homelab/k8s/backups` dataset | a bad upgrade, a bad migration, an app rewriting its own data, a mistaken delete | expensive — reads are free on the LAN |
| **Remote** | one S3 bucket, `eu-central-1` | fire, theft, the NAS dying, ransomware | cheap checks, often |

The local tier sits on the same ZFS pool as the data it backs up, so losing the
pool loses both. It is not disaster protection; that is what S3 is for. Only the
Immich library currently has a local copy.

**Local verification does not verify the remote copy.** They are different artifacts
from different code paths, and the classic failure is a remote backup silently
broken for months while the local one looks perfect.

## Coverage

Derived from the manifests. Where a row says a caveat, the caveat is the point —
do not read this table as "everything is backed up".

### Databases

| Cluster | Method | Retention | Consistency |
|---|---|---|---|
| `immich-db` | barman in-tree → S3: continuous WAL + nightly base (02:30) | 30d PITR | full PITR |
| `keycloak-db` | barman in-tree → S3: continuous WAL + nightly base (02:00) | 90d PITR | full PITR |
| `mealie-postgresql` | **nightly `pg_dump`** into the `mealie/data` restic repo (03:20) | 14d/8w/12m | consistent snapshot, **not** PITR |
| `sonarr-postgresql` | nightly `pg_dump` into `theater/configs` (03:40) | 14d/8w/12m | consistent snapshot, **not** PITR |
| `radarr-postgresql` | same job | 14d/8w/12m | same |
| `lidarr-postgresql` | same job | 14d/8w/12m | same |
| `prowlarr-postgresql` | same job | 14d/8w/12m | same |
| Paperless SQLite | `sqlite3 .backup` via Python → `paperless/media` (04:00) | 14d/8w/24m | consistent — uses SQLite's online backup API |
| Seafile MariaDB | `mariadb-dump --single-transaction` → `seafile/shared` (03:00) | 14d/8w/24m | transactionally consistent, no table locks |

**Only two of the seven CloudNativePG clusters have `spec.backup.barmanObjectStore`
at all.** `mealie`, `sonarr`, `radarr`, `lidarr` and `prowlarr` have no object
store, so barman archives nothing for them. `mealie-postgresql` is the one that
reads as covered and is not: it declares `backup.retentionPolicy: 14d` with no
destination underneath it, which is not a configuration error — CNPG accepts it, it
renders cleanly, it validates against the CRD schema, and it archives nothing. That
is why the logical dumps exist.

The consequence is stated rather than implied: those five get point-in-time
**snapshots**, not point-in-time **recovery**. Worst case is a day of recipes or a
day of quality-profile edits. Adding `barmanObjectStore` to a `Cluster` is a
separate edit in that app's manifest, and doing it makes the corresponding dump
redundant rather than wrong.

### Files

One restic repository per row, all with `--tag` names the verifier consumes.

| Repository | Contents | Retention | Caveats |
|---|---|---|---|
| `immich/library` | the photos. **Irreplaceable** | 7d/5w/12m | excludes `.tmp`, `encoded-video`, `thumbs` — all regenerated |
| `immich/library` *(local, on NFS)* | second, independent repository of the same source | 14d/8w/6m | this is the copy that gets the full `--read-data` check |
| `paperless/media` | scanned originals + the SQLite database | 14d/8w/24m | excludes the search index and thumbnails (derived); `paperless-consume` is a drop-box and is not backed up |
| `seafile/shared` | content-addressed blobs **and** the MariaDB dump **and** Seafile's in-volume configuration | 14d/8w/24m | see below — this is the only copy of `seahub_settings.py` anywhere |
| `syncthing/data` | `cert.pem`, `key.pem`, `config.xml` | 30d/12w/24m | the file index is **deliberately excluded**; see below |
| `theater/configs` | six `/config` volumes + four Postgres dumps, one repo, tagged per app | 14d/8w/12m | Plex and Jellyfin have caveats; see below |
| `mealie/data` | uploaded recipe images + the Postgres dump | 14d/8w/12m | write-once files; consistent |
| `grafana/data` | Grafana's config and, separately, its live SQLite | 7d/4w/6m | **best-effort on the database**; see below |

Schedules are staggered. Within `theater/configs`, six jobs share one repository
and restic takes an exclusive lock for `backup`, so they run ten minutes apart and
`forget --prune` runs **once**, from the last job of the night.

### The consistency caveats, per tag

The reason these are spelled out per tag rather than asserted in general is that
the difference between a backup and a wishful file copy lives here.

**Consistent.** `pg_dump` in a single transaction. `mariadb-dump
--single-transaction`. Paperless' SQLite via `.backup`. Content-addressed
write-once blobs (Seafile storage, Immich library, Mealie uploads) — a file is
written once under the hash of its contents and never modified, so a live copy
cannot be torn; worst case is catching an upload in flight, which restic picks up
correctly on the next run. XML configuration written to a temp file and renamed
(the *arr `config.xml`, Jellyfin's `config/`).

**Consistent because the inconsistent part is excluded.**

- **Syncthing.** The volume holds two categories with completely different value.
  Irreplaceable and tiny: `cert.pem` and `key.pem` — the device identity, whose
  fingerprint *is* the device ID, so losing it makes this a new device that every
  peer must re-accept by hand — plus `config.xml`, which holds folder definitions,
  peer device IDs, share permissions and the File Versioning settings. Rebuildable
  and large: the file index, which Syncthing regenerates by rescanning. Excluding
  the index is not a compromise, it is the better backup: the index is the only
  live database in the volume, so excluding it removes the entire consistency
  problem and leaves a fully consistent backup of a few kilobytes.
- **Plex.** The live SQLite databases are excluded and Plex's own scheduled
  database backups are included instead. `Metadata/`, `Media/` and `Cache/` are
  excluded too — posters, fanart and analysis, nearly all of the ~20GB, all
  regenerated. `Preferences.xml` is included and is easy to overlook: it holds the
  server's machine identity and its Plex account token.
- **The *arr apps.** With `*__POSTGRES__*` set, the real database is in Postgres.
  `/config` holds `config.xml`, the app's own `Backups/` zips and the ASP.NET
  data-protection keys. `logs.db` and `MediaCover/` are excluded.

**Not consistent, and tagged so.** Two, both deliberate, both split into their own
snapshot with a distinct tag so a restore cannot mistake one guarantee for the
other.

- **`jellyfin-db-besteffort`** — `/config/data/jellyfin.db` and `library.db`, live
  SQLite, possibly torn. The `-wal`/`-shm` files are included because SQLite needs
  them to recover the database on open; taking the `.db` alone would silently
  discard committed transactions. It still is not atomic across the three files,
  which is what the tag admits. What is at risk: user accounts, watch state and
  playback positions. Not the media, not the server settings. `jellyfin-config`
  is a separate, consistent snapshot.
- **`grafana-db-besteffort`** — `grafana.db`, same problem. The exposure is small
  because almost nothing important lives there: dashboards and datasources are
  provisioned from ConfigMaps, and users come from Keycloak. What is at risk is
  hand-made dashboards, stars, preferences and Grafana-defined alert rules — an
  evening, not data.

**Why nothing quiesces first.** The obvious answer — scale the Deployment to 0,
back up, scale back — cannot work here. Every Application in `clusters/` runs
`selfHeal: true`, so Argo CD reverts `replicas: 0` within seconds, restarting the
app mid-backup and contending for the `ReadWriteOnce` volume the backup pod now
holds. Quiescing anything Argo manages means suspending the Application first,
which a CronJob has no business doing. That applies equally to Plex, Jellyfin,
Seafile, Syncthing and Grafana, which is why none of their jobs try.

The correct fix for the two best-effort tags is snapshot-then-backup, via VolSync or
the CSI `VolumeSnapshot` machinery. It is not hand-rolled here, and the reasons —
including why a single Job structurally cannot do it — are argued in the header of
`platform/kube-prometheus-stack/routes/grafana-backup.yaml`. Build it the day Plex's
watch history matters.

**Seafile needs both halves or neither is worth anything.** The blobs are
SHA-named files with no index; the MariaDB dump is the index — which blob is which
file, which library, which version, who owns it, who it is shared with. One CronJob
takes both, database **first** and blobs second: a file uploaded between the two
appears as an orphan blob, which wastes space and nothing else, whereas the reverse
order gives a database row pointing at a blob that was never captured. That
ordering is why the dump is an `initContainer` and not a sidecar.

## What is deliberately not backed up

**The media library** — 26TB NFS, 9.5TB used. Roughly €50–120/month growing, and a
restore would mean egressing all of it, for content that is by its nature
re-acquirable.

What protects it instead, verified against the manifests rather than taken on
trust: ZFS snapshots on the NAS, `persistentVolumeReclaimPolicy: Retain` on the PV
so no Kubernetes action can delete it, and Plex and Jellyfin both mounting it
`readOnly: true` with `subPath: media` so neither media server can write to it.

If you disagree, the change is a copy of
`apps/immich/resources/backup-files.yaml` pointed at the `theater-data` PVC. The
honest off-site alternatives are a second NAS elsewhere doing `zfs send`, or
accepting the loss.

**`qbittorrent-config`** — torrent state and resume data. Reconstructible, and it
references media that is itself not backed up. Note it is also the volume whose
stale `ipc-socket` caused a three-month outage
([runbook](runbooks/arr-qbittorrent.md)), so a restored copy could restore the
fault.

**`paperless-consume`, `plex-transcode`, `jellyfin-cache`** — drop-boxes and
scratch, transient by definition.

**Synced data in Syncthing.** Syncthing is a replication tool: every peer holds a
full copy, so the data has as many copies as there are devices. What it does not
protect against is a deletion propagating to every peer, which is what Syncthing's
own File Versioning is for — configured per folder in the GUI, stored in
`config.xml`, i.e. inside the backup.

**etcd** is not covered by any of the above. `ansible/kube-upgrade.yml` snapshots
it before an upgrade, onto the node. Copy it off if you want it to survive losing
that node.

## Before any of this works

An ordered checklist. Nothing runs until all of it is done, and two of the steps
are silently expensive if skipped.

1. **`task secrets:keygen`**, and back the private key up. Nothing in the repo can
   be encrypted before this.

2. **Create the bucket and the scoped credentials.** OpenTofu does all the AWS
   work except one temporary admin key.

   ```sh
   cd bootstrap/aws-backup
   cp terraform.tfvars.example terraform.tfvars
   $EDITOR terraform.tfvars          # bucket_name must be globally unique
   tofu init && tofu plan            # read it
   tofu apply
   tofu output next_steps
   ```

   Use an admin IAM user, not root credentials: root cannot be scoped, so a leaked
   backup key could delete the backups *and* everything else in the account. Delete
   the admin key once this succeeds.

3. **Extend `local.restic_repos` in `bootstrap/aws-backup/main.tf` from 2 to 7,
   BEFORE applying.** It currently lists only `immich/library` and
   `paperless/media`. The five missing entries are `seafile/shared`,
   `syncthing/data`, `theater/configs`, `mealie/data` and `grafana/data`.

   S3 prefix filters are literal, with no wildcards, so `main.tf` generates one
   Glacier IR lifecycle rule per repository from that list. A repository not on the
   list has no rule, so its pack files sit in S3 Standard at roughly **6× the
   price**, and nothing warns you. `theater/configs` is deliberately one repository
   for six apps, so it needs one entry, not six.

4. **Seal the `s3-backup` Secret**, with a **byte-identical `RESTIC_PASSWORD` in
   every namespace it appears in.** It defines the same Secret in seven namespaces,
   because Kubernetes Secrets are namespaced and there is no built-in replication —
   and a repository written with one password cannot be read with another. Both key
   spellings are present (`ACCESS_KEY_ID` for barman, `AWS_ACCESS_KEY_ID` for
   restic) because the two tools disagree and neither is configurable.

   ```sh
   cp platform/secrets/s3-backup.sops.yaml.example platform/secrets/s3-backup.sops.yaml
   $EDITOR platform/secrets/s3-backup.sops.yaml
   task secrets:seal -- platform/secrets/s3-backup.sops.yaml
   task secrets:leak-check
   ```

   `RESTIC_PASSWORD` is not recoverable. Lose it and every file backup is
   permanently unreadable, including by you. Store it beside the age key.

5. **Point the manifests at the real bucket.** This is what clears the
   `homelab-backups-REPLACE-ME` placeholders that `scripts/placeholder-check.sh`
   allowlists with a reason:

   ```sh
   task backup:set-target -- <bucket-name> eu-central-1
   ```

   It re-renders `deploy/` as part of the same command.

6. **Patch the existing PVs to `Retain`.** Every volume in the cluster was
   `Delete`, including the Immich library — and the Immich upgrade runbook contains
   a step that deletes a PVC. The `iscsi-retain` StorageClass stops new ones
   repeating it; existing volumes have to be patched in place.

7. **Seed each new restic repository once, by hand, before the first verification
   run.** Step 2 of `verify-files.sh` fails with `no snapshot found for tag` against
   a repository that has never been written, so the first Sunday after this lands
   is *expected* to report failures — and it is important not to read that as "the
   new jobs are broken".

   ```sh
   kubectl -n syncthing create job --from=cronjob/syncthing-backup seed
   kubectl -n mealie    create job --from=cronjob/mealie-backup    seed
   kubectl -n seafile   create job --from=cronjob/seafile-backup   seed
   kubectl -n monitoring create job --from=cronjob/grafana-backup  seed
   kubectl -n theater   create job --from=cronjob/theater-postgres-backup seed
   # ...and each of the six theater config jobs
   ```

   Immich is the exception worth planning: the first upload is hundreds of GB over
   a domestic uplink. Start the **local** repository first — it is fast and it is
   the copy that gets fully verified — then the remote one, both by hand rather
   than letting a CronJob begin it at 03:30 and hit its deadline.

   ```sh
   kubectl -n immich create job --from=cronjob/immich-library-backup-local seed-local
   kubectl -n immich create job --from=cronjob/immich-library-backup       seed-remote
   ```

8. **Prove it.** `kubectl -n backup-verify create job
   --from=cronjob/backup-verify-files now`, and read the log.

Also on the list, and separate from the above: the **Barman Cloud plugin** is
written and ready in `platform/barman-cloud-plugin/` but deliberately **not
referenced** by the platform kustomization, because CNPG 1.24.1 does not have the
plugin CRD and its `Cluster` schema rejects `spec.plugins[0].isWALArchiver`. That is
verified with a server-side dry-run, not assumed. Enabling it is a step immediately
after the CNPG upgrade — see [migration-plan.md](./migration-plan.md).

## The bucket

One bucket, `eu-central-1`, from
[`bootstrap/aws-backup/`](../bootstrap/aws-backup/main.tf). One bucket rather than
several, because the two kinds of backup want opposite things from S3 and the
difference is per-**prefix**:

| Prefix | Contents | Storage class | Why |
|---|---|---|---|
| `*/postgres/` | barman: WAL + base backups | Standard | churn of small objects, 30–90d retention. Any archive class bills a 90-day minimum anyway |
| `*/data/` | restic pack files | Glacier IR after 1 day | the bulk. Write-once, read-almost-never |
| everything else | restic `config`, `keys/`, `index/`, `snapshots/` | **Standard** | read on *every* restic operation |

That last row is the most common way people break restic on Glacier. restic has no
concept of thawing — it expects every `GET` to succeed, so an archived index makes
the repository unusable. Upstream is explicit that a lifecycle policy must apply
[only to the `data/` prefix](https://forum.restic.net/t/unavailable-index-files/1326/7).

Glacier **Instant** Retrieval, not Deep Archive: Deep Archive is ~4× cheaper again
but reads need an asynchronous thaw taking hours, which restic cannot do, so
`restic check --read-data` and any real restore would need a workflow you have to
build and then remember exists. The premium buys the ability to *test the backup*.
Per TB per month, order of magnitude: Standard ~$23 storage / free retrieval,
Glacier IR ~$4 / ~$30, and internet egress ~$90 either way. **Storage is cheap,
egress is not, and S3 → EC2 in the same region is free** — which is the whole shape
of the verification design below.

### What the credentials can and cannot do

Two IAM users, both scoped to this bucket only. `…-writer` can put, get and delete,
because restic prunes and barman enforces retention. `…-verifier` is read-only plus
restic's lock prefix, so a drill gone wrong cannot damage the backup it is testing.

The writer carries an explicit `Deny` on `s3:DeleteObjectVersion`,
`s3:PutBucketVersioning`, `s3:PutLifecycleConfiguration` and `s3:DeleteBucket`.
Combined with versioning, **the backup credential cannot make a deletion
permanent**: `DeleteObject` only writes a delete marker and the previous version
survives 30 days. Deny beats Allow in IAM unconditionally, so this holds even if a
broader policy is attached later.

Deliberately not S3 Object Lock, which is stronger but must be enabled at bucket
creation and cannot be turned off. For a homelab where you may want to fix your own
mistakes, versioning plus a deny is the better trade.

All four access keys go to Bitwarden, and note that
`bootstrap/aws-backup/terraform.tfstate` now contains the secret keys — git-ignored,
but treat it as a secret and move it off this machine.

## Verification

`platform/backup-verify/` runs weekly and never touches anything live.

**Postgres, Sunday 05:00.** Builds a throwaway CNPG cluster in the `backup-verify`
namespace by recovery from S3, asserts the server answers queries, that the schema
has at least *N* tables (an **empty** restore is the classic silent failure, where
the restore "succeeds" with no data), that every relation is readable, and prints
the extension list — Immich will not boot without its vector extension. Then deletes
the cluster.

It cannot damage anything, for two independent reasons: its RBAC is a `Role` in its
own namespace, so it cannot reach `immich` or `keycloak` at all; and the restored
cluster declares no `spec.backup`, so it physically cannot write into the object
store it read from.

**Files, Sunday 07:00.** Per repository: `restic check`; the newest snapshot is less
than 3 days old, which catches a CronJob failing silently; **a sample of real files
is restored** and asserted non-empty; and `--read-data-subset=n/52` reads a
different fifty-second of the packs each week.

The sample restore is the one that matters — `restic check` validates metadata, it
does not prove the blobs are retrievable. The rotating subset is what makes this
more than a spot check: over a year every byte has been read back at least once,
while any single run pays retrieval on ~2% of the repository.

### The annual drill

Everything above is weekly and costs a few dollars a month, because it is metadata
plus ~2% of the packs. Reading *everything* is the check that actually proves the
backup, and it is affordable exactly once a year, in the right place: the expensive
thing is egress, not reading, and S3 → EC2 in the same region has no egress.

Use the **read-only verifier** credential:

```sh
# a small spot instance in the bucket's own region
export AWS_ACCESS_KEY_ID=...        # tofu output -raw verify_access_key_id
export AWS_SECRET_ACCESS_KEY=...    # tofu output -raw verify_secret_access_key
export RESTIC_REPOSITORY="s3:s3.eu-central-1.amazonaws.com/<bucket>/immich/library"
export RESTIC_PASSWORD=...

restic check --read-data          # reads every pack. This is the real check.
restic restore latest --target /mnt/scratch
```

**Terminate the instance** — an idle one costs more over a year than the drill did.
And do not restore the whole library to the house "just to check": that is the
expensive mistake, and it teaches you nothing the tiers above do not.

The full read of the **local** Immich repository is free, so it runs weekly against
that copy. It is a genuinely independent repository, not a copy of the S3 one, so
corruption or a bad `forget` in one cannot propagate to the other.

### Alerting

`platform/backup-verify/alerts.yaml` fires on: `BackupVerificationFailed`,
`BackupVerificationStale` (no success in 14 days), `PostgresBackupFailed`,
`PostgresBackupStale` (no base backup in 36h, i.e. two consecutive failures),
`PostgresWALArchiveFailing`, `FileBackupJobFailed`.

`PostgresWALArchiveFailing` is the urgent one: unarchivable WAL accumulates locally
and can take the database down on its own. `PersistentVolumeFillingUp` on a
Postgres data volume is usually this, not a capacity problem.

Note that a cluster with no `barmanObjectStore` publishes no backup timestamp at
all, so it cannot go stale — it is simply absent. `PostgresBackupMetricsAbsent`
covers the exporter disappearing; the five clusters with no object store are a known
gap, not an alert. How notifications reach you: [observability.md](observability.md).

### When verification fails

1. **Do not ignore it.** This alert exists because the alternative is discovering
   the problem when you need the backup.
2. `kubectl -n backup-verify logs job/<name>`.
3. Causes, in order of likelihood: S3 credentials rotated; a repository seeded but
   never written since; lifecycle rules deleting objects the retention policy still
   expects; the backup CronJob failing (check `PostgresBackupStale` too); genuine
   corruption — restore the previous snapshot and investigate.
4. Fix, then re-run the verification by hand before considering it closed.

## Before a risky change

```sh
scripts/pre-upgrade-snapshot.sh immich-v3       # dumps + snapshots, tagged
# ... do the upgrade, live with it for a bit ...
scripts/pre-upgrade-snapshot.sh --delete immich-v3
```

A `VolumeSnapshot` on ZFS is copy-on-write, so snapshotting the library is instant
and initially free — only diverging blocks cost anything. Copying it before every
upgrade would take hours and you would stop doing it.

Rollback is deliberately **not** automated: it destroys the current state, so the
script prints the exact commands instead of offering a flag.

This depends on `infrastructure/snapshot-controller/`, which ships the
`VolumeSnapshot` CRDs. Without them the `VolumeSnapshotClass` democratic-csi's chart
declares is never created — `kubectl get volumesnapshotclass` reports no such
resource type — so snapshots look configured and do not exist. Check for the class
before relying on a snapshot.

## Local dumps, on demand

```sh
task backup:dump      # -> ~/homelab-backups/<utc>/  (all 9 databases, verified)

task backup:verify-restore -- immich immich-db \
  ~/homelab-backups/<utc>/pg-immich-immich-db.dump
```

`backup:dump` dumps every database — seven Postgres clusters, Seafile's MariaDB,
Paperless' SQLite — to local disk and verifies each one, including a **sha256 taken
at the source** and compared locally: `pg_dump`'s custom format has no internal
checksums, so nothing else finds a flipped byte. It exits non-zero on any failure
and never writes to the cluster. The full list of checks and what each catches is in
the header of `scripts/dump-databases.sh`.

`backup:verify-restore` builds a throwaway CNPG cluster in its own namespace,
restores into it, and compares against the live database: table count, row counts on
the eight largest tables, every relation readable, and the extension set. Then
deletes it. It derives the target image and `shared_preload_libraries` from the
**source** cluster rather than guessing, which is what makes it work for Immich.

**These dumps are on one machine.** Point-in-time snapshots, not PITR, and not
off-site until you copy them somewhere else.

## Restoring

### Postgres, to a point in time

Create a **new** cluster that recovers from the object store. Never restore over a
live one.

**Get the image from the source cluster, do not copy it from here.** This is the one
place where the live cluster and this branch disagree, and it matters: the live
`immich-db` runs `cloudnative-pgvecto.rs:16.5-v0.3.0` on **PostgreSQL 16**, while
this branch declares `cloudnative-vectorchord:17-1.1.0` on **PostgreSQL 17**. A dump
or a barman backup taken from the live cluster will not restore against the branch's
image — different major version and a different vector extension. Which one you need
depends entirely on when the backup was taken, relative to
[runbooks/immich-upgrade.md](runbooks/immich-upgrade.md).

```sh
kubectl -n immich get cluster immich-db -o jsonpath='{.spec.imageName}'
```

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: immich-db-restored
  namespace: immich
spec:
  instances: 1
  # From the command above. NOT from this document.
  imageName: <the source cluster's image>
  storage: { size: 20Gi, storageClass: iscsi }
  bootstrap:
    recovery:
      source: src
      recoveryTarget:
        targetTime: "2026-07-30 14:32:00+02"   # omit for latest
  externalClusters:
    - name: src
      barmanObjectStore:
        # `serverName` selects which backup inside destinationPath to read.
        # It is the SOURCE cluster's name, not this one's.
        destinationPath: s3://<bucket>/immich/postgres
        endpointURL: https://s3.eu-central-1.amazonaws.com
        serverName: immich-db
        s3Credentials:
          accessKeyId: { name: s3-backup, key: ACCESS_KEY_ID }
          secretAccessKey: { name: s3-backup, key: ACCESS_SECRET_KEY }
```

Verify it, then repoint the app at `immich-db-restored-rw`. The restored cluster has
no `spec.backup`, so it does **not** archive WAL — add that block once you promote
it, or the new primary has no backups at all.

For the five clusters with no object store there is no PITR path. Restore their
nightly dump from the corresponding restic repository instead: `pg-mealie` in
`mealie/data`, `theater-postgres` in `theater/configs`.

### Files

```sh
kubectl -n immich run restic-restore --rm -it --restart=Never \
  --image=restic/restic:0.19.0 \
  --overrides='{"spec":{"containers":[{"name":"r","image":"restic/restic:0.19.0",
    "command":["sh"],"stdin":true,"tty":true,
    "envFrom":[{"secretRef":{"name":"s3-backup"}}],
    "env":[{"name":"RESTIC_REPOSITORY","value":"s3:https://s3.eu-central-1.amazonaws.com/<bucket>/immich/library"}]}]}}'

# then inside:
restic snapshots                       # --tag to narrow, e.g. --tag jellyfin-config
restic restore latest --target /restore --include /data/library/user/2024
```

**Check the tag before you trust a snapshot.** `theater/configs` holds six apps'
snapshots in one repository, and `jellyfin-db-besteffort` and `grafana-db-besteffort`
carry a weaker guarantee than everything beside them — that is what the tag is for.

Restore into a **scratch** location and copy across deliberately. Restoring straight
over a live library is how a bad restore becomes a real outage.

## Known gaps

- **The Postgres verifier's list includes three clusters with no object store**
  (`mealie-postgresql`, `sonarr-postgresql`, `radarr-postgresql`), so the weekly
  drill fails on them until either the `barmanObjectStore` blocks are added or those
  lines are removed. A check that always fails is a check you learn to ignore.
- **`grafana/data` is not in the file verifier's list.** It is a real repository
  and nothing checks it.
- **No off-site copy of the media library.** Deliberate, argued above.
- **Restore *time* is not tested.** Verification proves data is retrievable, not
  that a full multi-TB restore completes in a useful window. It would not.
- **No full-restore drill has ever been run.** The weekly sample is a good proxy.
