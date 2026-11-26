package collector

import (
	"context"
	"math"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// The database queries of version 10 (design.md, "Collector and page (task
// 26)"): the label-free aggregates of the PrometheusRule homelab-databases,
// so no database, namespace or pod name reaches the collector. A missing
// rule is no error: a count reads 0, a figure null.
var (
	databaseCounts = []struct {
		figure, expr string
		set          func(*snapshot.Databases, int)
	}{
		{"databases.count", `cluster:cnpg_databases:count`, func(d *snapshot.Databases, n int) { d.Count = n }},
		{"databases.up", `cluster:cnpg_databases_up:count`, func(d *snapshot.Databases, n int) { d.Up = n }},
		{"databases.wal_archiving", `cluster:cnpg_wal_archiving:count`, func(d *snapshot.Databases, n int) { d.WALArchiving = n }},
		{"databases.wal_behind", `cluster:cnpg_wal_behind:count`, func(d *snapshot.Databases, n int) { d.WALBehind = n }},
		{"databases.base_fresh", `cluster:cnpg_base_backup_fresh:count`, func(d *snapshot.Databases, n int) { d.BaseFresh = n }},
		{"databases.restore_passed", `cluster:cnpg_restore_passed:count`, func(d *snapshot.Databases, n int) { d.RestorePassed = n }},
		{"databases.restore_failed", `cluster:cnpg_restore_failed:count`, func(d *snapshot.Databases, n int) { d.RestoreFailed = n }},
		{"databases.sqlite_count", `cluster:sqlite_databases:count`, func(d *snapshot.Databases, n int) { d.SQLiteCount = n }},
		{"databases.sqlite_up", `cluster:sqlite_databases_up:count`, func(d *snapshot.Databases, n int) { d.SQLiteUp = n }},
		{"databases.sqlite_backup_fresh", `cluster:sqlite_backup_fresh:count`, func(d *snapshot.Databases, n int) { d.SQLiteBackupFresh = n }},
		{"databases.sqlite_restore_passed", `cluster:sqlite_restore_passed:count`, func(d *snapshot.Databases, n int) { d.SQLiteRestorePassed = n }},
		{"databases.sqlite_restore_failed", `cluster:sqlite_restore_failed:count`, func(d *snapshot.Databases, n int) { d.SQLiteRestoreFailed = n }},
		{"databases.valkey_redis_count", `cluster:valkey_redis_instances:count`, func(d *snapshot.Databases, n int) { d.ValkeyRedisCount = n }},
		{"databases.valkey_redis_up", `cluster:valkey_redis_instances_up:count`, func(d *snapshot.Databases, n int) { d.ValkeyRedisUp = n }},
		{"databases.clickhouse_count", `cluster:clickhouse_instances:count`, func(d *snapshot.Databases, n int) { d.ClickHouseCount = n }},
		{"databases.clickhouse_up", `cluster:clickhouse_instances_up:count`, func(d *snapshot.Databases, n int) { d.ClickHouseUp = n }},
	}
	databaseFigures = []struct {
		figure, expr string
		set          func(*snapshot.Databases, *float64)
	}{
		{"databases.data_bytes", `cluster:cnpg_data:bytes`, func(d *snapshot.Databases, v *float64) {
			if n := integer(v); n != nil {
				b := int64(*n)
				d.DataBytes = &b
			}
		}},
		{"databases.wal_archived_24h", `cluster:cnpg_wal_archived:increase24h`, func(d *snapshot.Databases, v *float64) {
			d.WALArchived24h = integer(mapped(v, math.Round))
		}},
		{"databases.base_oldest_seconds", `cluster:cnpg_base_backup_age:max_seconds`, func(d *snapshot.Databases, v *float64) {
			d.BaseOldestSeconds = integer(v)
		}},
		{"databases.recovery_window_seconds", `cluster:cnpg_recovery_window:min_seconds`, func(d *snapshot.Databases, v *float64) {
			d.RecoveryWindowSeconds = integer(v)
		}},
		{"databases.restore_rows", `cluster:cnpg_restore_rows:sum`, func(d *snapshot.Databases, v *float64) {
			d.RestoreRows = integer(v)
		}},
		{"databases.restore_median_seconds", `cluster:cnpg_restore_duration:median_seconds`, func(d *snapshot.Databases, v *float64) {
			d.RestoreMedianSeconds = integer(v)
		}},
		{"databases.freshness_30d", `min(slo:backup_freshness:ratio_rate30d{kind="cnpg"})`, func(d *snapshot.Databases, v *float64) {
			d.Freshness30d = mapped(v, snapshot.ToPercent)
		}},
	}
)

// databases reads the "Databases and backups" figures at at.
func databases(ctx context.Context, q Querier, at time.Time) (snapshot.Databases, error) {
	var d snapshot.Databases
	for _, f := range databaseCounts {
		n, err := counted(ctx, q, f.figure, f.expr, at)
		if err != nil {
			return d, err
		}
		f.set(&d, max(0, n))
	}
	for _, f := range databaseFigures {
		v, err := optional(ctx, q, f.figure, f.expr, at)
		if err != nil {
			return d, err
		}
		f.set(&d, v)
	}
	clampDatabases(&d)
	return d, nil
}

// clampDatabases keeps every count within count: the two rule groups are
// evaluated up to 2 minutes apart, so a database that appears or goes away
// can be counted by one and not yet by the other. Expected, so not logged.
func clampDatabases(d *snapshot.Databases) {
	d.Up = min(d.Up, d.Count)
	d.BaseFresh = min(d.BaseFresh, d.Count)
	d.WALArchiving = min(d.WALArchiving, d.Count)
	d.WALBehind = min(d.WALBehind, d.Count-d.WALArchiving)
	d.RestorePassed = min(d.RestorePassed, d.Count)
	d.RestoreFailed = min(d.RestoreFailed, d.Count-d.RestorePassed)
	d.SQLiteUp = min(d.SQLiteUp, d.SQLiteCount)
	d.SQLiteBackupFresh = min(d.SQLiteBackupFresh, d.SQLiteCount)
	d.SQLiteRestorePassed = min(d.SQLiteRestorePassed, d.SQLiteCount)
	d.SQLiteRestoreFailed = min(d.SQLiteRestoreFailed, d.SQLiteCount-d.SQLiteRestorePassed)
	d.ValkeyRedisUp = min(d.ValkeyRedisUp, d.ValkeyRedisCount)
	d.ClickHouseUp = min(d.ClickHouseUp, d.ClickHouseCount)
}
