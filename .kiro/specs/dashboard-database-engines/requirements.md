---
kind: change
status: active
created: 2026-11-26
issue: 1771
---

# Requirements: dashboard-database-engines

## Introduction

The "Databases and backups" group of the dashboard's Cluster card
([homelab-dashboard Requirement 14](../homelab-dashboard/requirements.md#requirement-14-databases-and-backups),
live since #1766) covers the 8 CloudNativePG PostgreSQL databases. The
operator asked on 2026-11-26 whether the cluster runs other database
engines, and to show them with their backup status if it does (#1771).

It does. Checked on 2026-11-26 in the repository and the live cluster
(read-only):

- **SQLite** inside 9 apps, each copied to S3 every night by its own
  restic CronJob. The weekly restore test covers the database file of 4
  of them.
- **Valkey and Redis**, 3 instances: two job queues and the Argo CD
  cache. In memory, with no volume, so nothing is backed up.
- **ClickHouse**, 1 instance: SigNoz's telemetry store, not backed up by
  decision ([docs/backups.md](../../../docs/backups.md#what-is-not-backed-up)).

No MariaDB, MySQL, MongoDB or other engine runs. etcd, the Prometheus
TSDB, ZooKeeper and the Trivy database cache are platform stores, not app
databases, and are not counted ([Out of scope](#out-of-scope)).

This spec adds the three engines to the group: four tiles after the six
PostgreSQL tiles, and a paragraph on how they are protected.
The six PostgreSQL tiles stay as they are.

## Glossary

- **Group**, **stat tile**, **hidden apps**, **collector**, **snapshot**:
  as in the [homelab-dashboard glossary](../homelab-dashboard/requirements.md#glossary).
- **Engine**: SQLite, Valkey and Redis (one engine on the page: Valkey is
  the Redis fork, same protocol), or ClickHouse.
- **SQLite app**: an app whose SQLite file holds state a restore needs,
  listed in the inventory `db_sqlite:app:info`
  ([design, Inventory](design.md#inventory)). An app counts once, however
  many files it has.
- **Instance**: one container running a Valkey, Redis or ClickHouse
  image, counted by namespace and container name.

## Requirement 1: Recording rules

**User story:** As the operator, I want each engine summed in Prometheus,
so that the dashboard reads numbers and never a name.

1. THE SQLite apps SHALL be a static, reviewed inventory in the
   PrometheusRule `homelab-databases`, one series per app, with the
   app's namespace, container, restic CronJob and, where the weekly
   restore test covers its database file, the restore target.
2. Valkey, Redis and ClickHouse instances SHALL be found by the image of
   the container, so a new instance counts without an inventory change.
3. EACH engine SHALL have a count (seen in the rolling 24 h) and an up
   count (ready at least once in the last 10 minutes, so a pod restart
   changes nothing), as the PostgreSQL rules do.
4. THE SQLite apps SHALL have a backup count (the app's restic CronJob
   succeeded in the last 26 h, `slo:backup_fresh`), a restore-passed
   count (the app's latest restore test passed, under 8 days old) and a
   restore-failed count (the latest restore test in the rolling 8 days
   failed).
5. EVERY figure the dashboard reads SHALL be a label-free aggregate.

## Requirement 2: The tiles

**User story:** As a reader, I want to see every database engine the
homelab runs and how each one is protected.

1. AFTER the six PostgreSQL tiles, the group SHALL have a second
   paragraph and four tiles: SQLite, SQLite backups, Valkey and Redis,
   ClickHouse, with the values, details and statuses of
   [design, The tiles](design.md#the-tiles).
2. THE first sentence of the PostgreSQL paragraph SHALL say "Each
   PostgreSQL database", because the SQLite databases are not CNPG
   clusters.
3. A tile whose engine count is 0 SHALL read "No data" with no status.
4. THE Valkey and Redis and the ClickHouse tiles SHALL say that their
   data is not backed up, and carry no backup status.

## Requirement 3: Privacy

1. THE snapshot SHALL gain integers only in `cluster.databases`; the
   block still holds no string (homelab-dashboard 14.2).
2. NO figure, word, title, detail line or paragraph SHALL name an app,
   a namespace, a container or a CronJob. The hidden apps count in the
   SQLite figures like every other app and are never singled out.
3. THE collector's queries SHALL carry no label matcher and no name.

## Requirement 4: Statuses and windows

1. Up and Down SHALL follow the PostgreSQL rule: Down when an instance
   has not been ready for 10 minutes.
2. THE SQLite backups tile SHALL be "Stale" when an app has no
   successful backup in 26 hours (the threshold of `BackupNotFresh`),
   otherwise "Failed" when a restore test failed (`BackupVerifyFailed`),
   otherwise "Fresh".
3. EVERY window SHALL be rolling and its small text SHALL say so:
   "Seen in the rolling 24 h" for the counts, "rolling 26 h" for the
   backups, "rolling 8 days" for the restore tests.

## Requirement 5: French

1. EVERY new string SHALL be in the English and the French catalogue of
   the dashboard (site-theme-language task 5).
2. THE French SHALL be proposed by the coder, corrected by the operator,
   and merged only as corrected (operator, 2026-11-26).

## Non-functional requirements

- No JavaScript: HTML, CSS and inline SVG, as the rest of the page.
- Prometheus cost: one rule group every minute over
  `kube_pod_container_info` and `kube_pod_container_status_ready`, and
  two 8-day reads every 2 minutes, like the PostgreSQL restore rules.

## Acceptance criteria

1. `tests/prometheus/databases_test.yaml` passes in the `promtool` job
   and covers: every engine healthy (9, 9, 9 fresh, 4 passed, 0
   failed; 3, 3; 1, 1), with an unlisted container and a Redis
   exporter not counted and an old Valkey pod not ready next to the
   ready one counted once and up; an SQLite container down 10 minutes
   after it stops being ready, and one with a 5-minute gap in its ready
   series still up; a stale CronJob (one fewer fresh); a test run after
   the last pass and a run without a pass (both failed); a pass 8 days
   and 1 minute old (neither passed nor failed); a container gone for
   more than 24 hours (counted, then not); every aggregate without a
   label. [1.1-1.5]
2. After task 1 merges, Grafana's Prometheus returns the nine
   aggregates with the values of today's cluster. [1.3, 1.4]
3. Collector tests pin each new query and read a missing rule as 0;
   `Validate` refuses an up, a fresh or a restore count above its
   count; `TestDatabasesNumbersOnly` and the hidden-name test of
   homelab-dashboard acceptance criterion 19 cover the new keys.
   [1.5, 3.1, 3.3]
4. A table test covers each status boundary (all, all but one, 0;
   Stale before Failed); the golden pages show the four tiles, "No
   data" with a count of 0, and the rolling windows in their text.
   [2.1-2.4, 4.1-4.3]
5. `TestCatalogue` passes with every new key in both languages, and the
   French matches the operator's correction. [5.1, 5.2]
6. Live after task 3: `https://homelab.nedsi.io/` and `/fr/` show the
   four tiles with the values Grafana gives at the same minute;
   `snapshot.json` and both pages contain no hidden-app name and no
   namespace. [2.1, 3.2]

## Out of scope

- etcd (the Kubernetes datastore, snapshots by hand), the Prometheus
  TSDB, ZooKeeper (ClickHouse's coordination service) and the Trivy
  database cache. The operator can ask for etcd later.
- SQLite data size: it cannot be measured without exec into the pods.
- Consistent SQLite copies (most are taken live): #746.
- Restore tests over the database file of every SQLite app: a separate
  issue.
