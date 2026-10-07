# Backups

The data of Immich, Mealie, Paperless, Seafile, Syncthing and the theater apps is
backed up nightly with restic to one S3 bucket (`ned-si-homelab-backups`,
`eu-central-1`). The
Immich photo library also has a second, independent restic repository on the NAS.
Postgres and MariaDB are captured as logical dumps inside those repositories.
`immich-db` and `keycloak-db` have no scheduled backup: barman is not running on
any CloudNativePG cluster yet, so those two are covered only by
[on-demand local dumps](#local-dumps-and-pre-upgrade-snapshots).

Restores have been rehearsed from S3 with the read-only key for `mealie/data` (files
and Postgres dump) and for a sample of 50 Immich originals. Every restored file
matched its live copy, except one log file written after the snapshot. The steps
are in [How to restore](#how-to-restore).

## What is backed up where

### S3 repositories

Bucket `ned-si-homelab-backups`, endpoint `https://s3.eu-central-1.amazonaws.com`.
One restic repository per prefix. The restic URL is
`s3:https://s3.eu-central-1.amazonaws.com/ned-si-homelab-backups/<repository>`.

| Repository | restic host | Snapshot path → tag | Source | Size at first backup |
|---|---|---|---|---|
| `immich/library` | `immich` | `/data` → `immich-library` | PVC `immich-data` (read-only), minus `thumbs/`, `encoded-video/`, `.tmp` | 256 GiB, 50,822 files |
| `mealie/data` | `mealie` | `/data` → `mealie-files`; `/dumps` → `mealie-postgres` | PVC `mealie-pvc`; `pg_dump` of `mealie-postgresql` | 1.5 MiB |
| `paperless/media` | `paperless` | `/media` → `paperless-media`; `/data` → `paperless-data` | PVCs `paperless-media`, `paperless-data` (includes `db.sqlite3`) | 2.4 MiB |
| `seafile/shared` | `seafile` | `/shared` → `seafile-data`; `/dumps` → `seafile-mariadb` | PVC `seafile-pvc`; `mariadb-dump` of Seafile's MariaDB | 0.7 MiB |
| `syncthing/data` | `syncthing` | `/data` → `syncthing-identity` | PVC `syncthing-pvc` | 8.2 MiB |
| `theater/configs` | `theater` | `/config` → `sonarr`, `radarr`, `lidarr`, `prowlarr`, `plex`, `jellyfin-config`; `/config/data` → `jellyfin-db-besteffort`; `/dumps` → `theater-postgres` | the six `*-config` PVCs; `pg_dump` of `sonarr`/`radarr`/`lidarr`/`prowlarr-postgresql` | 295 MiB |
| `grafana/data` | — | — | none: Grafana has no persistent volume, so the job is not rendered. The repository exists and is empty | 0 |

Every snapshot in `theater/configs` also carries the tag `theater-configs`. The
dumps are files named `pg-<app>.dump` (theater), `pg-mealie-mealie-postgresql.dump`
and `seafile-mariadb.sql.gz` under `/dumps` in the snapshot.

The jobs run as uid 1000 with the source volumes mounted read-only. Credentials
come from the Secret `s3-backup` (the writer key and `RESTIC_PASSWORD`), present in
every namespace that runs a backup job.

### Local repository on the NAS

| Repository | Where | Source | Retention |
|---|---|---|---|
| `/backups/immich/library` | NFS `192.168.1.228:/mnt/homelab/k8s/backups`, subdirectory `immich/library` (dataset `homelab/k8s/backups`) | PVC `immich-data`, same excludes as S3 | `--keep-daily 14 --keep-weekly 8 --keep-monthly 6`, pruned nightly |

It is a separate repository, not a copy of the S3 one, so corruption or a bad
`forget` in one cannot reach the other. It uses the same `RESTIC_PASSWORD`. It sits
on the same ZFS pool as the live library, so it protects against mistakes and bad
upgrades, not against losing the NAS.

### Databases

| Database | Captured by | Into | Consistency |
|---|---|---|---|
| `immich/immich-db` | nothing scheduled | — | on-demand local dump only |
| `keycloak/keycloak-db` | nothing scheduled | — | on-demand local dump only |
| `mealie/mealie-postgresql` | `pg_dump` in `mealie-backup` | `mealie/data` | consistent, one transaction |
| `theater/{sonarr,radarr,lidarr,prowlarr}-postgresql` | `pg_dump` in `theater-postgres-backup` | `theater/configs` | consistent, one transaction |
| Seafile MariaDB | `mariadb-dump --single-transaction` (client `mariadb:10.11`, same as the server) in `seafile-backup` | `seafile/shared` | consistent, no table locks |
| Paperless SQLite | file copy of `db.sqlite3` inside `/data` | `paperless/media` | may be torn: the restic image has no `sqlite3`, so `.backup` is skipped and the job logs a warning |

No CloudNativePG cluster has `spec.backup` or a barman plugin, so no WAL is
archived and there is no point-in-time recovery for any database. The
`ContinuousArchiving=True` condition CNPG reports on every cluster is meaningless
without a target: the archive command succeeds without sending anything. The
cluster runs CNPG 1.30.1, so the Barman Cloud plugin
(`platform/barman-cloud-plugin/`) can be wired in; that is not done yet.

Before every sync of `mealie`, `seafile` and `theater`, an Argo CD PreSync hook
(`presync-backup.yaml` in each app) runs that app's database backup CronJob
once and waits for it to complete. A failed backup fails the sync, so no image
change, including a database major, is applied without a fresh, verified dump.

### Outside the cluster

| What | Where | How |
|---|---|---|
| All nine databases (seven Postgres, Seafile MariaDB, Paperless SQLite) | `~/homelab-backups/<utc>/` on the machine that runs it | `task backup:dump`, by hand |
| etcd | `/root/etcd-snapshots/` on `homelab-cp-1` and `~/homelab-backups/etcd/` | by hand before every upgrade or risky change, [runbooks/cold-start.md](runbooks/cold-start.md#etcd-snapshot-and-restore) |
| Cluster configuration | this repository | every manifest is in git; see [bootstrap.md](bootstrap.md) |

## RPO and RTO

RPO is the most data you can lose. RTO here is what a rehearsed restore took; where
nothing was rehearsed, the column says so.

| Data | Copies | RPO | Restore rehearsed | RTO |
|---|---|---|---|---|
| Immich originals | S3 + NAS | 24 h | from S3, 50-file sample, 2026-10-06 | 410 MiB in 8 s. Full library (256 GiB) not rehearsed; at the sample's rate about 1.5 h, plus about $30 of retrieval and egress |
| Immich originals, NAS copy | NAS | 24 h | no | — |
| Immich database (`immich-db`) | local dump only | since the last `task backup:dump` | no (`task backup:verify-restore` exists) | — |
| Keycloak database (`keycloak-db`) | local dump only | since the last `task backup:dump` | no | — |
| Mealie files + database | S3 | 24 h | from S3, full, 2026-10-06 | restore 24 s; dump restored into a throwaway Postgres, row counts equal to live |
| Paperless documents + SQLite | S3 | 24 h | no | — |
| Seafile blobs + MariaDB | S3 | 24 h | no | — |
| Syncthing identity + config | S3 | 24 h | no | — |
| *arr, Plex, Jellyfin config and *arr databases | S3 | 24 h | no | — |
| Media library | none | everything | — | — |
| Cluster state | git, plus etcd snapshots by hand | last merged commit | no | rebuild, see [bootstrap.md](bootstrap.md) and [runbooks/cold-start.md](runbooks/cold-start.md) |

## Schedule

All times UTC (the controller's time zone; no CronJob sets `timeZone`). Every job
has `concurrencyPolicy: Forbid`, so a run still going when the next is due causes
that next run to be skipped. One start per slot, so jobs never share the uplink or
the NAS:

| UTC | Job |
|---|---|
| 01:30 | `immich/immich-library-backup-local` (NAS) |
| 02:00 | `syncthing/syncthing-backup` |
| 02:30 | `paperless/paperless-backup` |
| 03:00 | `seafile/seafile-backup` |
| 03:20 | `mealie/mealie-backup` |
| 03:30 | `immich/immich-library-backup` (S3) |
| 03:40 | `theater/theater-postgres-backup` |
| 04:00–04:40 | `theater/theater-config-backup-{sonarr,radarr,lidarr,prowlarr,plex}`, ten minutes apart |
| 05:00 | `theater/theater-config-backup-jellyfin` |
| 1st of the month, 12:00–13:30 | `*-prune`: syncthing 12:00, mealie 12:15, paperless 12:30, seafile 12:45, theater 13:00, immich 13:30 |

The six theater jobs share one repository and restic takes an exclusive lock for
`backup`, hence the spacing; 04:50 is kept for bazarr. Each nightly job ends with
`restic check`. The running set is listed in `ci/active-cronjobs.txt`; CI fails any
other rendered CronJob that is not suspended.

A failed backup Job fires the stock `KubeJobFailed` rule from kube-prometheus-stack,
but Alertmanager has only the `null` receiver, so nobody is notified: check the Jobs
by hand ([observability.md](observability.md)). The backup-specific alerts in
`platform/backup-verify/alerts.yaml` are not deployed.

```sh
kubectl get cronjobs -A | grep -E 'backup|prune'   # 19 lines, SUSPEND False
kubectl get jobs -A | grep -E 'backup|prune'       # after 05:30 UTC: every job Complete
```

## Retention

| Repository | Nightly job | Monthly `*-prune` job |
|---|---|---|
| `immich/library`, `mealie/data`, `theater/configs` | backup + check | `forget --keep-within 3m --keep-monthly 12 --prune`, then check |
| `paperless/media`, `seafile/shared`, `syncthing/data` | backup + check | `forget --keep-within 3m --keep-monthly 24 --prune`, then check |
| NAS `immich/library` | backup + `forget --keep-daily 14 --keep-weekly 8 --keep-monthly 6 --prune` + check | — |

`theater-configs-prune` uses `--group-by host,paths,tags`, so each app keeps its own
monthly snapshots. Retention is in months because restic pack files move to Glacier
Instant Retrieval after one day, and Glacier IR bills every object for at least 90
days: keeping every snapshot for three months means no pack is deleted before then.

## How to restore

Restore into a throwaway namespace and a scratch volume, check the result, then
copy across deliberately. Never restore over a live volume or a live database.

These steps reproduce the rehearsed restores. They run on macOS with `kubectl`
pointed at the cluster and need nothing else installed; restic runs in the Jobs.

### Before you start

You need:

- the read-only verifier key:
  `scripts/tofu.sh bootstrap/aws-backup output -raw verify_access_key_id` and
  `... output -raw verify_secret_access_key`
  ([OpenTofu state](bootstrap.md#opentofu-state)), or the password manager copy
  ([secrets.md](secrets.md));
- `RESTIC_PASSWORD`, from the password manager (also sealed in
  `platform/secrets/s3-backup.sops.yaml`). Without it no file backup can be read;
- the repository and tag from [S3 repositories](#s3-repositories).

Use the verifier key, not the writer key in `s3-backup`: it can read the bucket and
cannot change data, so a mistake during a restore cannot damage the backup. Every
restic call below passes `--no-lock`; a restore does not need a lock.

### 1. Namespace, credentials, scratch volume

```sh
NS=restore-test
kubectl create namespace "$NS"
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=restricted
```

Expected: `namespace/restore-test created`, `namespace/restore-test labeled`.

Type the three values at the prompts; they are not echoed and not written to disk:

```sh
printf 'verifier key id: ';  read -rs KEY_ID;     echo
printf 'verifier secret: ';  read -rs KEY_SECRET; echo
printf 'restic password: ';  read -rs RESTIC_PW;  echo
kubectl -n "$NS" create secret generic restic-verifier \
  --from-literal=AWS_ACCESS_KEY_ID="$KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$KEY_SECRET" \
  --from-literal=AWS_DEFAULT_REGION=eu-central-1 \
  --from-literal=RESTIC_PASSWORD="$RESTIC_PW"
unset KEY_ID KEY_SECRET RESTIC_PW
```

Expected: `secret/restic-verifier created`.

Size the scratch volume to what you restore (the rehearsals used 2Gi):

```sh
kubectl -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restore-scratch
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: iscsi-retain
  resources:
    requests:
      storage: 2Gi
EOF
```

Expected: `persistentvolumeclaim/restore-scratch created`. It binds when the first
pod uses it.

### 2. Restore a snapshot

Set the repository and tag, and the snapshot: `latest` (the newest one with that
tag) or an id from the listing.

```sh
REPO=mealie/data
TAG=mealie-files
SNAP=latest
kubectl -n "$NS" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: restic-restore
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 7200
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile: {type: RuntimeDefault}
      initContainers:
        - name: snapshots
          image: restic/restic:0.19.0
          args: [--no-lock, snapshots, --tag, "$TAG"]
          envFrom: [{secretRef: {name: restic-verifier}}]
          env: &env
            - {name: RESTIC_REPOSITORY, value: "s3:https://s3.eu-central-1.amazonaws.com/ned-si-homelab-backups/$REPO"}
            - {name: RESTIC_CACHE_DIR, value: /cache}
            - {name: TMPDIR, value: /cache}
          volumeMounts: &mounts
            - {name: scratch, mountPath: /restore}
            - {name: cache, mountPath: /cache}
          securityContext: &csec
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
      containers:
        - name: restore
          image: restic/restic:0.19.0
          args: [--no-lock, restore, "$SNAP", --tag, "$TAG", --target, /restore, --verify]
          envFrom: [{secretRef: {name: restic-verifier}}]
          env: *env
          volumeMounts: *mounts
          securityContext: *csec
          resources:
            requests: {cpu: 100m, memory: 256Mi}
            limits: {memory: 1Gi}
      volumes:
        - {name: scratch, persistentVolumeClaim: {claimName: restore-scratch}}
        - {name: cache, emptyDir: {sizeLimit: 2Gi}}
EOF
kubectl -n "$NS" wait --for=condition=complete job/restic-restore --timeout=2h
kubectl -n "$NS" logs job/restic-restore -c snapshots
kubectl -n "$NS" logs job/restic-restore -c restore
```

Expected: `job.batch/restic-restore condition met`. The `snapshots` log lists the
snapshots with that tag. The `restore` log ends with
`Summary: Restored <n> files/dirs (<size>) in <time>`, then
`finished verifying <n> files in /restore`. The files land under
`/restore/<snapshot path>`, for example `/restore/data/…`.

If the Job fails, read the same logs. `wrong password or no key found` means the
wrong `RESTIC_PASSWORD`; `Access Denied` means the wrong key or repository.

To restore only part of a snapshot, add `--include, <path>` to the `restore` args,
once per path (paths as in the snapshot, e.g. `/data/library/<user>/2024`). For the
Immich sample, 50 `--include` paths were passed this way.

### 3. Check it against live

Checksums of the restored files, then of the live ones; for Mealie:

```sh
kubectl -n "$NS" delete job restic-restore
kubectl -n "$NS" apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: restore-sums
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: sums
          image: restic/restic:0.19.0
          command: [/bin/sh, -c, "cd /restore/data && find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2"]
          volumeMounts: [{name: scratch, mountPath: /restore, readOnly: true}]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
      volumes:
        - {name: scratch, persistentVolumeClaim: {claimName: restore-scratch, readOnly: true}}
EOF
kubectl -n "$NS" wait --for=condition=complete job/restore-sums --timeout=10m
kubectl -n "$NS" logs job/restore-sums > restored.sha256
kubectl -n mealie exec deploy/mealie -- sh -c \
  'cd /app/data && find . -type f ! -path "*/.temp/*" -exec sha256sum {} + | LC_ALL=C sort -k2' > live.sha256
diff restored.sha256 live.sha256
```

Expected: no output, except files the app wrote after the snapshot (`.temp/` is
excluded from the backup). In the rehearsal 44 of 45 files matched; the 45th was
`mealie.log`, appended to after the snapshot, and its restored bytes equalled the
start of the live file.

For Immich, compare with the database instead: an asset's `checksum` is the SHA-1
of the original. Pick assets created before the snapshot (its time is in the
`snapshots` log). Live paths start with `/usr/src/app/upload/`, which is `/data/`
in the snapshot.

```sh
kubectl -n immich exec immich-db-1 -c postgres -- psql -X -At -d app -c \
  "select \"originalPath\", encode(checksum, 'hex') from asset where \"deletedAt\" is null and \"createdAt\" < '<snapshot time>+00' order by random() limit 50"
```

Restore those paths with `--include` (`TAG=immich-library`, `REPO=immich/library`),
run `sha1sum` instead of `sha256sum` in the `restore-sums` Job, and compare. In the
rehearsal all 50 matched the database and the live files.

### 4. Check a Postgres dump

Restore the dump snapshot: `kubectl -n "$NS" delete job restic-restore
--ignore-not-found`, then [step 2](#2-restore-a-snapshot) with, for Mealie, `TAG=mealie-postgres` (for the
*arr databases, `REPO=theater/configs TAG=theater-postgres`). Then load the dump
into a throwaway Postgres in an `emptyDir` and count rows. Use a Postgres image of
the same major version as the source or newer (the source clusters run 17.0).

```sh
kubectl -n "$NS" apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: pg-restore-check
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 26
        runAsGroup: 26
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: pg
          image: ghcr.io/cloudnative-pg/postgresql:17.6
          env:
            - {name: DUMP, value: /restore/dumps/pg-mealie-mealie-postgresql.dump}
          command: [/bin/sh, -eu, -c]
          args:
            - |
              export PGDATA=/work/pg HOME=/work TMPDIR=/work
              initdb -U postgres -A trust > /work/initdb.log
              pg_ctl -o "-k /work -c listen_addresses=''" -l /work/pg.log -w start > /dev/null
              createdb -h /work -U postgres app
              pg_restore -h /work -U postgres -d app --no-owner --no-privileges --exit-on-error "$DUMP"
              Q="select format('select %L, count(*) from %I.%I;', table_schema||'.'||table_name, table_schema, table_name) from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1"
              psql -X -h /work -U postgres -At -d app -c "$Q" | psql -X -h /work -U postgres -At -F' ' -d app
              pg_ctl -m fast -w stop > /dev/null
          volumeMounts:
            - {name: scratch, mountPath: /restore, readOnly: true}
            - {name: work, mountPath: /work}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
      volumes:
        - {name: scratch, persistentVolumeClaim: {claimName: restore-scratch, readOnly: true}}
        - {name: work, emptyDir: {sizeLimit: 2Gi}}
EOF
kubectl -n "$NS" wait --for=condition=complete job/pg-restore-check --timeout=30m
kubectl -n "$NS" logs job/pg-restore-check > restored-rows.txt

DBN=$(kubectl -n mealie get secret mealie-postgresql-app -o jsonpath='{.data.dbname}' | base64 -d)
Q="select format('select %L, count(*) from %I.%I;', table_schema||'.'||table_name, table_schema, table_name) from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1"
kubectl -n mealie exec mealie-postgresql-1 -c postgres -- \
  sh -c "psql -X -At -d '$DBN' -c \"$Q\" | psql -X -At -F' ' -d '$DBN'" > live-rows.txt
diff restored-rows.txt live-rows.txt
```

Expected: the Job completes (`pg_restore` exits 0 with `--exit-on-error`) and
`diff` prints nothing, or only tables written to since the dump. In the rehearsal
all 59 tables (606 rows) matched.

### 5. Clean up

The scratch volume is on `iscsi-retain`, so deleting the claim keeps the volume on
the NAS. Switch only that PV to `Delete` first. Check the name before patching: it
must be the scratch claim's volume and nothing else.

```sh
PV=$(kubectl -n "$NS" get pvc restore-scratch -o jsonpath='{.spec.volumeName}')
kubectl get pv "$PV" -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'
```

Expected: `restore-test/restore-scratch`. Stop if it prints anything else.

```sh
kubectl -n "$NS" delete jobs --all
kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
kubectl delete namespace "$NS"
kubectl get pv "$PV"
rm -f restored.sha256 live.sha256 restored-rows.txt live-rows.txt
```

Expected: the last `kubectl` prints `NotFound` within a minute, once
democratic-csi has deleted the volume.

### Not rehearsed

- **Writing restored data back into a live volume.** Every Application except
  `immich` runs `selfHeal`, so scaling an app to zero is reverted within seconds.
  Disable automated sync on its Argo CD Application first, scale it down, copy the
  data from the scratch volume, scale up, re-enable sync.
- **The NAS repository.** Same Job with `RESTIC_REPOSITORY=/backups/immich/library`,
  only `RESTIC_PASSWORD` in the Secret, and the NFS share
  `192.168.1.228:/mnt/homelab/k8s/backups` mounted read-only at `/backups`. The
  `restricted` Pod Security level rejects NFS volumes, so label the namespace
  `baseline` instead.
- **A full Immich library restore**, and a restore after the packs moved to
  Glacier IR. Glacier IR reads are immediate; only the cost differs.
- **Point-in-time recovery.** There is no barman backup to recover from. Once
  barman archives a cluster, recover into a **new** cluster, never over the live
  one, with the source cluster's image
  (`kubectl -n immich get cluster immich-db -o jsonpath='{.spec.imageName}'`):

  ```yaml
  apiVersion: postgresql.cnpg.io/v1
  kind: Cluster
  metadata:
    name: immich-db-restored
    namespace: immich
  spec:
    instances: 1
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
          # serverName is the SOURCE cluster's name, not this one's.
          destinationPath: s3://ned-si-homelab-backups/immich/postgres
          endpointURL: https://s3.eu-central-1.amazonaws.com
          serverName: immich-db
          s3Credentials:
            accessKeyId: { name: s3-backup, key: ACCESS_KEY_ID }
            secretAccessKey: { name: s3-backup, key: ACCESS_SECRET_KEY }
  ```

  The restored cluster has no `spec.backup`, so it archives nothing until you add
  it.
- **`immich-db` from a local dump.** Its image is
  `cloudnative-pgvecto.rs:16.5-v0.3.0` (PostgreSQL 16 with pgvecto.rs); restore
  into a cluster with exactly that image. `task backup:verify-restore -- immich
  immich-db <dump>` derives the image from the source cluster.

## Consistency, per tag

Nothing quiesces before a backup. Every Application except `immich` runs
`selfHeal: true`, so Argo CD would revert `replicas: 0` within seconds and restart
the app mid-backup.

**Consistent.** The `pg_dump` and `mariadb-dump --single-transaction` snapshots.
Content-addressed, write-once files: the Immich library, Seafile blobs, Mealie
uploads; a live copy cannot be torn, and an upload caught in flight is picked up on
the next run. XML configuration written by rename (the *arr `config.xml`,
Jellyfin's `config/`).

**Consistent because the live database is excluded.**

- **Plex.** The live SQLite databases, `Metadata/`, `Media/` and `Cache/` are
  excluded; Plex's own scheduled database backups are included. `Preferences.xml`
  is included: it holds the server identity and its Plex account token.
- **The *arr apps.** The real database is in Postgres (the `theater-postgres` dump).
  `/config` holds `config.xml`, the app's own `Backups/` zips and the ASP.NET
  data-protection keys. `logs.db` and `MediaCover/` are excluded.

**Not consistent, and tagged so.**

- **`jellyfin-db-besteffort`.** `jellyfin.db` and `library.db` with their `-wal` and
  `-shm` files, copied live and possibly torn. At risk: user accounts, watch state,
  playback positions. `jellyfin-config` is a separate, consistent snapshot.
- **Paperless `db.sqlite3`**, copied live inside the `paperless-data` snapshot. At
  risk: document metadata; the originals in `paperless-media` are write-once.
- **Syncthing.** The job keeps only `cert.pem`, `key.pem` and `config.xml` by
  excluding the index database at the volume root, but this volume keeps its files
  under `config/`, so the excludes match nothing. The snapshot holds the whole
  volume: identity, config, the live index database and the synced folder. The
  identity check (`restic ls` must find all three files) passes. Restore only the
  three identity files; Syncthing rebuilds its index by rescanning.

**Seafile needs both halves.** The blobs are hash-named files; the MariaDB dump is
the index that maps them to files, libraries and owners. The job dumps the database
first and the blobs second, so a file uploaded in between leaves an orphan blob
rather than a database row with no blob. Restore both from the same night.

## The bucket

Created by [`bootstrap/aws-backup/`](../bootstrap/aws-backup/main.tf) (OpenTofu).
Versioning on, public access blocked, SSE-S3.

| Prefix | Contents | Storage class |
|---|---|---|
| `<repository>/data/` | restic pack files | Glacier Instant Retrieval after 1 day |
| `<repository>/` everything else | restic `config`, `keys/`, `index/`, `snapshots/`, `locks/` | Standard: read on every restic operation |
| `<namespace>/postgres/` | reserved for barman WAL and base backups; empty | Standard |

The lifecycle rule is generated per repository from `local.restic_repos` in
`bootstrap/aws-backup/main.tf`, because S3 prefix filters have no wildcards. A
repository missing from that list stays in Standard at about six times the price.
`scripts/check-restic-repos.sh` (CI) fails when the list and the manifests differ.
Noncurrent versions expire after 30 days; incomplete multipart uploads after 7.

Only `data/` moves to Glacier: restic cannot thaw objects, so an archived index
would make the repository unreadable. Instant Retrieval, not Deep Archive, so
`restic check --read-data` and restores work without a thaw step.

### Credentials

| IAM user | Used by | Can |
|---|---|---|
| `ned-si-homelab-backups-writer` | the backup jobs, via `s3-backup` | get, put and delete objects; list the bucket |
| `ned-si-homelab-backups-verifier` | restores and drills | get objects and versions, list the bucket, write only under `*/locks/` |

The writer has an explicit `Deny` on `s3:DeleteObjectVersion`, versioning,
lifecycle, bucket policy, ACL, encryption and bucket deletion. With versioning on, a
delete by the writer only adds a delete marker, and the previous version stays for
30 days. A test delete of a specific version with the writer key returns
`AccessDenied`.

## Reclaim policy

A PersistentVolume's reclaim policy decides what happens on the NAS when its claim
is deleted: `Delete` destroys the iSCSI volume, `Retain` keeps it (the PV goes to
`Released` and can be re-bound by hand).

| What | Policy |
|---|---|
| StorageClass `iscsi` (default, `infrastructure/democratic-csi/values-iscsi.yaml`) | `Delete` for new volumes. A StorageClass's `reclaimPolicy` is immutable |
| StorageClass `iscsi-retain` | `Retain` for new volumes. Use it for every new data volume |
| Every existing data PV, including `immich-data` and every CNPG volume | `Retain`, patched in place (PVs are provisioned objects, not in git) |
| `immich-machine-learning-cache`, `jellyfin-cache`, `plex-transcode` | `Delete`: regenerable caches |

Existing claims keep `storageClassName: iscsi`; a PVC's class is immutable. Re-check
after any restore or rebuild:

```sh
kubectl get pv -o custom-columns=CLAIM:.spec.claimRef.name,POLICY:.spec.persistentVolumeReclaimPolicy,SC:.spec.storageClassName
```

Expected: `Retain` on every line except the three caches. Fix a data volume on
`Delete` with
`kubectl patch pv <pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`.

Every PVC, CNPG Cluster, StatefulSet and Namespace also carries
`argocd.argoproj.io/sync-options: Delete=false,Prune=false`, so Argo CD never
deletes one when its manifest leaves git.

## What is not backed up

- **The media library** (NFS `192.168.1.228:/mnt/homelab/k8s/nfs/media`, about
  9.5 TB). Re-acquirable, and off-site storage plus a restore's egress would cost
  more than the content is worth. No periodic ZFS snapshot task is configured on the
  NAS, so nothing protects it against a deletion either. The options are a ZFS
  snapshot task, a second NAS receiving `zfs send`, or accepting the loss.
- **`qbittorrent-config`.** Torrent state, reconstructible, and it references media
  that is not backed up. A stale `ipc-socket` in this volume once caused a
  long outage ([runbook](runbooks/arr-qbittorrent.md)), so a restored copy could
  restore the fault.
- **`paperless-consume`, `plex-transcode`, `jellyfin-cache`, Immich `thumbs/` and
  `encoded-video/`.** Drop-boxes, scratch and derived files.
- **Data synced by Syncthing.** Every peer holds a full copy. Deletions propagate to
  every peer; Syncthing's per-folder File Versioning (in `config.xml`) covers that.
- **Grafana.** No persistent volume: dashboards and data sources are provisioned
  from git, users come from Keycloak.
- **etcd on a schedule.** Take a snapshot by hand before every Kubernetes upgrade
  or risky change ([runbooks/cold-start.md](runbooks/cold-start.md#etcd-snapshot-and-restore)).
  The snapshot task in `ansible/kube-upgrade.yml` calls `etcdctl` on the host, and
  the hosts have none (it lives in the etcd container), so do not rely on it.

## Local dumps and pre-upgrade snapshots

```sh
task backup:dump      # -> ~/homelab-backups/<utc>/, all nine databases, verified

task backup:verify-restore -- immich immich-db \
  ~/homelab-backups/<utc>/pg-immich-immich-db.dump
```

`backup:dump` dumps the seven Postgres clusters, Seafile's MariaDB and Paperless'
SQLite to local disk and verifies each, including a sha256 taken at the source. It
exits non-zero on any failure and never writes to the cluster. The checks are listed
in the header of `scripts/dump-databases.sh`.

`backup:verify-restore` builds a throwaway CNPG cluster in its own namespace with
the source cluster's image and `shared_preload_libraries`, restores the dump,
compares table count, row counts of the eight largest tables, readability of every
relation and the extension set against live, then deletes it.

These dumps live on one machine. Copy them elsewhere to make them a backup.

Before a risky change:

```sh
task backup:pre-upgrade -- immich-v3      # dumps + VolumeSnapshots, tagged
task backup:snapshots                     # list rollback points
task backup:drop-snapshots -- immich-v3   # once the change is confirmed good
```

A `VolumeSnapshot` on ZFS is copy-on-write: instant and initially free. Rollback is
not automated; the script prints the commands. It needs the `VolumeSnapshot` CRDs,
a snapshot controller and the `iscsi` VolumeSnapshotClass from democratic-csi.
Today the controller is an unmanaged `kube-system/snapshot-controller` v6.3.1;
`infrastructure/snapshot-controller/` is written to replace it and not enabled.
Check before relying on a snapshot:

```sh
kubectl get volumesnapshotclass
```

Expected: one row, `iscsi`, driver `org.democratic-csi.iscsi`.

## Setting it up from scratch

For a new bucket or a rebuilt cluster, in order.

1. **`task secrets:keygen`**, and back up the private key.
2. **Create the bucket and the two IAM users** from a short-lived `aws login`
   session, never long-lived or root access keys. The state bucket comes first
   ([OpenTofu state](bootstrap.md#opentofu-state)):

   ```sh
   cp bootstrap/aws-backup/terraform.tfvars.example bootstrap/aws-backup/terraform.tfvars
   $EDITOR bootstrap/aws-backup/terraform.tfvars    # bucket_name must be globally unique
   aws login --profile homelab --region eu-central-1
   scripts/tofu.sh bootstrap/aws-backup init
   scripts/tofu.sh bootstrap/aws-backup plan
   scripts/tofu.sh bootstrap/aws-backup apply
   scripts/tofu.sh bootstrap/aws-backup output next_steps
   ```

   The module's state holds the secret keys, encrypted in the state bucket.
3. **Keep `local.restic_repos` in `main.tf` equal to the repositories in the
   manifests** before applying (see [The bucket](#the-bucket)).
4. **Seal the `s3-backup` Secret.** One `RESTIC_PASSWORD`, byte-identical in every
   namespace: a repository written with one password cannot be read with another.
   Both key spellings are set (`ACCESS_KEY_ID` for barman, `AWS_ACCESS_KEY_ID` for
   restic).

   ```sh
   cp platform/secrets/s3-backup.sops.yaml.example platform/secrets/s3-backup.sops.yaml
   $EDITOR platform/secrets/s3-backup.sops.yaml
   task secrets:seal -- platform/secrets/s3-backup.sops.yaml
   task secrets:leak-check
   ```

   `RESTIC_PASSWORD` is not recoverable. Store it beside the age key.
5. **Point the manifests at the bucket:** `task backup:set-target -- <bucket>
   eu-central-1` (re-renders `deploy/`).
6. **Check every data PV is `Retain`** ([Reclaim policy](#reclaim-policy)). On a
   rebuilt cluster, new volumes on `iscsi` start as `Delete`.
7. **Seed the Immich repositories by hand** rather than at 03:30. The first upload
   of 270 GiB took 2 h 14 min (about 32 MiB/s, limited by reading the NAS, not the
   uplink), well inside the job's 20 h deadline:

   ```sh
   kubectl -n immich create job --from=cronjob/immich-library-backup-local seed-local
   kubectl -n immich create job --from=cronjob/immich-library-backup       seed-remote
   ```

   Every other repository is initialised by its job's first run: each job runs
   `restic init` before `restic backup`.
8. **List the jobs in `ci/active-cronjobs.txt`** once their first run has worked
   (see [Why it is like this](#why-it-is-like-this)).
9. **Rehearse a restore** with [How to restore](#how-to-restore).

## Verification

What runs: every nightly job ends with `restic check` (structure: snapshots, trees
and blob index, not the pack contents), and a failed Job fires `KubeJobFailed` in
Prometheus, which reaches no one until Alertmanager has a receiver.

What is written but not running: `platform/backup-verify/` (staged in
`clusters/homelab/staged/`, namespace absent). Weekly, it would restore a sample of
files from each repository, read a rotating 1/52 of the packs
(`--read-data-subset=n/52`), alert when the newest snapshot is older than three
days, and recover each barman-backed cluster into a throwaway cluster. Its
`alerts.yaml` holds the backup-specific alerts. It needs its namespace and
`s3-backup` copy, and its Postgres half needs barman.

**Annual full read.** Reading every pack is the only check that proves the whole
backup, and S3 to EC2 in the same region has no egress charge. On a small instance
in `eu-central-1`, with the verifier key:

```sh
export AWS_ACCESS_KEY_ID=<verifier key id>
export AWS_SECRET_ACCESS_KEY=<verifier secret>
export RESTIC_PASSWORD=<restic password>
export RESTIC_REPOSITORY=s3:https://s3.eu-central-1.amazonaws.com/ned-si-homelab-backups/immich/library
restic --no-lock check --read-data
```

Expected: `no errors were found`. Terminate the instance afterwards. The NAS
repository can be read in full for free from inside the cluster.

## Known gaps

- `immich-db` and `keycloak-db` have no scheduled or off-site backup. Needs the
  Barman Cloud plugin, which CNPG 1.30.1 supports; not wired in yet.
- No point-in-time recovery for any database.
- `platform/backup-verify/` is not running: no weekly sample restore, no
  `--read-data`, no staleness alert.
- No alert reaches anyone: a failed backup Job is visible only in `kubectl get jobs`
  and the Prometheus alerts page.
- Restores are rehearsed only for `mealie/data` and an Immich sample. Paperless,
  Seafile, Syncthing, theater and the NAS repository are backed up and checked, not
  restored.
- Paperless' SQLite copy may be torn.
- The Syncthing excludes do not match the volume layout (see
  [Consistency, per tag](#consistency-per-tag)).
- No ZFS snapshot task on the NAS; the media library has no protection.
- The time for a full restore is not measured.

## Why it is like this

- **restic to S3, plus a NAS copy for Immich.** One tool for every app, client-side
  encryption, deduplication, and restores that need only the bucket and a password.
  The NAS copy makes the most valuable data restorable without egress and checkable
  in full for free. Rejected: VolSync, which does snapshot-then-backup but is
  another controller to run, and buys little for write-once files. It is the upgrade
  path for data that is changed in place.
- **Backup CronJobs run only once reviewed.** A job runs unsuspended only when it
  is listed in `ci/active-cronjobs.txt`, which happens once its credentials are
  real and its first run has been seen to work. Every other CronJob ships suspended
  behind a `pending-guard` init container, so a placeholder bucket can never look
  like a working backup.
- **Logical dumps until barman runs.** Barman for `immich-db` and `keycloak-db`
  uses the Barman Cloud plugin ([roadmap](roadmap.md)). The in-tree `barmanObjectStore` was not used: it is
  deprecated from CNPG 1.26. A nightly `pg_dump` gives a 24 h RPO, enough for
  recipes and *arr settings; once barman runs, the dump becomes redundant, not
  wrong.
- **`Retain` on data PVs plus `iscsi-retain` for new ones**, rather than changing
  `iscsi`: a StorageClass's reclaim policy is immutable, and changing an existing
  claim's class means copying its data.
- **One bucket, Glacier IR on `data/` only.** Cheap storage for packs while every
  restic read keeps working. Rejected: Deep Archive, about four times cheaper, but
  every read needs an hours-long thaw that restic cannot do.
- **Versioning plus an explicit deny, not Object Lock.** The backup key cannot make
  a deletion permanent, and the owner can still fix mistakes. Object Lock is
  stronger but must be set at bucket creation and cannot be turned off.
- **Retention in months.** Glacier IR bills 90 days per object, so pruning sooner
  saves nothing.
- **No quiescing.** Argo CD `selfHeal` reverts any scale-down. Live SQLite copies
  are documented as possibly torn instead, and Jellyfin's gets its own
  `jellyfin-db-besteffort` tag. The proper fix is snapshot-then-backup (CSI
  `VolumeSnapshot` or VolSync), not built yet.
- **The media library is not backed up.** About 9.5 TB of re-acquirable content;
  off-site storage and egress cost more than it is worth.
