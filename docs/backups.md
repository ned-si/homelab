# Backups

The data of Immich, Mealie, Paperless, Syncthing and the theater apps is
backed up nightly with restic to one S3 bucket (`ned-si-homelab-backups`,
`eu-central-1`). The
Immich photo library also has a second, independent restic repository on the NAS.
Every CloudNativePG cluster archives its WAL continuously and takes a daily base
backup to the same bucket (`cnpg/<serverName>/`) through the Barman Cloud plugin,
kept 30 days, so each Postgres database can be recovered to any point in that
window. The Mealie, Home Assistant and *arr Postgres databases are also captured as
logical dumps inside the restic repositories.

Every week, `backup-verify` restores a sample of every restic repository, every
CNPG cluster, compares them with the source and
reports to Prometheus ([Verification](#verification)). The manual steps are in
[How to restore](#how-to-restore).

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
| `seafile/shared` (retained) | `seafile` | `/shared` → `seafile-data`; `/dumps` → `seafile-mariadb` | none since Seafile was removed ([decisions.md](decisions.md#seafile-removed)) | 0.7 MiB |
| `syncthing/data` | `syncthing` | `/data` → `syncthing-identity` | PVC `syncthing-pvc` | 8.2 MiB |
| `theater/configs` | `theater` | `/config` → `sonarr`, `radarr`, `lidarr`, `prowlarr`, `plex`, `jellyfin-config`, `lazylibrarian`; `/config/data` → `jellyfin-db-besteffort`; `/dumps` → `theater-postgres` | the six `*-config` PVCs; `pg_dump` of `sonarr`/`radarr`/`lidarr`/`prowlarr-postgresql` | 295 MiB |
| `books/configs` | `books` | `/data` → `audiobookshelf`; `/library` → `calibre-library`; `/config` → `calibre-web` | PVC `audiobookshelf-config`, minus `metadata/cache`, `metadata/logs`; NFS `books/ebooks`; PVC `calibre-web-config`, minus `log` | not yet measured |
| `home/configs` | `home` | `/dumps` → `home-assistant-postgres`; `/config` → `home-assistant-config` (both also `home-assistant`) | `pg_dump` of `home-assistant-postgresql`; PVC `home-assistant-config`, minus logs, `deps`, `tts`, `.cache` | not yet measured |
| `grafana/data` | `grafana` | `/data` → `grafana-config` (minus `grafana.db*`); `/data/grafana.db*` → `grafana-db-besteffort` | PVC `kube-prometheus-stack-grafana`: the service accounts and their tokens, preferences, annotations | not yet measured |

Every snapshot in `theater/configs` also carries the tag `theater-configs`. The
dumps are files named `pg-<app>.dump` (theater) and
`pg-mealie-mealie-postgresql.dump` under `/dumps` in the snapshot.

`seafile/shared` is retained: nothing writes to it or prunes it, and the bucket
policy keeps its versions like any other prefix. Its last snapshots are
`34f34ea0` (tag `seafile-mariadb`, the dump of `ccnet_db`, `seafile_db` and
`seahub_db`, 161 tables) and `8838dac0` (tag `seafile-data`, `/shared` with
`seafile/conf/`). Restore them with `restic restore <id>`; the dump loads into
`mariadb:10.11`.

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
| `immich/immich-db` | Barman Cloud plugin: WAL + `immich-db-daily` | `cnpg/immich-db-t1/` | point-in-time, 30 days |
| `keycloak/keycloak-db` | Barman Cloud plugin: WAL + `keycloak-db-daily` | `cnpg/keycloak-db-t1/` | point-in-time, 30 days |
| `mealie/mealie-postgresql` | Barman Cloud plugin: WAL + `mealie-postgresql-daily`; `pg_dump` in `mealie-backup` | `cnpg/mealie-postgresql-t1/`; `mealie/data` | point-in-time, 30 days; dump consistent, one transaction |
| `theater/{sonarr,radarr,lidarr,prowlarr}-postgresql` | Barman Cloud plugin: WAL + `<cluster>-daily`; `pg_dump` in `theater-postgres-backup` | `cnpg/<cluster>-t1/`; `theater/configs` | point-in-time, 30 days; dump consistent, one transaction |
| `home/home-assistant-postgresql` | Barman Cloud plugin: WAL + `home-assistant-postgresql-daily`; `pg_dump` in `home-assistant-backup` | `cnpg/home-assistant-postgresql/`; `home/configs` | point-in-time, 30 days; dump consistent, one transaction |
| Paperless SQLite | file copy of `db.sqlite3` inside `/data` | `paperless/media` | may be torn: the restic image has no `sqlite3`, so `.backup` is skipped and the job logs a warning |
| Grafana SQLite | file copy of `grafana.db` (and `-wal`/`-shm`) in `grafana-backup` | `grafana/data` | may be torn, tagged `grafana-db-besteffort`; dashboards and datasources are in git |

Each Cluster lists the plugin in `spec.plugins` with `isWALArchiver: true` and
`barmanObjectName: cnpg-backup`, the ObjectStore in its namespace
(`apps/mealie/cnpg-backup.yaml`, `apps/theater/cnpg-backup.yaml`,
`platform/keycloak/backup.yaml`, `apps/immich/resources/backup.yaml`). The plugin
runs as a sidecar (`plugin-barman-cloud`) in each instance pod, so the Postgres
image needs no barman tools; that is why the VectorChord image of `immich-db` works
unchanged. Objects land under `cnpg/<serverName>/base/` and
`cnpg/<serverName>/wals/`. `serverName` is `<cluster>-t1` (new archives since the
Talos cutover), except `home-assistant-postgresql`, whose archive carries its own
name. A WAL segment is archived when it fills or after
`archive_timeout` (5 minutes) if it holds any WAL. Check one cluster:

```sh
kubectl -n mealie get cluster mealie-postgresql \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}{"\n"}'
kubectl -n mealie get objectstore cnpg-backup -o jsonpath='{.status.serverRecoveryWindow}{"\n"}'
kubectl -n mealie get backups.postgresql.cnpg.io
```

Expected: `True`; a `firstRecoverabilityPoint` and `lastSuccessfulBackupTime` for
`mealie-postgresql`; a `mealie-postgresql-daily-<timestamp>` Backup in phase
`completed` from the last night.

Before every sync of `mealie`, `theater`, `home`, `keycloak` and `immich`,
including selfHeal syncs, an Argo CD PreSync hook
(`components/presync-backup`) decides whether a backup is needed:

| Case | Hook does |
|---|---|
| The CronJob or CNPG Cluster does not exist yet (fresh cluster) | nothing |
| The database image changes major version, or the app is `immich` | backs up |
| `mealie`, `theater`, `home`: the backup CronJob last succeeded < 24 h ago | nothing |
| `keycloak`: WAL archiving works and the last base backup is < 24 h old | nothing |
| Otherwise | backs up |

A backup is the app's backup CronJob run once (`mealie`,
`theater`, `home`) or a Barman Cloud base backup (`Backup` `presync-<cluster>`). The
hook waits for it; a failed backup fails the sync, so no database major is
applied without a fresh, verified backup. Postgres majors are
held by a Renovate rule until a major bump also moves the plugin's `serverName`
([Why it is like this](#why-it-is-like-this)).

### Outside the cluster

| What | Where | How |
|---|---|---|
| All eight databases (seven Postgres, Paperless SQLite) | `~/homelab-backups/<utc>/` on the machine that runs it | `task backup:dump`, by hand |
| etcd | `~/homelab-backups/etcd/talos-<utc>.db` | `task talos:etcd-snapshot`, by hand before every upgrade or risky change, [runbooks/cold-start.md](runbooks/cold-start.md#etcd-snapshot-and-restore) |
| Cluster configuration | this repository | every manifest is in git; see [bootstrap.md](bootstrap.md) |

## RPO and RTO

RPO is the most data you can lose. RTO here is what a rehearsed restore took; where
nothing was rehearsed, the column says so.

"Weekly sample" means the required files of each tag plus five sampled files,
restored and size-checked every week ([Verification](#verification)).

| Data | Copies | RPO | Restore tested | RTO |
|---|---|---|---|---|
| Immich originals | S3 + NAS | 24 h | weekly sample; 50-file sample by hand 2026-10-06 | 410 MiB in 8 s. Full library (256 GiB) not rehearsed; at the sample's rate about 1.5 h, plus about $30 of retrieval and egress |
| Immich originals, NAS copy | NAS | 24 h | weekly sample | — |
| Postgres databases (all eight CNPG clusters) | S3 (Barman Cloud) | about 5 min (`archive_timeout`) | weekly, every cluster into a new cluster, row counts equal to the source | 2 to 5 min per cluster into a new cluster (table in [Restore a Postgres cluster from S3](#restore-a-postgres-cluster-from-s3)) |
| Mealie files + database dump | S3 | 24 h | weekly sample; full by hand 2026-10-06 | restore 24 s; dump restored into a throwaway Postgres, row counts equal to live |
| Paperless documents + SQLite | S3 | 24 h | weekly sample | — |
| Syncthing identity + config | S3 | 24 h | weekly sample (`cert.pem`, `key.pem`, `config.xml`) | — |
| *arr, Plex, Jellyfin config and *arr databases | S3 | 24 h | weekly sample (Bazarr from its first snapshot on) | — |
| Audiobookshelf config and database backups | S3 | 24 h | weekly sample | — |
| Home Assistant config | S3 | 24 h | weekly sample | — |
| Ebook library and Calibre-Web config | S3 | 24 h | weekly sample | — |
| Media library | none | everything | — | — |
| Cluster state | git, plus etcd snapshots by hand | last merged commit | no | rebuild, see [bootstrap.md](bootstrap.md) and [runbooks/cold-start.md](runbooks/cold-start.md) |

### Freshness

The 24 h RPO is measured as an SLO (PrometheusRule `homelab-backup-slo`,
`platform/kube-prometheus-stack/routes/backup-slo.yaml`): a backup target is
fresh while its last successful backup is younger than 26 hours, and each
target should be fresh 99% of the time over 30 days (about 7 hours of
staleness a month).

| Kind | Targets | Last success from |
| --- | --- | --- |
| `restic` | the 18 backup CronJobs of `ci/active-cronjobs.txt` (`backup-slo-targets.yaml`, kept equal by repo-policy rule `backup-slo-targets`) | `kube_cronjob_status_last_successful_time`; no series counts as stale |
| `cnpg` | every CloudNativePG cluster | `barman_cloud_cloudnative_pg_io_last_available_backup_timestamp` |

`slo:backup_fresh{kind, namespace, target}` is 1 or 0;
`slo:backup_freshness:ratio_rate30d` is the share of 30 days it was 1. The
Homelab / Data protection dashboard shows both. A restic target stale for 15
minutes pages `BackupNotFresh`
([runbook](runbooks/alerts/BackupNotFresh.md)) whatever the cause, except a
failed Job, which already pages as `KubeJobFailed`; a stale CNPG cluster pages
`CNPGBaseBackupTooOld`. Read it:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 > /dev/null 2>&1 &
PF=$!
sleep 3
curl -s -m 10 http://localhost:9090/api/v1/query --data-urlencode 'query=slo:backup_fresh == 0' |
  jq -r '.data.result[] | "\(.metric.kind) \(.metric.namespace)/\(.metric.target)"'
kill "$PF"
```

Expected: no output when every target is fresh.

## Schedule

All times UTC (the controller's time zone; no CronJob sets `timeZone`). Every job
has `concurrencyPolicy: Forbid`, so a run still going when the next is due causes
that next run to be skipped. One start per slot, so jobs never share the uplink or
the NAS:

| UTC | Job |
|---|---|
| 00:00–01:10 | CNPG base backups (ScheduledBackup `<cluster>-daily`): immich-db 00:00, keycloak-db 00:10, mealie-postgresql 00:20, sonarr 00:30, radarr 00:40, lidarr 00:50, prowlarr 01:00, home-assistant-postgresql 01:10 |
| 01:30 | `immich/immich-library-backup-local` (NAS) |
| 02:00 | `syncthing/syncthing-backup` |
| 02:30 | `paperless/paperless-backup` |
| 03:20 | `mealie/mealie-backup` |
| 03:30 | `immich/immich-library-backup` (S3) |
| 03:40 | `theater/theater-postgres-backup` |
| 04:00–04:40 | `theater/theater-config-backup-{sonarr,radarr,lidarr,prowlarr,plex}`, ten minutes apart |
| 04:50 | `theater/theater-config-backup-bazarr` |
| 05:00 | `theater/theater-config-backup-jellyfin` |
| 05:10 | `books/books-config-backup-audiobookshelf` |
| 05:20 | `books/books-config-backup-calibre-web` |
| 05:30 | `theater/theater-config-backup-lazylibrarian` |
| 05:40 | `home/home-assistant-backup` |
| 05:50 | `monitoring/grafana-backup` (keeps its own 7 daily / 4 weekly / 6 monthly; no prune job) |
| 1st of the month, 12:00–13:45 | `*-prune`: syncthing 12:00, mealie 12:15, paperless 12:30, theater 13:00, books 13:15, immich 13:30, home 13:45 |

The theater jobs share one repository and restic takes an exclusive lock for
`backup`, hence the spacing. Each nightly job ends with
`restic check`. The running set is listed in `ci/active-cronjobs.txt`; CI fails any
other rendered CronJob that is not suspended.

The restore tests run on weekend evenings, outside this window and one at a
time: `backup-verify-lock` Saturday 20:00, `backup-verify-files` Saturday
22:00, `backup-verify-postgres` Sunday
21:00 ([Verification](#verification)).

A failed backup Job fires the stock `KubeJobFailed` rule from kube-prometheus-stack.
For Postgres, PrometheusRule `cnpg-backups` (group `cnpg.backups`, in
`platform/barman-cloud-plugin/monitoring.yaml`, scraped by PodMonitor
`cnpg-instances`) fires `CNPGBackupFailed`, `CNPGBaseBackupTooOld` (no base backup
in 26 h, or never), `CNPGBackupMetricsMissing` (an instance without the plugin
sidecar), `CNPGWALArchivingFailing`, `CNPGWALArchiveLag` (more than 5 segments
waiting for 30 min) and `CNPGMetricsAbsent`. All of them notify on ntfy
(`action: human`), as does a failed `*-backup-*` Job (`KubeJobFailed`)
([sre.md](sre.md#paging)).

```sh
kubectl get cronjobs -A | grep -E 'backup|prune'   # 29 lines, SUSPEND False
kubectl get jobs -A | grep -E 'backup|prune'       # after 05:30 UTC: every job Complete
```

## Retention

| Repository | Nightly job | Monthly `*-prune` job |
|---|---|---|
| `immich/library`, `mealie/data`, `theater/configs`, `home/configs` | backup + check | `forget --keep-within 3m --keep-monthly 12 --prune`, then check |
| `paperless/media`, `syncthing/data` | backup + check | `forget --keep-within 3m --keep-monthly 24 --prune`, then check |
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

### Restore a Postgres cluster from S3

Restores go into a **new** Cluster, never over the live one. The scripted test
restores one cluster into the scratch namespace `cnpg-restore-test`, compares the
row count of every table with the source, and deletes the namespace again. It only
reads the source, and the restored cluster has no `spec.plugins`, so it cannot
write to the bucket. It needs an `aws login` session for the verifier key:

```sh
aws login --profile homelab --region eu-central-1
task backup:verify-barman -- mealie mealie-postgresql
```

Expected, after two to ten minutes:

```text
… L1 at <time> (LSN <lsn>, WAL <file>): 69 tables, 608 rows
… restore Ready after 1xx s
tables=69 rows L1=608 R=608 L2=608 failing=0
… VERDICT mealie/mealie-postgresql: PASS
… cleanup: cnpg-restore-test deleted
```

Any `FAIL <table>` line, or a namespace left behind, is a failed test. Results of
the last run, per cluster:

| Cluster | Tables | Rows (restored = source) | Restore time |
|---|---|---|---|
| `immich-db` | 60 | 750,652; assets 48,833 images / 2,311 videos | 295 s |
| `keycloak-db` | 101 | 1,823 | 117 s |
| `mealie-postgresql` | 69 | 608 | 104 s |
| `sonarr-postgresql` | 38 | 39,054 | 149 s |
| `radarr-postgresql` | 41 | 58,302 | 154 s |
| `lidarr-postgresql` | 40 | 77 | 110 s |
| `prowlarr-postgresql` | 20 | 6,496 | 149 s |

Last run 2026-10-13. A quiet database adds up to 7.5 minutes before the restore
starts: the script waits for the WAL file of its snapshot to be archived.

To recover by hand, for example `immich-db` to a point in time, create the
verifier Secret and the two objects below in a namespace of your choice, with the
source's image and `shared_preload_libraries`
(`kubectl -n immich get cluster immich-db -o jsonpath='{.spec.imageName} {.spec.postgresql.shared_preload_libraries}'`):

```sh
kubectl create namespace restore-test
printf 'verifier key id: '; read -rs KEY_ID; echo
printf 'verifier secret: '; read -rs KEY_SECRET; echo
kubectl -n restore-test create secret generic cnpg-restore-s3 \
  --from-literal=ACCESS_KEY_ID="$KEY_ID" --from-literal=ACCESS_SECRET_KEY="$KEY_SECRET"
unset KEY_ID KEY_SECRET
```

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: cnpg-restore
  namespace: restore-test
spec:
  configuration:
    destinationPath: s3://ned-si-homelab-backups/cnpg
    endpointURL: https://s3.eu-central-1.amazonaws.com
    s3Credentials:
      accessKeyId: { name: cnpg-restore-s3, key: ACCESS_KEY_ID }
      secretAccessKey: { name: cnpg-restore-s3, key: ACCESS_SECRET_KEY }
    wal:
      compression: gzip
  instanceSidecarConfiguration:
    env:
      - { name: AWS_DEFAULT_REGION, value: eu-central-1 }
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: immich-db-restored
  namespace: restore-test
spec:
  instances: 1
  # The image of apps/immich/resources/database.yaml. A target before
  # 2026-10-16 08:37 UTC (pgvecto.rs) needs cloudnative-pgvecto.rs:16.5-v0.3.0
  # with ["vectors.so"] instead.
  imageName: ghcr.io/tensorchord/cloudnative-vectorchord:16.15-1.1.1@sha256:f5a17fa05faf25e81304ee95e9f920d8ae077ac4a4ef0a1251e09c7197cbb236
  postgresql:
    shared_preload_libraries: ["vchord.so"]
  storage: { size: 5Gi, storageClass: iscsi }
  bootstrap:
    recovery:
      source: origin
      database: app
      owner: app
      recoveryTarget:
        targetTime: "<YYYY-MM-DD HH:MM:SS+00>"   # omit to replay all archived WAL
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: cnpg-restore
          serverName: immich-db-t1   # the SOURCE cluster's serverName
```

Expected: `kubectl -n restore-test wait --for=condition=Ready cluster/immich-db-restored --timeout=45m`
returns `condition met`. The target time must lie inside the source's recovery
window (`kubectl -n immich get objectstore cnpg-backup -o jsonpath='{.status.serverRecoveryWindow}'`)
and its WAL must already be archived. Recovery to a time also needs a commit after
the target in the archived WAL; on an idle database it fails (exit code 4). Use
`targetLSN` then, as `scripts/verify-barman-restore.sh` does. Delete the namespace
when done.

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
- **Replacing a live Postgres cluster with a restored one.** Every rehearsal above
  restores into a new cluster in a scratch namespace. Pointing an app at a restored
  cluster (or recreating its Cluster from the backup) is not rehearsed.
- **`immich-db` from a local dump.** Its image is
  `cloudnative-vectorchord:16.15-1.1.1` (PostgreSQL 16 with VectorChord); restore
  into a cluster with exactly that image, or `cloudnative-pgvecto.rs:16.5-v0.3.0`
  for a dump from before 2026-10-16. `task backup:verify-restore -- immich
  immich-db <dump>` derives the image from the source cluster.

## Consistency, per tag

Nothing quiesces before a backup. Every Application except `immich` runs
`selfHeal: true`, so Argo CD would revert `replicas: 0` within seconds and restart
the app mid-backup.

**Consistent.** The `pg_dump` snapshots.
Content-addressed, write-once files: the Immich library, Mealie
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

**Seafile (retained repository) needs both halves.** The blobs are hash-named
files; the MariaDB dump is the index that maps them to files, libraries and
owners. Restore `34f34ea0` and `8838dac0` together.

## The bucket

Created by [`bootstrap/aws-backup/`](../bootstrap/aws-backup/main.tf) (OpenTofu),
applied by the `tofu` workflow ([bootstrap.md](bootstrap.md#drift-detection)).
Versioning on, public access blocked, SSE-S3, TLS only, and immutable versions
([below](#immutable-versions)).

| Prefix | Contents | Storage class |
|---|---|---|
| `<repository>/data/` | restic pack files | Glacier Instant Retrieval after 1 day |
| `<repository>/` everything else | restic `config`, `keys/`, `index/`, `snapshots/`, `locks/` | Standard: read on every restic operation |
| `cnpg/<serverName>/base/`, `cnpg/<serverName>/wals/` | Barman Cloud base backups and WAL of each CNPG cluster; the plugin deletes what falls out of its 30-day retention | Standard |

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
| `ned-si-homelab-backups-verifier` | restores, drills and the lock test | get objects and versions, list the bucket, write only under `*/locks/` and `_lock-test/`; delete versions under `_lock-test/` (refused by the bucket policy, which is the test); read the bucket policy |
| `ned-si-homelab-backups-cnpg` | the Barman Cloud plugin, via `cnpg-backup-s3` | get, put and delete objects under `cnpg/` only; list the bucket only without a prefix or with `cnpg/*` |
| `homelab-metrics-reader` | the AWS dashboard, via `aws-exporter` | list the bucket (no object reads); read CloudWatch metrics and Cost Explorer |

The writer and the cnpg user have an explicit `Deny` on `s3:DeleteObjectVersion`, versioning,
lifecycle, bucket policy, ACL, encryption and bucket deletion. With versioning on, a
delete by the writer only adds a delete marker, and the previous version stays for
30 days. A test delete of a specific version with the writer key returns
`AccessDenied`.

### Immutable versions

The bucket policy extends that to every principal in the account, admin
sessions and the CI roles included:

| Statement | Denies | To |
|---|---|---|
| `DenyVersionDestruction` | `s3:DeleteObjectVersion`, `s3:PutBucketVersioning`, `s3:DeleteBucket` | everyone |
| `RetentionRulesFromCiOnly` | `s3:PutLifecycleConfiguration`, `s3:PutBucketPolicy`, `s3:DeleteBucketPolicy` | everyone but `homelab-github-tofu-apply` |
| `DenyInsecureTransport` | any request without TLS | everyone |

So a delete, by anyone, adds a delete marker; the old version stays until the
30-day noncurrent lifecycle rule expires it (S3 runs lifecycle itself, outside
bucket policies). Restic prune, the Barman Cloud retention and the verify
jobs only issue plain deletes, so they work unchanged. Changing the lifecycle
or the policy is a pull request: the `tofu` workflow applies it on merge.

How it is proven:

- **Live test, 2026-10-16.** An object under `_lock-test/` written twice by
  the writer key, then a delete of its older version (`delete-object
  --version-id`) with the writer key, the verifier key and the account root
  user: all three got `AccessDenied ... with an explicit deny in a
  resource-based policy`. A plain delete by the writer added a delete
  marker; both versions are still there and expire with the lifecycle rule.
- **Weekly, in the cluster.** CronJob `backup-verify-lock` (Saturday 20:00
  UTC) does the same with the verifier key on `_lock-test/weekly`. That key is
  allowed `s3:DeleteObjectVersion` there, so only the bucket policy refuses
  it. It also reads the policy and checks for an unconditional `Deny` of
  `s3:DeleteObjectVersion` to every principal on every object. Result:
  `backup_verify_lock_ok`; `BackupLockBroken` (critical, ntfy) when the delete
  succeeds or the statement is missing ([When the lock test fails](#when-the-lock-test-fails)).
- **On every pull request.** repo-policy `backup-bucket-lock` fails if
  `aws_s3_bucket_policy.backups` stops using
  `data.aws_iam_policy_document.bucket`, or that document loses its
  unconditional `Deny` of `s3:DeleteObjectVersion`, `s3:PutBucketVersioning`
  and `s3:DeleteBucket` to principal `*` on the bucket and its objects. The
  daily `tofu` plan catches the live policy drifting from the code.

By hand (expected: `AccessDenied`, on a key that does not exist):

```sh
aws s3api delete-object --profile homelab --bucket ned-si-homelab-backups \
  --key policy-check/none --version-id null
```

Break-glass (purging versions, emergency lifecycle change): sign in to the
AWS console as the account root user, which S3 always lets manage a bucket
policy; delete the bucket policy, do the change, then re-run the `tofu`
workflow (`gh workflow run tofu.yaml`), which puts the policy back.

Accepted limit: the account root user can remove the policy and then delete
versions. Only S3 Object Lock in compliance mode stops root, at the cost of
locking every version, and the bucket, for the whole retention period.

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
  or risky change: `task talos:etcd-snapshot`
  ([talos-cheatsheet.md](talos-cheatsheet.md#etcd-snapshots)).

## Local dumps and pre-upgrade snapshots

```sh
task backup:dump      # -> ~/homelab-backups/<utc>/, all eight databases, verified

task backup:verify-restore -- immich immich-db \
  ~/homelab-backups/<utc>/pg-immich-immich-db.dump
```

`backup:dump` dumps the seven Postgres clusters and Paperless'
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

Every nightly job ends with `restic check` (structure: snapshots, trees and blob
index, not the pack contents). On top of that, the Application `backup-verify`
(`platform/backup-verify/`, namespace `backup-verify`) restores every backup on a
schedule and compares the result. It only reads: S3 through the verifier key in
`backup-verify/s3-backup` (which writes nothing outside `*/locks/` and
`_lock-test/`), the NAS repository mounted read-only, restic with `--no-lock`,
and the production databases through read-only transactions.

| CronJob (UTC) | What it proves | Pass when |
| --- | --- | --- |
| `backup-verify-lock`, Saturday 20:00 | an old version in the bucket cannot be deleted ([Immutable versions](#immutable-versions)) | the delete of the older version of `_lock-test/weekly` is refused by the bucket policy, and the policy still denies `s3:DeleteObjectVersion` to every principal |
| `backup-verify-files`, Saturday 22:00 | per tag in `scripts/restic-targets.txt`: the newest snapshot restores, with `restic restore --verify`, into an emptyDir | the snapshot is at most 72 h old, every required file (identity, keys, configs, dumps) is in it and non-empty, and the required files plus five sampled files of up to 64 MiB (a different sample every ISO week) restore with the size the snapshot records |
| the same job, first Saturday of the month | `restic check --read-data-subset=<n>/<slices>` on every repository in `scripts/restic-data-targets.txt` | no errors; the slice rotates monthly, so every pack is read once every 12 months (S3 `immich/library`: 1/120 a month, about 2.3 GiB) |
| `backup-verify-postgres`, Sunday 21:00 | each CNPG cluster in `scripts/postgres-targets.txt`, one at a time, recovers from its Barman Cloud archive into a new Cluster `bv-<cluster>` | the restored database has the same tables and, in every table, the same row count as the source at the recovery target (its LSN); `immich-db` also holds at least 49,032 images and 2,377 videos |

The Postgres test reads the source's image, preload libraries, volume size and
`serverName` (`<cluster>-t1` since the Talos cutover, `home-assistant-postgresql`
for Home Assistant) from its Cluster, counts its rows as the database owner, waits
up to 7.5 minutes for the WAL of that moment to be archived, and recovers to that
LSN through ObjectStore `verify-source`. The restore has no `spec.plugins`, so it
cannot write to the bucket, and runs on an `iscsi` volume the size of the source's
(5 Gi), deleted with the Cluster before the next one starts. The run takes about
an hour. The restic test uses only emptyDirs (4 Gi at most).

### Reading the results

Grafana dashboard Homelab / Data protection (`/d/homelab-data-protection`)
shows the last result of every check next to the backup freshness. Each check
pushes its result to the Pushgateway in `backup-verify`, which Prometheus
scrapes. Labels: `check` (`restic`, `restic-data`, `postgres`)
and `target` (the tag, repository or cluster).

| Metric | Meaning |
| --- | --- |
| `backup_verify_success` | 1 if the last run passed, 0 if it failed |
| `backup_verify_last_success_timestamp_seconds` | end of the last passing run |
| `backup_verify_last_run_timestamp_seconds`, `backup_verify_duration_seconds` | end and length of the last run |
| `backup_verify_snapshot_timestamp_seconds` | time of the backup that was tested |
| `backup_verify_rows`, `backup_verify_tables` | rows and tables restored and compared (Postgres) |
| `backup_verify_files`, `backup_verify_bytes` | files and bytes restored (restic) |
| `backup_verify_restore_seconds` | time to a Ready restored cluster (Postgres) |
| `backup_verify_lock_ok` | lock test (`check="lock"`): 1 the version delete was refused by the bucket policy, 0 it succeeded or the deny is gone; not pushed by an inconclusive run |
| `backup_verify_lock_last_success_timestamp_seconds`, `backup_verify_lock_last_run_timestamp_seconds` | end of the last passing and of the last lock test |

Alerts (PrometheusRule `backup-verify`, group `backup.verify`, all `warning`
and all notify on ntfy, [sre.md](sre.md#paging)):
`BackupVerifyFailed` (a check's last run failed), `BackupVerifyStale` (no
pass in 8 days), `BackupVerifyDataStale` (no monthly pack read in 36 days) and
`BackupVerifyMissing` (no passing result of a check at all). A Job that crashes
before pushing also fires the stock `KubeJobFailed`. Group `backup.lock`:
`BackupLockBroken` (`critical`, notifies) and `BackupLockCheckStale`
(`warning`, no passing lock test in 8 days or none on record).

```sh
kubectl -n backup-verify get cronjobs,jobs
kubectl -n backup-verify logs job/<job> --all-containers | grep -E 'PASS|FAIL|changed'
```

Expected: one `PASS <target>` line per target and a final `ALL ... PASSED`. Run a
test now, for example after changing a backup job:

```sh
kubectl -n backup-verify create job --from=cronjob/backup-verify-postgres verify-now
```

### When a restore test fails

1. Read the `FAIL` lines of the Job (above). They name the target and the
   reason: no or stale snapshot, a missing or empty required file, a size
   mismatch, a restore that did not become Ready, a table or row count that
   differs, Immich below its floor.
2. A stale snapshot or a missing file is a backup problem: check that app's
   backup CronJob and its last Job log ([Schedule](#schedule)).
3. A failed restore or a count mismatch is a restore problem: restore the same
   backup by hand ([How to restore](#how-to-restore),
   [Restore a Postgres cluster from S3](#restore-a-postgres-cluster-from-s3))
   and compare. Treat it as data at risk until a restore passes.
4. A one-row mismatch on a busy table (an *arr history or command table) can
   come from a commit between the count and the WAL position read in the
   same statement; it is not a backup fault if the next run passes.
5. Leftovers: a `bv-<cluster>` Cluster in `backup-verify` is removed by the next
   run; delete it by hand with
   `kubectl -n backup-verify delete cluster.postgresql.cnpg.io bv-<cluster>`.

To add a target, add a line to the matching file in
`platform/backup-verify/scripts/`; a new Postgres cluster also needs its Cluster
and `-app` Secret names in ClusterRole `backup-verify-sources` (`rbac.yaml`). A
removed target keeps its last result in the Pushgateway and goes stale after 8
days; delete its group:

```sh
kubectl -n backup-verify port-forward svc/pushgateway 9091:9091 &
curl -m 10 -X DELETE http://localhost:9091/metrics/job/backup-verify/check/<check>/target/<target>
kill %1
```

Expected: no output; the group is gone from `http://localhost:9091`.

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

### When the lock test fails

```sh
kubectl -n backup-verify logs job/<job> -c report
```

- `BROKEN: DeleteObjectVersion ... succeeded`, `BROKEN: the bucket has no
  policy` or `BROKEN: no unconditional Deny ...`: the bucket no longer
  protects old versions. Run the `tofu` workflow (`gh workflow run
  tofu.yaml`), which re-applies the policy, and check it with `aws s3api
  get-bucket-policy --profile homelab --bucket ned-si-homelab-backups`. Then
  find who changed it (CloudTrail `PutBucketPolicy`/`DeleteBucketPolicy`
  events) and rotate the keys if it was not you. A new run must log `OK`:
  `kubectl -n backup-verify create job --from=cronjob/backup-verify-lock lock-now`.
- `INCONCLUSIVE`: the verifier key could not write `_lock-test/weekly` or read
  the policy, or the delete was refused by something other than the bucket
  policy (for example the verifier's IAM policy not applied). Only the run
  time is pushed; `BackupLockCheckStale` fires after 8 days without a pass.

## Known gaps

- The weekly file tests restore a sample, not whole repositories; full reads
  are monthly slices (yearly for the NAS copy, ten years for S3
  `immich/library`) plus the [annual full read](#verification) by hand.
- Postgres majors are held by Renovate until a major bump also moves the plugin's
  `serverName` to `<cluster>-pg<major>`.
- SQLite files in restic (Paperless, Audiobookshelf, Calibre) are restored and
  size-checked, not opened: a torn copy passes. `jellyfin-db-besteffort` is
  not tested.
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
- **Restore tests in the cluster, results through a Pushgateway.** A restore
  that runs on a schedule and alerts is the only kind that keeps being done.
  Batch jobs cannot be scraped, so they push; the alerts read Prometheus'
  history, so a restarted Pushgateway changes nothing. The Postgres test
  recovers to the LSN of its source count, so every table must match exactly
  rather than within a tolerance. Rejected: restoring whole restic repositories
  weekly, which would cost more in Glacier IR retrieval and egress than the
  storage itself.
- **Backup CronJobs run only once reviewed.** A job runs unsuspended only when it
  is listed in `ci/active-cronjobs.txt`, which happens once its credentials are
  real and its first run has been seen to work. Every other CronJob ships suspended
  behind a `pending-guard` init container, so a placeholder bucket can never look
  like a working backup.
- **Postgres through the Barman Cloud plugin, not the in-tree
  `barmanObjectStore`.** CNPG deprecated the in-tree support in 1.26; the plugin is
  the supported path. Its sidecar carries the barman tools, so the VectorChord image
  of `immich-db` needs no change. The Mealie and *arr `pg_dump`s stay as a second,
  independent copy.
- **The plugin runs in `immich`.** It must share the operator's namespace, and the
  operator is still there. Moving both to `cnpg-system` is a separate change.
- **A separate IAM user scoped to `cnpg/`.** A database pod never holds a key that
  can reach the restic repositories, and the restic jobs never hold one that can
  reach the WAL. barman checks the bucket with HeadBucket, which IAM authorises as
  `ListBucket` without a prefix, so listing is allowed without a prefix or under
  `cnpg/*` (key names only; objects outside `cnpg/` stay unreadable).
- **`cnpg/` in Standard, 30 days.** WAL is a stream of small objects with constant
  churn; Glacier IR's 90-day minimum would bill every segment three times over. The
  plugin, not a lifecycle rule, deletes old backups, because only it knows which WAL
  a base backup still needs.
- **Postgres majors wait for `serverName`.** pg_upgrade gives the cluster a new
  system ID and restarts at timeline 1; the plugin does not separate archives, so
  the upgraded cluster would overwrite the old timeline-1 WAL unless `serverName`
  changes in the same commit, and PostgreSQL 17 before 17.6 needs the 17.6+ minor
  first ([CNPG upgrade docs](https://cloudnative-pg.io/docs/1.27/postgres_upgrades/)).
  Renovate holds `ghcr.io/cloudnative-pg/postgresql` majors until a bump does both.
  Rejected: approving majors by hand.
- **`Retain` on data PVs plus `iscsi-retain` for new ones**, rather than changing
  `iscsi`: a StorageClass's reclaim policy is immutable, and changing an existing
  claim's class means copying its data.
- **One bucket, Glacier IR on `data/` only.** Cheap storage for packs while every
  restic read keeps working. Rejected: Deep Archive, about four times cheaper, but
  every read needs an hours-long thaw that restic cannot do.
- **Versioning plus a bucket policy that denies version deletion, not Object
  Lock.** No key, role or admin session in the account can make a deletion
  permanent, and every noncurrent version is kept for its full 30 days. Object
  Lock default retention counts from each version's creation, so an old restic
  pack pruned today would get none; it makes every upload require a checksum
  header (a new failure mode for WAL archiving); and it cannot be turned off.
  Compliance mode would also stop the root user, at the cost of locking the
  bucket for the retention period.
- **Retention in months.** Glacier IR bills 90 days per object, so pruning sooner
  saves nothing.
- **No quiescing.** Argo CD `selfHeal` reverts any scale-down. Live SQLite copies
  are documented as possibly torn instead, and Jellyfin's gets its own
  `jellyfin-db-besteffort` tag. The proper fix is snapshot-then-backup (CSI
  `VolumeSnapshot` or VolSync), not built yet.
- **The media library is not backed up.** About 9.5 TB of re-acquirable content;
  off-site storage and egress cost more than it is worth.
