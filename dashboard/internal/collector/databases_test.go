package collector

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// wantDatabases is the block of fakeDatabases: integers rounded down, the
// WAL files to the nearest, the freshness in percent at full precision.
func wantDatabases() snapshot.Databases {
	b := int64(1345968964)
	return snapshot.Databases{
		Count: 8, Up: 8, DataBytes: &b, WALArchiving: 8, WALBehind: 0, WALArchived24h: i(1517),
		BaseFresh: 8, BaseOldestSeconds: i(70292), RecoveryWindowSeconds: i(2658197),
		RestorePassed: 8, RestoreFailed: 0, RestoreRows: i(1031332), RestoreMedianSeconds: i(414),
		Freshness30d: f64(99.966),
		SQLiteCount:  9, SQLiteUp: 9, SQLiteBackupFresh: 9, SQLiteRestorePassed: 4, SQLiteRestoreFailed: 0,
		ValkeyRedisCount: 3, ValkeyRedisUp: 3, ClickHouseCount: 1, ClickHouseUp: 1,
	}
}

// Every query of design.md, "Collector and page (task 26)", once per cycle
// at the cycle's time.
func TestDatabaseQueries(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 25, 20, 30), http.StatusNoContent)
	s := e.push(t)
	if diff := cmp.Diff(wantDatabases(), s.Cluster.Databases, approx); diff != "" {
		t.Errorf("databases mismatch (-want +got):\n%s", diff)
	}
	queries := []string{
		`cluster:cnpg_databases:count`,
		`cluster:cnpg_databases_up:count`,
		`cluster:cnpg_wal_archiving:count`,
		`cluster:cnpg_wal_behind:count`,
		`cluster:cnpg_base_backup_fresh:count`,
		`cluster:cnpg_restore_passed:count`,
		`cluster:cnpg_restore_failed:count`,
		`cluster:cnpg_data:bytes`,
		`cluster:cnpg_base_backup_age:max_seconds`,
		`cluster:cnpg_recovery_window:min_seconds`,
		`cluster:cnpg_restore_rows:sum`,
		`cluster:cnpg_restore_duration:median_seconds`,
		`cluster:cnpg_wal_archived:increase24h`,
		`min(slo:backup_freshness:ratio_rate30d{kind="cnpg"})`,
		`cluster:sqlite_databases:count`,
		`cluster:sqlite_databases_up:count`,
		`cluster:sqlite_backup_fresh:count`,
		`cluster:sqlite_restore_passed:count`,
		`cluster:sqlite_restore_failed:count`,
		`cluster:valkey_redis_instances:count`,
		`cluster:valkey_redis_instances_up:count`,
		`cluster:clickhouse_instances:count`,
		`cluster:clickhouse_instances_up:count`,
	}
	e.fake.mu.Lock()
	defer e.fake.mu.Unlock()
	for _, q := range queries {
		if diff := cmp.Diff([]int64{e.now.Unix()}, unix(e.fake.queryTimes[q])); diff != "" {
			t.Errorf("times of %s mismatch (-want +got):\n%s", q, diff)
		}
	}
}

func unix(ts []time.Time) []int64 {
	out := make([]int64, len(ts))
	for n, t := range ts {
		out[n] = t.Unix()
	}
	return out
}

// Requirement 14.3 and the clamp: every count within count, wal_behind and
// restore_failed within what is left.
func TestDatabaseClamp(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 25, 20, 30), http.StatusNoContent)
	for q, v := range map[string]float64{
		"cluster:cnpg_databases_up:count":         9,
		"cluster:cnpg_base_backup_fresh:count":    9,
		"cluster:cnpg_wal_archiving:count":        7,
		"cluster:cnpg_wal_behind:count":           3,
		"cluster:cnpg_restore_passed:count":       9,
		"cluster:cnpg_restore_failed:count":       1,
		"cluster:sqlite_databases_up:count":       10,
		"cluster:sqlite_backup_fresh:count":       10,
		"cluster:sqlite_restore_passed:count":     8,
		"cluster:sqlite_restore_failed:count":     2,
		"cluster:valkey_redis_instances_up:count": 4,
		"cluster:clickhouse_instances_up:count":   2,
	} {
		e.fake.dbs[q] = v
	}
	d := e.push(t).Cluster.Databases
	got := [6]int{d.Up, d.BaseFresh, d.WALArchiving, d.WALBehind, d.RestorePassed, d.RestoreFailed}
	if want := [6]int{8, 8, 7, 1, 8, 0}; got != want {
		t.Errorf("up, base_fresh, wal_archiving, wal_behind, restore_passed, restore_failed = %v, want %v", got, want)
	}
	engines := [6]int{d.SQLiteUp, d.SQLiteBackupFresh, d.SQLiteRestorePassed, d.SQLiteRestoreFailed, d.ValkeyRedisUp, d.ClickHouseUp}
	if want := [6]int{9, 9, 8, 1, 3, 1}; engines != want {
		t.Errorf("sqlite_up, sqlite_backup_fresh, sqlite_restore_passed, sqlite_restore_failed, valkey_redis_up, clickhouse_up = %v, want %v", engines, want)
	}
}

// A missing rule is no error: the counts read 0, the figures null, and the
// block is this cycle's.
func TestDatabasesWithoutRules(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 25, 20, 30), http.StatusNoContent)
	e.fake.dbs = map[string]float64{}
	s := e.push(t)
	if diff := cmp.Diff(snapshot.Databases{}, s.Cluster.Databases); diff != "" {
		t.Errorf("databases without rules mismatch (-want +got):\n%s", diff)
	}
	if s.Cluster.AsOf != s.GeneratedAt {
		t.Errorf("cluster.as_of = %s, want this cycle's %s", s.Cluster.AsOf, s.GeneratedAt)
	}
}

// Acceptance criterion 32: the dry run's databases block holds numbers
// only.
func TestDatabasesNumbersOnly(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 25, 20, 30))
	_, dry, err := e.c.Collect(t.Context(), e.now)
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Cluster struct {
			Databases map[string]any `json:"databases"`
		} `json:"cluster"`
	}
	if err := json.Unmarshal(dry, &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Cluster.Databases) != 23 {
		t.Errorf("databases has %d keys, want 23", len(doc.Cluster.Databases))
	}
	for k, v := range doc.Cluster.Databases {
		if _, ok := v.(float64); !ok {
			t.Errorf("databases.%s = %#v, want a number", k, v)
		}
	}
}
