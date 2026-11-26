# Design: dashboard-database-engines

Extends [homelab-dashboard, Databases](../homelab-dashboard/design.md#databases-tasks-25-and-26).
Everything not said here works as it does for PostgreSQL there.

## What exists

Checked on 2026-11-26 around 15:00Z (`kubectl get`, read-only, and
Grafana's Prometheus datasource). No engine exporter is scraped
(`redis_*`, `valkey_*` and `chi_*` have no series), so "up" comes from
kube-state-metrics for every engine.

| Engine | Where | Backup |
| --- | --- | --- |
| SQLite, 9 apps | Paperless-ngx (`db.sqlite3`), Audiobookshelf (`absdatabase.sqlite`), Calibre-Web (`app.db`, the library's `metadata.db`), Grafana (`grafana.db`), SigNoz (`signoz.db`), Jellyfin (`jellyfin.db`), Plex (its library databases) and 2 hidden apps | One restic CronJob per app, nightly to S3, watched by `slo:backup_fresh{kind="restic"}`; the weekly restore test (`backup-verify-files`) requires the database file for Paperless, Audiobookshelf, Calibre-Web and Grafana |
| Valkey 9.2, 2 | `apps/immich/resources/valkey.yaml`, `apps/paperless/valkey.yaml`: job queue and Celery broker, Deployments with no volume | None: in memory, rebuilt by the app |
| Redis 8.6, 1 | The Argo CD chart's `argocd-redis`, a cache | None |
| ClickHouse, 1 | `platform/signoz/values.yaml`, the Altinity operator, 50 GiB on `iscsi` | None, by decision ([docs/backups.md](../../../docs/backups.md#what-is-not-backed-up)) |

Left out of SQLite: Syncthing's index database (rebuilt by a rescan and
excluded from its backup) and the hidden apps' `logs.db` (disposable,
excluded). Consistency of the live copies is #746's subject.

## Inventory

Nothing detects an SQLite file from outside the pod, so the SQLite apps
are a static series per app, as `slo:backup_target:info` lists the
restic CronJobs in `backup-slo-targets.yaml`. Labels: `namespace`,
`container` (the container that owns the file), `cronjob` (its restic
CronJob, the `target` of `slo:backup_fresh`) and `restore_target` (the
`target` of `backup_verify_*{check="restic"}` whose required files
include the database file; absent when none does).

| namespace | container | cronjob | restore_target |
| --- | --- | --- | --- |
| `paperless` | `paperless` | `paperless-backup` | `paperless-db` |
| `books` | `audiobookshelf` | `books-config-backup-audiobookshelf` | `audiobookshelf` |
| `books` | `calibre-web` | `books-config-backup-calibre-web` | `calibre-web` |
| `monitoring` | `grafana` | `grafana-backup` | `grafana-db` |
| `signoz` | `signoz` | `signoz-backup` | |
| `theater` | `jellyfin` | `theater-config-backup-jellyfin` | |
| `theater` | `plex` | `theater-config-backup-plex` | |
| `theater` | 2 rows, one per hidden app, their container and `theater-config-backup-<app>` | | |

Calibre-Web's restore target is `calibre-web` (`app.db`); the library's
`metadata.db` is a second target of the same app, and the app counts once.

## Recording rules (task 1)

PrometheusRule `homelab-databases` in
`platform/kube-prometheus-stack/routes/databases.yaml`. A third group
after `homelab.databases`, and four rules at the end of
`homelab.databases.restore`. Per-instance rules are keyed by `engine`,
`namespace` and `container`; the dashboard reads only the label-free
`cluster:*` aggregates.

Two choices keep it cheap: the 24-hour window reads the instance rule
`db_engine:present` (13 series), not `kube_pod_container_info` (every
container of the cluster); and up reads the last 10 minutes of
`kube_pod_container_status_ready`.

```yaml
    - name: homelab.databases.engines
      interval: 1m
      rules:
        - record: db_sqlite:app:info
          expr: vector(1)
          labels: {namespace: paperless, container: paperless, cronjob: paperless-backup, restore_target: paperless-db}
        # ... one rule per row of the inventory
        # 1 per instance now: SQLite by the inventory, the servers by image.
        - record: db_engine:present
          expr: |
            label_replace(
              group by (namespace, container) (kube_pod_container_info)
              and on (namespace, container) db_sqlite:app:info,
              "engine", "sqlite", "", "")
            or label_replace(
              group by (namespace, container) (kube_pod_container_info{image_spec=~"(.+/)?(valkey|redis)[:@].+"}),
              "engine", "valkey_redis", "", "")
            or label_replace(
              group by (namespace, container) (kube_pod_container_info{image_spec=~"(.+/)?clickhouse-server[:@].+"}),
              "engine", "clickhouse", "", "")
        # The denominator: an instance that goes away still counts for 24 h.
        - record: db_engine:seen_24h
          expr: group by (engine, namespace, container) (max_over_time(db_engine:present[24h]))
        # Down after 10 minutes not ready, as cnpg_cluster:up.
        - record: db_engine:up
          expr: |
            db_engine:seen_24h * on (namespace, container)
              max by (namespace, container) (max_over_time(kube_pod_container_status_ready[10m]))
            or on (engine, namespace, container) (db_engine:seen_24h * 0)
        - record: db_sqlite:backup_fresh
          expr: |
            label_replace(db_sqlite:app:info, "target", "$1", "cronjob", "(.+)")
              * on (namespace, target) slo:backup_fresh{kind="restic"}
        - record: cluster:sqlite_databases:count
          expr: count(db_engine:seen_24h{engine="sqlite"}) or vector(0)
        - record: cluster:sqlite_databases_up:count
          expr: sum(db_engine:up{engine="sqlite"}) or vector(0)
        - record: cluster:sqlite_backup_fresh:count
          expr: |
            sum(db_sqlite:backup_fresh and on (namespace, container) db_engine:seen_24h{engine="sqlite"})
            or vector(0)
        - record: cluster:valkey_redis_instances:count
          expr: count(db_engine:seen_24h{engine="valkey_redis"}) or vector(0)
        - record: cluster:valkey_redis_instances_up:count
          expr: sum(db_engine:up{engine="valkey_redis"}) or vector(0)
        - record: cluster:clickhouse_instances:count
          expr: count(db_engine:seen_24h{engine="clickhouse"}) or vector(0)
        - record: cluster:clickhouse_instances_up:count
          expr: sum(db_engine:up{engine="clickhouse"}) or vector(0)
```

At the end of `homelab.databases.restore` (every 2 minutes), the same
logic as `cluster:cnpg_restore_passed:count` and `_failed:count`, keyed
by app:

```yaml
        - record: db_sqlite:restore_last_run:timestamp
          expr: |
            label_replace(db_sqlite:app:info{restore_target!=""}, "target", "$1", "restore_target", "(.+)")
              * on (target)
            max by (target) (max_over_time(backup_verify_last_run_timestamp_seconds{check="restic"}[8d]))
        - record: db_sqlite:restore_last_success:timestamp
          expr: |
            label_replace(db_sqlite:app:info{restore_target!=""}, "target", "$1", "restore_target", "(.+)")
              * on (target)
            max by (target) (max_over_time(backup_verify_last_success_timestamp_seconds{check="restic"}[8d]))
        - record: cluster:sqlite_restore_passed:count
          expr: |
            count(
              (db_sqlite:restore_last_success:timestamp >= on (namespace, container) db_sqlite:restore_last_run:timestamp)
              and on (namespace, container) (time() - db_sqlite:restore_last_success:timestamp < 8 * 86400)
              and on (namespace, container) db_engine:seen_24h{engine="sqlite"}
            ) or vector(0)
        - record: cluster:sqlite_restore_failed:count
          expr: |
            count(
              (
                (db_sqlite:restore_last_run:timestamp > on (namespace, container) db_sqlite:restore_last_success:timestamp)
                or (db_sqlite:restore_last_run:timestamp unless on (namespace, container) db_sqlite:restore_last_success:timestamp)
              )
              and on (namespace, container) db_engine:seen_24h{engine="sqlite"}
            ) or vector(0)
```

Expected today: 9, 9, 9, 4, 0, 3, 3, 1, 1.

Tests: new cases at the end of `tests/prometheus/databases_test.yaml`,
the list of [acceptance criterion 1](requirements.md#acceptance-criteria).
`slo:backup_fresh` is an input series there, so the test needs no other
rule file. `docs/backups.md`: the new aggregates in "Reading the results",
and Valkey and Redis in "What is not backed up".

## The snapshot (task 2)

`Version` is main's value plus one. Nine integers join
`cluster.databases`, each in the schema's `required` list:

| Key | Rule | Bound in `Validate` |
| --- | --- | --- |
| `sqlite_count` | `cluster:sqlite_databases:count` | 0-100 |
| `sqlite_up` | `cluster:sqlite_databases_up:count` | at most `sqlite_count` |
| `sqlite_backup_fresh` | `cluster:sqlite_backup_fresh:count` | at most `sqlite_count` |
| `sqlite_restore_passed`, `sqlite_restore_failed` | `cluster:sqlite_restore_passed:count`, `_failed:count` | their sum at most `sqlite_count` |
| `valkey_redis_count`, `valkey_redis_up` | `cluster:valkey_redis_instances:count`, `_up:count` | 0-100, up at most count |
| `clickhouse_count`, `clickhouse_up` | `cluster:clickhouse_instances:count`, `_up:count` | 0-100, up at most count |

The collector adds them to `databaseCounts` (a missing rule reads 0) and
clamps them in `clampDatabases`, as for PostgreSQL: the two rule groups
run up to 2 minutes apart.

## The tiles

`engineTiles(d)` in `render.go` returns four tiles, filled next to
`Databases` as the view's `Engines` field. In `page.html` the second
paragraph and a second `div.tiles` follow the PostgreSQL tiles, before
the "as of" line.

| Tile | Value | Status | Details |
| --- | --- | --- | --- |
| SQLite | `<n> apps` (`1 app`) | `databasesStatus(sqlite_up, sqlite_count)` | Seen in the rolling 24 h; `<up> up` |
| SQLite backups | `<fresh> of <n>` | `sqliteBackupStatus` below | Nightly to S3, each in the rolling 26 h; `<passed> passed the weekly restore test, rolling 8 days` |
| Valkey and Redis | `<n> instances` (`1 instance`) | `databasesStatus(valkey_redis_up, valkey_redis_count)` | Seen in the rolling 24 h; `<up> up`; In memory, not backed up |
| ClickHouse | `<n> instances` (`1 instance`) | `databasesStatus(clickhouse_up, clickhouse_count)` | Seen in the rolling 24 h; `<up> up`; Logs and traces expire, not backed up |

A tile whose count is 0 is `noDataTile` ("No data", status none); the
SQLite backups tile follows `sqlite_count`.

| Rule | ok | warn | bad |
| --- | --- | --- | --- |
| `sqliteBackupStatus(fresh, failed, count)` | `fresh` equal to `count` and `failed` 0: "Fresh" | — | `fresh` below `count`: "Stale" (`BackupNotFresh`, 26 h); otherwise `failed` above 0: "Failed" (`BackupVerifyFailed`) |

No warn band: a backup older than 26 hours already pages. Up is the
10-minute grace before Down, not a reporting window, so its window is not
named, as for PostgreSQL.

## Strings

The PostgreSQL paragraph's first sentence becomes "Each PostgreSQL
database is its own CloudNativePG cluster." The second paragraph:

> The apps that keep their database in SQLite, a file in the app's
> volume, are copied to S3 every night with restic. Most copies are
> taken while the app runs, and the weekly restore test checks the
> database files it covers. Valkey, Redis and ClickHouse hold queues,
> caches and telemetry that are rebuilt or expire, so they are not
> backed up.

New catalogue keys, in English and French: the four labels, the units
`app`/`apps` (existing) and `instance`/`instances`, the detail lines of
[The tiles](#the-tiles), the second paragraph and the changed sentence.
Reused: "Seen in the rolling 24 h", Up, Down, Fresh, Stale, Failed, "No
data". The French is the operator's correction of the coder's proposal
(Requirement 5.2), recorded in the task 2 PR.

## Privacy

- The inventory names apps in the rule file only, as
  `backup-slo-targets.yaml` already does; those labels stay in
  Prometheus.
- The collector's nine queries are bare rule names.
- The page names engines only. The paragraph enumerates no app.
- Tests: `TestDatabasesNumbersOnly`, `TestDatabasesNameNothing` and the
  hidden-name check over the full fixture and the goldens include the
  new keys and tiles.
