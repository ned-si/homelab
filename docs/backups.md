# Backups

Two tiers with different threat models. What runs today: the restic file and
dump backups of every row in [Files](#files) except `grafana/data`, on the
[schedule](#schedule) below, against the S3 bucket and, for Immich, the NAS. What
does not run yet: barman for `immich-db` and `keycloak-db` (no object store on
either Cluster; the Barman Cloud plugin needs a CNPG upgrade first), and the
weekly verification in `platform/backup-verify/` (staged). Until then those two
databases are covered only by the on-demand [local dumps](#local-dumps-on-demand).

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
| `immich-db` | **not running**: barman → S3 is written (`apps/immich/resources/backup.yaml`) but not rendered | — | on-demand local dumps only |
| `keycloak-db` | **not running**: same (`platform/keycloak/backup.yaml`) | — | on-demand local dumps only |
| `mealie-postgresql` | **nightly `pg_dump`** into the `mealie/data` restic repo (03:20) | 3m + 12 monthly | consistent snapshot, **not** PITR |
| `sonarr-postgresql` | nightly `pg_dump` into `theater/configs` (03:40) | 3m + 12 monthly | consistent snapshot, **not** PITR |
| `radarr-postgresql` | same job | 3m + 12 monthly | same |
| `lidarr-postgresql` | same job | 3m + 12 monthly | same |
| `prowlarr-postgresql` | same job | 3m + 12 monthly | same |
| Paperless SQLite | file copy of `db.sqlite3` → `paperless/media` (02:30). The job would use `sqlite3 .backup`, but the restic image has no `sqlite3` | 3m + 24 monthly | **may be torn**; the job logs a warning every run |
| Seafile MariaDB | `mariadb-dump --single-transaction` → `seafile/shared` (03:00) | 3m + 24 monthly | transactionally consistent, no table locks |

**No CloudNativePG cluster has an object store.** barman archives nothing for any
of them. `mealie-postgresql` is the one that reads as covered and is not: it
declares `backup.retentionPolicy: 14d` with no destination underneath it, which is
not a configuration error — CNPG accepts it, it renders cleanly, it validates
against the CRD schema, and it archives nothing. That is why the logical dumps
exist.

The consequence is stated rather than implied: the five dumped clusters get
point-in-time **snapshots**, not point-in-time **recovery**. Worst case is a day of
recipes or a day of quality-profile edits. Adding `barmanObjectStore` to a
`Cluster` is a separate edit in that app's manifest, and doing it makes the
corresponding dump redundant rather than wrong.

### Files

One restic repository per row, all with `--tag` names the verifier consumes.

| Repository | Contents | Retention | Caveats |
|---|---|---|---|
| `immich/library` | the photos. **Irreplaceable** | 3m + 12 monthly | excludes `.tmp`, `encoded-video`, `thumbs` — all regenerated |
| `immich/library` *(local, on NFS)* | second, independent repository of the same source | 14d/8w/6m, pruned nightly | this is the copy that gets the full `--read-data` check |
| `paperless/media` | scanned originals + the SQLite database | 3m + 24 monthly | excludes the search index and thumbnails (derived); `paperless-consume` is a drop-box and is not backed up |
| `seafile/shared` | content-addressed blobs **and** the MariaDB dump **and** Seafile's in-volume configuration | 3m + 24 monthly | see below — this is the only copy of `seahub_settings.py` anywhere |
| `syncthing/data` | `cert.pem`, `key.pem`, `config.xml` | 3m + 24 monthly | the file index is **deliberately excluded**; see below |
| `theater/configs` | six `/config` volumes + four Postgres dumps, one repo, tagged per app | 3m + 12 monthly | Plex and Jellyfin have caveats; see below. bazarr's job is added with bazarr |
| `mealie/data` | uploaded recipe images + the Postgres dump | 3m + 12 monthly | write-once files; consistent |
| `grafana/data` | Grafana's config and, separately, its live SQLite | 7d/4w/6m | **not running**: Grafana has no persistent volume today, so there is nothing to back up; see below |

### Retention

"3m + 12 monthly" means every snapshot is kept for three months, then one per
month until it is twelve months old (`restic forget --keep-within 3m
--keep-monthly 12`). Retention is in months because of the storage class: pack
files move to Glacier Instant Retrieval after a day, and Glacier IR bills every
object for at least 90 days. Deleting a pack sooner saves nothing and is billed
anyway. Keeping everything for three months means no pack becomes unused before
it is 90 days old.

So the nightly jobs only add snapshots and run `restic check`. Each S3 repository
has its own `*-prune` CronJob that runs `forget --prune` and a check **once a
month**, on the 1st, away from the nightly window. The local Immich repository is
on the NAS, has no minimum storage duration, and keeps its nightly forget + prune.

### Schedule

Every job has `concurrencyPolicy: Forbid`: a run that is still going when the next
one is due causes that next one to be skipped, never run beside it. The cluster's
CronJobs use the controller's time zone, UTC. One start per slot, so jobs never
pile up on the uplink or the NAS:

| UTC | Job |
|---|---|
| 01:30 | `immich/immich-library-backup-local` (NFS) |
| 02:00 | `syncthing/syncthing-backup` |
| 02:30 | `paperless/paperless-backup` |
| 03:00 | `seafile/seafile-backup` |
| 03:20 | `mealie/mealie-backup` |
| 03:30 | `immich/immich-library-backup` (S3) |
| 03:40 | `theater/theater-postgres-backup` |
| 04:00–04:40 | `theater/theater-config-backup-{sonarr,radarr,lidarr,prowlarr,plex}`, ten minutes apart |
| 05:00 | `theater/theater-config-backup-jellyfin` |
| 1st, 12:00–13:30 | `*-prune`: syncthing 12:00, mealie 12:15, paperless 12:30, seafile 12:45, theater 13:00, immich 13:30 |

Within `theater/configs`, six jobs share one repository and restic takes an
exclusive lock for `backup`, so they run ten minutes apart; 04:50 is kept for
bazarr. The running set is listed in `ci/active-cronjobs.txt`; CI fails any other
rendered CronJob that is not suspended.

### The consistency caveats, per tag

The reason these are spelled out per tag rather than asserted in general is that
the difference between a backup and a wishful file copy lives here.

**Consistent.** `pg_dump` in a single transaction. `mariadb-dump
--single-transaction`. Content-addressed
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

**Not consistent.** Paperless' SQLite is copied as a file while Paperless runs
(the restic image has no `sqlite3` for `.backup`), so a copy taken mid-write can
be torn; the job logs a warning every run, and the on-demand local dump uses
SQLite's backup API. Two more are deliberate, each split into its own snapshot
with a distinct tag so a restore cannot mistake one guarantee for the other.

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
back up, scale back — cannot work here. Every Application except `immich` runs
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

## Reclaim policy

A PersistentVolume's reclaim policy decides what happens on the NAS when its
claim is deleted: `Delete` destroys the iSCSI volume, `Retain` keeps it (the PV
goes to `Released` and can be re-bound by hand).

| What | Policy | Where it is set |
|---|---|---|
| StorageClass `iscsi` (default) | `Delete` for new volumes | democratic-csi (`infrastructure/democratic-csi/values-iscsi.yaml`). A StorageClass's `reclaimPolicy` is immutable, so it stays. |
| StorageClass `iscsi-retain` | `Retain` for new volumes | `infrastructure/democratic-csi/values-iscsi.yaml`. Use it for every new data volume. |
| Every existing data PV on `iscsi` (including `immich-data` and every CNPG volume) | `Retain` | On each PV (`spec.persistentVolumeReclaimPolicy`), not in git |
| `immich-machine-learning-cache`, `jellyfin-cache`, `plex-transcode` | `Delete` | Regenerable caches, on purpose |

Existing claims keep `storageClassName: iscsi`: a PVC's class is immutable, and
changing it would mean a new volume and a data copy. PVs are provisioned objects,
so their policy is not in git; check it after any restore or rebuild:

```sh
kubectl get pv -o custom-columns=CLAIM:.spec.claimRef.name,POLICY:.spec.persistentVolumeReclaimPolicy,SC:.spec.storageClassName
```

Expected: `Retain` on every line except the three caches. Fix a data volume on
`Delete` with
`kubectl patch pv <pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`.

In the layered tree every PVC, CNPG Cluster, StatefulSet and Namespace also
carries `argocd.argoproj.io/sync-options: Delete=false,Prune=false`, so Argo CD
never deletes one, even when its manifest disappears from git.

## What is deliberately not backed up

**The media library** — 26TB NFS, 9.5TB used. Roughly €50–120/month growing, and a
restore would mean egressing all of it, for content that is by its nature
re-acquirable.

What protects it instead: ZFS snapshots on the NAS, and an NFS share that no
Kubernetes object can delete (the theater workloads mount it inline). Today
Plex and Jellyfin mount it read-write, as they always have; mounting it
`readOnly: true` for the two media servers, and moving the mounts to the
`nfs-storage` leaf (`Retain` PVs, written but not enabled), are listed in
[docs/roadmap.md](roadmap.md).

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

**etcd** is not covered by any of the above. Take a snapshot by hand before
every Kubernetes upgrade or risky change, with the procedure in
[runbooks/cold-start.md](runbooks/cold-start.md#etcd-snapshot-and-restore): it
keeps one copy in `/root/etcd-snapshots/` on `homelab-cp-1` and one in
`~/homelab-backups/etcd/` on the Mac. The snapshot task in
`ansible/kube-upgrade.yml` calls `etcdctl` on the host, and the hosts have none
(it lives in the etcd container), so do not rely on it.

## Setting it up from scratch

An ordered checklist for a new bucket or a rebuilt cluster. Nothing works until
all of it is done, and two of the steps are silently expensive if skipped.

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

3. **Keep `local.restic_repos` in `bootstrap/aws-backup/main.tf` equal to the
   repositories in the manifests, BEFORE applying.** It lists all seven today;
   `scripts/check-restic-repos.sh` fails when the two drift.

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

6. **Check every data PV is `Retain`** ([Reclaim policy](#reclaim-policy)). On
   a rebuilt cluster, new volumes on `iscsi` start as `Delete`.

7. **Seed each new restic repository once, by hand, before the first verification
   run.** Step 2 of `verify-files.sh` fails with `no snapshot found for tag` against
   a repository that has never been written, so the first Sunday after this lands
   is *expected* to report failures — and it is important not to read that as "the
   new jobs are broken".

   ```sh
   kubectl -n syncthing create job --from=cronjob/syncthing-backup seed
   kubectl -n mealie    create job --from=cronjob/mealie-backup    seed
   kubectl -n seafile   create job --from=cronjob/seafile-backup   seed
   kubectl -n theater   create job --from=cronjob/theater-postgres-backup seed
   # ...and each of the six theater config jobs
   ```

   On a running cluster the CronJobs are active (`ci/active-cronjobs.txt`), so
   anything not seeded by hand is seeded by its first scheduled run.

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
verified with a server-side dry-run, not assumed. Enabling it comes right after
the CNPG upgrade on the [roadmap](roadmap.md).

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

Not running yet: `clusters/homelab/staged/backup-verify.yaml` is in no layer.
Once enabled, `platform/backup-verify/` runs weekly and never touches anything
live.

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

This needs the `VolumeSnapshot` CRDs, a snapshot controller and the `iscsi`
VolumeSnapshotClass from democratic-csi. Today the controller is an unmanaged
`kube-system/snapshot-controller` v6.3.1; `infrastructure/snapshot-controller/`
is written to replace it and not enabled. Check before relying on a snapshot:

```sh
kubectl get volumesnapshotclass
```

Expected: `iscsi`, driver `org.democratic-csi.iscsi`.

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

Once barman archives a cluster (none does yet), create a **new** cluster that
recovers from the object store. Never restore over a live one. Until then,
restore from a dump: `task backup:verify-restore` above is the tested path into
a throwaway cluster, and the nightly dumps are in the restic repositories listed
at the end of this section.

**Get the image from the source cluster, do not copy it from here.** `immich-db`
runs `cloudnative-pgvecto.rs:16.5-v0.3.0` (PostgreSQL 16 with pgvecto.rs) until
[runbooks/immich-upgrade.md](runbooks/immich-upgrade.md) moves it to VectorChord
on PostgreSQL 17. A backup restores only into the image it was taken from: same
major version, same vector extension.

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
  storage: { size: 20Gi, storageClass: iscsi-retain }
  bootstrap:
    recovery:
      source: src
      recoveryTarget:
        targetTime: "<YYYY-MM-DD HH:MM:SS+02>"   # omit for latest
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
- **No full-restore drill has ever been run.** The weekly sample, once enabled, is
  a good proxy.
- **`immich-db` and `keycloak-db` have no off-site copy.** Only the on-demand local
  dumps cover them until barman runs.

## Why it is like this

- Restic CronJobs are suspended unless listed in `ci/active-cronjobs.txt`
  (cited as ADR 0008 in code comments): a backup job is only switched on once
  its credentials are real and its first run has been seen to work. Every other
  CronJob ships suspended behind a `pending-guard` init container, so a
  placeholder bucket can never look like a working backup.
- `Retain` on data PVs plus `iscsi-retain` for new ones, rather than changing
  `iscsi`: a StorageClass's reclaim policy is immutable, and changing an
  existing claim's class means copying its data.
- Retention in months and Glacier Instant Retrieval, not Deep Archive: Glacier IR
  bills 90 days per object anyway, and restic cannot thaw Deep Archive, so
  `restic check --read-data` and every restore would become a manual workflow.
- Versioning plus an IAM `Deny`, not S3 Object Lock: Object Lock cannot be
  turned off, and the owner may need to fix their own mistakes.
- In-tree `barmanObjectStore` first, the Barman Cloud plugin later: the running
  CloudNativePG 1.24.1 rejects the plugin fields.
