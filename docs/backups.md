# Backups

Everything goes to S3-compatible object storage off-site. Restores are verified
**automatically, weekly**, because a backup nobody has restored is a hypothesis.

## What is backed up, and what deliberately is not

| Data | Method | Retention | Why |
|---|---|---|---|
| Immich Postgres | Barman Cloud → S3, continuous WAL + nightly base | 30d PITR | albums, people, embeddings |
| Immich library (files) | restic → S3, nightly | 7d / 5w / 12m | **the photos. irreplaceable.** |
| Keycloak Postgres | Barman Cloud → S3 | 90d PITR | users, OIDC clients, roles |
| Paperless documents | restic → S3, nightly | 14d / 8w / 24m | **scanned originals. irreplaceable.** |
| Paperless SQLite | `sqlite3 .backup` → restic | same | tags, correspondents |
| Mealie Postgres | Barman Cloud → S3 | 30d PITR | recipes you typed in |
| Seafile `/shared` + MariaDB | **NOT YET IMPLEMENTED** | — | see below |
| Syncthing config | **NOT YET IMPLEMENTED** | — | see below |
| *arr configs | **NOT YET IMPLEMENTED** | — | see below |
| **The media library (26TB NFS, 9.5TB used)** | **NOT backed up** | — | see below |
| *arr Postgres databases | **NOT backed up** | — | see below |
| qBittorrent config | **NOT backed up** | — | see below |

### Why the media library is not backed up

The share is 26TB with 9.5TB in use. Even at today's usage that is roughly
€50–120/month depending on provider, growing, and a restore would mean egressing
all of it. For content that is, by its nature, re-acquirable, that is not a good
trade.

What protects it instead:

- **ZFS on the NAS** with snapshots — covers accidental deletion and ransomware,
  which are the realistic threats.
- `persistentVolumeReclaimPolicy: Retain` on the NFS PV, so no Kubernetes action
  can delete it.
- Plex and Jellyfin mount it **read-only**.

If you want off-site coverage for it, the honest options are a second NAS at
another location doing `zfs send`, or accepting the loss. Adding it to restic
would quadruple the backup bill for the least valuable data in the cluster.

**This is a deliberate decision, not an oversight.** If you disagree, the change
is a copy of `apps/immich/resources/backup-files.yaml` pointed at the
`theater-data` PVC.

### Not yet implemented: Seafile, Syncthing, *arr configs

Stated plainly rather than left as an implied promise. Only **two** restic
CronJobs exist as manifests today:

| Repository | Manifest |
|---|---|
| `immich/library` | `apps/immich/resources/backup-files.yaml` |
| `paperless/media` | `apps/paperless/backup.yaml` |

Seafile, Syncthing and the *arr configs are covered by `scripts/dump-databases.sh`
only to the extent that their *databases* are (Seafile's MariaDB is; the others
have no database worth the name). Their **file volumes are not backed up at all
yet**.

Each is a copy of `apps/paperless/backup.yaml` with a different PVC, mount path
and repository suffix, plus an entry in `local.restic_repos` in
`bootstrap/aws-backup/main.tf` so the packs get archived. They are deliberately
left until the Immich path is proven end to end, because Immich is the one that
matters and adding five repositories at once means debugging five things.

When adding them, remember `local.restic_repos` — miss it and the packs stay in
Standard at roughly 6× the price, silently.

### Why the *arr databases and qBittorrent config are not backed up

They contain quality profiles, indexer settings and download history — annoying
to lose, but reconstructible in an evening, and they reference media that is
itself not backed up. Their `/config` volumes *are* covered by the theater restic
job, which captures the useful part.

## Architecture

Two mechanisms, chosen per data type:

**PostgreSQL → Barman Cloud.** Continuous WAL archiving plus nightly base
backups gives **point-in-time recovery**: you can restore to 14:32 yesterday,
just before a bad migration. That is qualitatively better than nightly dumps.

Which *API* is used matters, and the answer is not the modern one:

| | in-tree `spec.backup.barmanObjectStore` | Barman Cloud plugin |
|---|---|---|
| Status upstream | deprecated in CNPG 1.26 | the supported path going forward |
| Works on CNPG 1.24.1 | **yes** | no |
| Used here today | **yes** | no |

The running operator is **1.24.1**. It does not have the plugin CRD, and its
`Cluster` schema rejects `spec.plugins[0].isWALArchiver`, so the plugin form
fails at apply time — verified with a server-side dry-run, not assumed. Every
database therefore uses the in-tree form.

`platform/barman-cloud-plugin/` and `clusters/homelab/platform/barman-cloud-plugin.yaml`
are written and ready but **not referenced** by the platform kustomization.
Enabling them is a step immediately after the CNPG upgrade in
[migration-plan.md](./migration-plan.md).

**Files → restic CronJobs.** Deduplicated, encrypted, incremental.

### Why restic CronJobs rather than VolSync

VolSync is the more polished GitOps answer and does snapshot-then-backup, giving
a crash-consistent copy. It is also another operator to install, version and
understand.

For this data the snapshot buys little: the Immich library and Paperless media are
write-once-then-immutable files. Backing them up live can catch a half-written
file, and restic simply picks it up correctly next run. Where consistency
genuinely matters — the databases — Barman handles it properly with PITR, and
Paperless' SQLite gets `sqlite3 .backup`, which cooperates with the running
writer instead of copying bytes from underneath it.

VolSync is the right upgrade if a PVC ever holds something mutated in place.

## Before any of that: the backup you can take right now

The S3 machinery above needs a bucket and credentials. Until those exist there is
**no backup at all**, and the migration in [migration-plan.md](./migration-plan.md)
should not start without one.

```sh
task backup:dump      # -> ~/homelab-backups/<utc>/
```

Dumps every database — 7 Postgres clusters via CloudNativePG, Seafile's MariaDB,
and Paperless' SQLite — to local disk, and **verifies each one**:

| Check | Catches |
|---|---|
| sha256 taken **at the source**, compared locally | corruption in transit. `pg_dump`'s custom format has no internal checksums, so nothing else finds a flipped byte |
| `set -o pipefail` on the `pg_dump` pipeline | `pg_dump` failing. Without it a dump that died early has a checksum that matches on *both* sides |
| archive magic + non-zero size | a file that is actually an error message |
| `mariadb-dump` end-of-dump marker | a MariaDB dump that stopped halfway |
| `PRAGMA integrity_check` on the SQLite copy | a torn snapshot |

The script exits non-zero if any dump fails, and says so loudly. It never writes
to the cluster.

Two things worth knowing about how it works, both discovered the hard way:

- The CNPG pods have a **read-only root filesystem**, and the only large writable
  path is the live PGDATA volume — filling that would stop the database. So the
  dump is teed through a **FIFO** into `sha256sum`: a real source-side checksum
  that uses no storage at all.
- Paperless' image has **no `sqlite3` binary**, which this document previously
  flagged as an open question. It does have Python, so the backup uses
  `sqlite3.Connection.backup()` — the online backup API, which cooperates with
  the running writer instead of copying bytes from underneath it. Resolved.

### Proving a dump actually restores

```sh
task backup:verify-restore -- immich immich-db \
  ~/homelab-backups/<utc>/pg-immich-immich-db.dump
```

Builds a throwaway CNPG cluster in its own namespace, restores into it, and
compares against the live database: table count, row counts on the eight
physically largest tables, every relation readable, and the extension set. Then
deletes it. The source is only ever read from.

It derives the target image and `shared_preload_libraries` from the source
cluster rather than guessing, which is what makes it work for Immich — that dump
needs pgvecto.rs 16.5 and `vectors.so`, and would fail against a plain
`postgresql:17` image.

**Result on 2026-08-03**, against the live cluster:

```
mealie/mealie-postgresql   59 tables, all row counts match          VERIFIED
immich/immich-db           60 tables; asset=50600  asset_face=53395
                           smart_search=50132  geodata_places=219618
                           extensions identical incl. `vectors`      VERIFIED
```

So the photo library's database is not a hypothesis any more. Note the row counts
are also a useful record in their own right: they are what a future restore
should be compared against.

**These dumps are on one machine.** They are point-in-time snapshots, not PITR,
and they are not off-site until you copy them somewhere else. That is what the
rest of this document is for.

## The bucket

One bucket, in `eu-central-1`, created by
[`bootstrap/aws-backup/`](../bootstrap/aws-backup/main.tf).

```sh
cd bootstrap/aws-backup
$EDITOR terraform.tfvars      # bucket_name (globally unique -- add a suffix)
tofu init && tofu plan
tofu apply
tofu output next_steps
```

**Do not apply it with root credentials, and do not create root access keys.**
Root cannot be scoped, so a leaked backup key would be able to delete the backups
*and* everything else in the account. Make yourself an admin IAM user first.

### Why one bucket with prefix lifecycle rules, not several buckets

Because the two kinds of backup want opposite things from S3, and the difference
is per-prefix, not per-bucket:

| Prefix | Contents | Storage class | Why |
|---|---|---|---|
| `*/postgres/` | barman: WAL + base backups | **Standard** | continuous churn of small objects, 30–90d retention. Any archive class has a 90-day minimum duration, so short retention is billed at 90 days anyway |
| `*/data/` | restic pack files | **Glacier Instant Retrieval** after 1 day | the bulk. Write-once, read-almost-never |
| everything else | restic `config`, `keys/`, `index/`, `snapshots/` | **Standard** | read on *every* restic operation |

That last row is the one that matters, and it is the most common way people break
restic on Glacier. restic has no concept of thawing an object — it expects every
`GET` to succeed. If the index is archived, the repository becomes unusable.
Upstream is explicit that a lifecycle policy must apply
[only to the `data/` prefix](https://forum.restic.net/t/unavailable-index-files/1326/7).

S3 prefix filters are literal prefixes with no wildcards, so there is no way to
write `*/data/`. `main.tf` generates one rule per restic repository from a list.
**Adding a new restic repo means adding it to `local.restic_repos`**, or its packs
sit in Standard at 6× the price and nothing warns you.

### Why Glacier *Instant* Retrieval and not Deep Archive

Deep Archive is roughly 4× cheaper again, and it is the wrong choice here:

- reads require an asynchronous restore taking hours, which restic cannot do — so
  `restic check --read-data` and any restore need a separate thaw workflow you
  would have to build and then remember exists
- it makes the weekly verification below impossible, and an unverifiable backup is
  a hypothesis

GIR keeps millisecond reads, so restic, verification and a real restore all work
unchanged. The premium buys the ability to *test the backup*, which is the whole
point.

Deep Archive would make sense for a second, deliberately cold copy that you only
ever touch in a genuine disaster. That is a reasonable thing to add later; it is
not a replacement for this one.

### Rough cost, per TB stored, per month

Order-of-magnitude only — check the
[calculator](https://calculator.aws/#/createCalculator/S3) for current figures:

| | Standard | Glacier IR |
|---|---|---|
| storage /TB/month | ~$23 | ~$4 |
| retrieval /TB | free | ~$30 |
| **egress to the internet /TB** | **~$90** | **~$90** |

Two things follow, and they shape everything below:

1. **Storage is cheap; egress is not.** Getting the library *out* of AWS costs
   several times a month of storing it.
2. **Retrieval is much cheaper than egress**, and traffic from S3 to EC2 **in the
   same region is free**. So reading the whole backup is affordable as long as you
   do not pull it across the internet.

Measure your actual library size before budgeting:

```sh
kubectl -n immich exec deploy/immich-server -- du -sh /data
```

### What the credentials can and cannot do

`bootstrap/aws-backup/` creates two IAM users, both scoped to this bucket only:

- **`…-writer`** — used by barman and the restic CronJobs. It can put, get and
  delete objects, because restic prunes and barman enforces retention.
- **`…-verifier`** — read-only, plus restic's lock prefix. Used by the restore
  drill, so a drill gone wrong cannot damage the backup it is testing.

The writer carries an explicit `Deny` on `s3:DeleteObjectVersion`,
`s3:PutBucketVersioning`, `s3:PutLifecycleConfiguration` and `s3:DeleteBucket`.
Combined with versioning, that means **the backup credential cannot make a
deletion permanent**: `DeleteObject` only writes a delete marker, and the previous
version survives for 30 days. Deny beats Allow in IAM unconditionally, so this
holds even if a broader policy is attached later.

This is deliberately not S3 Object Lock. Object Lock is stronger — genuinely
immutable, undeletable even by root in Compliance mode — and it has to be enabled
at bucket creation and cannot be turned off. For a homelab where you may want to
fix your own mistakes, versioning plus a deny is the better trade. Add Object Lock
in Governance mode if you disagree; it is a one-line change but only at creation
time.

### Credentials checklist

- [ ] all four access keys → Bitwarden (`tofu output -raw <name>`)
- [ ] `RESTIC_PASSWORD` generated (`openssl rand -base64 48`) → Bitwarden,
      **beside the age key**. Without it the file backups are unreadable,
      including by you.
- [ ] `bootstrap/aws-backup/terraform.tfstate` now contains the secret keys.
      It is git-ignored, but treat it as a secret: mode 600, and move it off this
      machine or into an encrypted backend once the keys are in Bitwarden.

### 2. The Secret

```sh
cp platform/secrets/s3-backup.sops.yaml.example platform/secrets/s3-backup.sops.yaml
$EDITOR platform/secrets/s3-backup.sops.yaml
task secrets:seal -- platform/secrets/s3-backup.sops.yaml
```

Note it defines the **same Secret in seven namespaces** — Kubernetes Secrets are
namespaced and there is no built-in replication. Both key spellings are present
(`ACCESS_KEY_ID` for Barman, `AWS_ACCESS_KEY_ID` for restic) because the two tools
disagree about conventions and neither is configurable.

`RESTIC_PASSWORD` encrypts the restic repository. **Back it up beside the age
key.** Without it the backups are unreadable — including by you.

### 3. Endpoints

The bucket and endpoint appear in each backup manifest. Update them together:

```sh
grep -rn 'homelab-backups' --include='*.yaml' .
```

### 4. The first Immich run will take days

A 2TB initial upload over a domestic uplink is not a five-minute job. Start it
well before you need it, and well before a house move:

```sh
kubectl -n immich create job --from=cronjob/immich-library-backup initial
kubectl -n immich logs -f job/initial
```

## Verification

`platform/backup-verify/` runs weekly and **never touches anything live**.

**Postgres** (Sunday 05:00): creates a throwaway CNPG cluster in the
`backup-verify` namespace, bootstrapped by recovery from S3, then asserts:

1. the server answers queries
2. the schema has at least *N* tables — an **empty** restore is the classic
   silent failure, where the restore "succeeds" with no data
3. every relation is readable (catches corruption)
4. the extension list is printed — Immich will not boot without its vector
   extension, so a regression there shows up in the log

Then deletes the cluster. Two independent reasons it cannot damage anything:

- its RBAC is a `Role` in its own namespace, so it cannot reach `immich` or
  `keycloak` at all
- the restored cluster declares **no `spec.backup`**, so it has nowhere to
  archive WAL and physically cannot write into the object store it read from

**Files** (Sunday 07:00): for each restic repository,

1. `restic check` — structural integrity
2. the newest snapshot is **less than 3 days old** — catches a CronJob that has
   been failing silently
3. **a sample of real files is restored** and asserted non-empty

Point 3 is the one that matters. `restic check` validates metadata; it does not
prove the data blobs are retrievable. Restoring proves it.

### How to verify a large backup without the verification costing more than the backup

This is the real design problem. Restoring 500GB–2TB weekly to prove it works
would cost more per month than storing it. But "we can't afford to test it" ends
with an untested backup, which is the failure mode this whole document exists to
avoid.

The way out is that **the expensive thing is egress, not reading**. Reading from
Glacier IR costs ~$30/TB; pulling it across the internet to your house costs
~$90/TB on top. Reading it into EC2 *in the same region* costs the retrieval and
**nothing else**. So the strategy is not to test less, it is to test in the right
place — and to spend the cheap checks often and the expensive ones rarely.

| Tier | What it proves | Frequency | Runs where | Rough cost |
|---|---|---|---|---|
| 1. Postgres full restore | albums, faces, people — the metadata you cannot rebuild — are recoverable | weekly | in-cluster | pennies (it is ~370MB) |
| 2. `restic check` (no `--read-data`) | repository structure, index consistency | weekly | in-cluster | pennies (metadata only, and it lives in Standard) |
| 3. Snapshot freshness | the CronJob is actually running | weekly | in-cluster | free |
| 4. Sample restore, ~5 files | credentials work and blobs are genuinely retrievable | weekly | in-cluster | ~$0.02 |
| 5. `restic check --read-data-subset=1/52` | a rotating 1/52 slice of every pack is readable → **full coverage over a year** | weekly | in-cluster | ~$1–4/month depending on library size |
| 6. Full `--read-data` + full restore drill | the whole thing really restores, end to end | **annually** | **EC2, same region** | retrieval only; egress is $0 |

Tier 5 is the part people skip, and it is what turns "the index is fine" into
"every byte has been read back at least once this year". restic supports
`--read-data-subset=n/t` precisely for this.

Tier 6 is where the region choice pays off. A full drill from home would be
~$90/TB in egress. The same drill on a spot instance in `eu-central-1`:

```sh
# a t4g.medium spot instance, same region as the bucket
# use the READ-ONLY verifier credential from bootstrap/aws-backup
export AWS_ACCESS_KEY_ID=...        # tofu output -raw verify_access_key_id
export AWS_SECRET_ACCESS_KEY=...    # tofu output -raw verify_secret_access_key
export RESTIC_REPOSITORY="s3:s3.eu-central-1.amazonaws.com/<bucket>/immich/library"
export RESTIC_PASSWORD=...

restic check --read-data          # reads every pack. This is the real check.
restic restore latest --target /mnt/scratch
# spot-check a few hundred files against known checksums, then terminate.
```

Cost is retrieval plus a few hours of cheap compute. **Terminate the instance**;
an idle one costs more over a year than the drill did.

**Do not ever restore the whole library to the house "just to check".** That is the
expensive mistake, and it teaches you nothing that tier 6 does not.

### What the real disaster costs

Worth knowing before you need it, so the number is not a surprise:
recovering the full library to home is ~$90/TB in egress plus ~$30/TB retrieval.
For a 500GB library that is roughly $60. That is the insurance paying out, and it
is fine — the point of the tiers above is that you only pay it when something has
actually gone wrong.

### Run it now

```sh
kubectl -n backup-verify create job --from=cronjob/backup-verify-postgres now-pg
kubectl -n backup-verify logs -f job/now-pg

kubectl -n backup-verify create job --from=cronjob/backup-verify-files now-files
kubectl -n backup-verify logs -f job/now-files
```

### Alerting

`platform/backup-verify/alerts.yaml` fires on:

| Alert | Meaning |
|---|---|
| `BackupVerificationFailed` | a restore test failed — **data-loss risk** |
| `BackupVerificationStale` | no successful verification in 14 days |
| `PostgresBackupFailed` | last backup failed |
| `PostgresBackupStale` | no base backup in 36h (two consecutive failures) |
| `PostgresWALArchiveFailing` | PITR broken, **and WAL will fill the data volume** |
| `FileBackupJobFailed` | a restic CronJob is failing |

`PostgresWALArchiveFailing` is the one to treat as urgent: unarchivable WAL
accumulates locally and can take the database down on its own.

## Restoring

### Postgres, to a point in time

Create a **new** cluster that recovers from the object store — never restore over
a live one:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: immich-db-restored
  namespace: immich
spec:
  instances: 1
  # Must match the source cluster's image, or the restore will not start.
  # Check it: kubectl -n immich get cluster immich-db -o jsonpath='{.spec.imageName}'
  imageName: ghcr.io/tensorchord/cloudnative-pgvecto.rs:16.5-v0.3.0
  storage: { size: 20Gi, storageClass: iscsi }
  bootstrap:
    recovery:
      source: src
      recoveryTarget:
        targetTime: "2026-07-30 14:32:00+02"   # omit for latest
  externalClusters:
    - name: src
      # `serverName` selects which backup inside destinationPath to read. It is
      # the SOURCE cluster's name, not this one's.
      barmanObjectStore:
        destinationPath: s3://homelab-backups/immich/postgres
        endpointURL: https://s3.eu-central-003.backblazeb2.com
        serverName: immich-db
        s3Credentials:
          accessKeyId: { name: s3-backup, key: ACCESS_KEY_ID }
          secretAccessKey: { name: s3-backup, key: ACCESS_SECRET_KEY }
```

Verify it, then repoint the app at `immich-db-restored-rw`. Note the restored
cluster has no `spec.backup`, so it does **not** archive WAL — add that block
once you promote it, or the new primary has no backups at all.

### Files

```sh
# What is in there?
kubectl -n immich run restic-restore --rm -it --restart=Never \
  --image=restic/restic:0.19.0 \
  --overrides='{"spec":{"containers":[{"name":"r","image":"restic/restic:0.19.0",
    "command":["sh"],"stdin":true,"tty":true,
    "envFrom":[{"secretRef":{"name":"s3-backup"}}],
    "env":[{"name":"RESTIC_REPOSITORY","value":"s3:https://<endpoint>/homelab-backups/immich/library"}]}]}}'

# then inside:
restic snapshots
restic restore latest --target /restore --include /data/library/user/2024
```

Restore into a **scratch** location and copy across deliberately. Restoring
straight over a live library is how a bad restore becomes a real outage.

## When verification fails

1. **Do not ignore it.** This alert exists because the alternative is discovering
   the problem when you need the backup.
2. Read the job log: `kubectl -n backup-verify logs job/<name>`.
3. Common causes, in order of likelihood:
   - S3 credentials expired or rotated
   - bucket lifecycle rules deleted objects the retention policy still expects
   - the backup CronJob has been failing (check `PostgresBackupStale` too)
   - genuine corruption — restore the previous snapshot and investigate
4. Fix, then re-run the verification by hand before considering it closed.

## What is still missing

Stated plainly rather than left implied:

- **No off-site copy of the media library.** Deliberate, see above.
- **Backups are not tested for restore *time*.** Verification proves data is
  retrievable, not that a full 2TB restore completes in a useful window. It
  would not.
- **`sqlite3` is not in the Paperless image** — confirmed, not hypothetical.
  `scripts/dump-databases.sh` works around it with Python's
  `sqlite3.Connection.backup()`. The restic CronJob still needs the same
  treatment; it currently checks and warns rather than producing an inconsistent
  copy silently.
- **No monthly full-restore drill.** The weekly sample is a good proxy; an
  annual real drill would be better.
