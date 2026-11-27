package web

import (
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// Acceptance criterion 33: every database rule on its boundaries, with all,
// all but one and no database.
func TestDatabaseRules(t *testing.T) {
	type result struct {
		st   status
		word string
	}
	r := func(st status, word string) result { return result{st, word} }
	for _, tc := range []struct {
		name string
		got  result
		want result
	}{
		{"databases, all up", r(databasesStatus(english, 8, 8)), r(statusOK, "Up")},
		{"databases, one down", r(databasesStatus(english, 7, 8)), r(statusBad, "Down")},
		{"databases, none", r(databasesStatus(english, 0, 0)), r(statusNone, noData)},
		{"wal, all archiving", r(walStatus(english, 8, 0, 8)), r(statusOK, "Archiving")},
		{"wal, one behind", r(walStatus(english, 7, 1, 8)), r(statusWarn, "Behind")},
		{"wal, one failing", r(walStatus(english, 7, 0, 8)), r(statusBad, "Failing")},
		{"wal, one behind, one failing", r(walStatus(english, 6, 1, 8)), r(statusBad, "Failing")},
		{"wal, none", r(walStatus(english, 0, 0, 0)), r(statusNone, noData)},
		{"base, all fresh", r(baseBackupStatus(english, 8, 8)), r(statusOK, "Fresh")},
		{"base, one stale", r(baseBackupStatus(english, 7, 8)), r(statusBad, "Stale")},
		{"base, none", r(baseBackupStatus(english, 0, 0)), r(statusNone, noData)},
		{"restore, all passed", r(restoreStatus(english, 8, 0, 8)), r(statusOK, "Passed")},
		{"restore, one overdue", r(restoreStatus(english, 7, 0, 8)), r(statusWarn, "Overdue")},
		{"restore, one failed", r(restoreStatus(english, 7, 1, 8)), r(statusBad, "Failed")},
		{"restore, none", r(restoreStatus(english, 0, 0, 0)), r(statusNone, noData)},
		{"freshness, 100%", r(freshnessStatus(english, new(100.0))), r(statusOK, "Met")},
		{"freshness, 99%", r(freshnessStatus(english, new(99.0))), r(statusOK, "Met")},
		{"freshness, under 99%", r(freshnessStatus(english, new(98.999))), r(statusBad, "Missed")},
		{"freshness, no series", r(freshnessStatus(english, nil)), r(statusNone, noData)},
		{"sqlite backups, all fresh", r(sqliteBackupStatus(english, 9, 0, 9)), r(statusOK, "Fresh")},
		{"sqlite backups, one stale", r(sqliteBackupStatus(english, 8, 0, 9)), r(statusBad, "Stale")},
		{"sqlite backups, stale before failed", r(sqliteBackupStatus(english, 8, 1, 9)), r(statusBad, "Stale")},
		{"sqlite backups, one failed", r(sqliteBackupStatus(english, 9, 1, 9)), r(statusBad, "Failed")},
		{"sqlite backups, none", r(sqliteBackupStatus(english, 0, 0, 0)), r(statusNone, noData)},
	} {
		if tc.got != tc.want {
			t.Errorf("%s: %v, want %v", tc.name, tc.got, tc.want)
		}
	}
}

func TestDurationText(t *testing.T) {
	for s, want := range map[int]string{70292: "19 h 31 min", 414: "6 min 54 s", 3600: "1 h", 59: "59 s", 0: "0 s", 2658197: "30 d 18 h"} {
		if got := english.durationText(s); got != want {
			t.Errorf("durationText(%d) = %q, want %q", s, got, want)
		}
	}
}

func TestDatabaseTiles(t *testing.T) {
	labels := []string{"db.postgresql", "db.wal", "db.base", "db.recovery", "db.restore", "db.fresh"}
	var none []tile
	for _, l := range labels {
		none = append(none, noDataTile(english, l))
	}
	if diff := cmp.Diff(none, databaseTiles(english, snapshot.Databases{})); diff != "" {
		t.Errorf("databaseTiles(count 0) mismatch (-want +got):\n%s", diff)
	}

	// The figures without a series: their detail lines are left out, the
	// recovery window and the freshness have no data.
	got := databaseTiles(english, snapshot.Databases{Count: 1, Up: 1, WALArchiving: 1, BaseFresh: 1, RestorePassed: 1})
	want := []tile{
		{Label: "PostgreSQL", Value: english.one("1", "unit.database"), Status: statusOK, Word: "Up",
			Details: []string{"Seen in the rolling 24 h", "1 up"}},
		{Label: "WAL archiving", Value: english.of(1, 1), Status: statusOK, Word: "Archiving"},
		{Label: "Base backups", Value: english.of(1, 1), Status: statusOK, Word: "Fresh",
			Details: []string{"Nightly, each in the rolling 26 h"}},
		noDataTile(english, "db.recovery"),
		{Label: "Restore tests", Value: english.of(1, 1), Status: statusOK, Word: "Passed",
			Details: []string{"Weekly, rolling 8 days"}},
		noDataTile(english, "db.fresh"),
	}
	if diff := cmp.Diff(want, got); diff != "" {
		t.Errorf("databaseTiles(null figures) mismatch (-want +got):\n%s", diff)
	}

	// A window of under a day is 0 days; one day is singular.
	for s, value := range map[int][]part{86399: english.one("0", "unit.days"), 86400: english.one("1", "unit.day"), 172800: english.one("2", "unit.days")} {
		got := databaseTiles(english, snapshot.Databases{Count: 1, RecoveryWindowSeconds: &s})[3]
		if diff := cmp.Diff(value, got.Value); diff != "" {
			t.Errorf("recovery window %d s mismatch (-want +got):\n%s", s, diff)
		}
	}
}

// dashboard-database-engines Requirement 2: four tiles, no data for an
// engine with no count, singular units.
func TestEngineTiles(t *testing.T) {
	none := []tile{noDataTile(english, "db.sqlite"), noDataTile(english, "db.sqlite-backups"), noDataTile(english, "db.valkey"), noDataTile(english, "db.clickhouse")}
	if diff := cmp.Diff(none, engineTiles(english, snapshot.Databases{})); diff != "" {
		t.Errorf("engineTiles(count 0) mismatch (-want +got):\n%s", diff)
	}
	got := engineTiles(english, snapshot.Databases{SQLiteCount: 9, SQLiteUp: 8, SQLiteBackupFresh: 9, SQLiteRestorePassed: 4,
		ValkeyRedisCount: 3, ValkeyRedisUp: 3, ClickHouseCount: 1, ClickHouseUp: 1})
	want := []tile{
		{Label: "SQLite", Value: english.one("9", "unit.apps"), Status: statusBad, Word: "Down",
			Details: []string{"Seen in the rolling 24 h", "8 up"}},
		{Label: "SQLite backups", Value: english.of(9, 9), Status: statusOK, Word: "Fresh",
			Details: []string{"Nightly to S3, each in the rolling 26 h", "4 passed the weekly restore test, rolling 8 days"}},
		{Label: "Valkey and Redis", Value: english.one("3", "unit.instances"), Status: statusOK, Word: "Up",
			Details: []string{"Seen in the rolling 24 h", "3 up", "In memory, not backed up"}},
		{Label: "ClickHouse", Value: english.one("1", "unit.instance"), Status: statusOK, Word: "Up",
			Details: []string{"Seen in the rolling 24 h", "1 up", "Logs and traces expire, not backed up"}},
	}
	if diff := cmp.Diff(want, got); diff != "" {
		t.Errorf("engineTiles mismatch (-want +got):\n%s", diff)
	}
	if got := engineTiles(english, snapshot.Databases{SQLiteCount: 1, SQLiteUp: 1, SQLiteBackupFresh: 1})[0].Value; !cmp.Equal(got, english.one("1", "unit.app")) {
		t.Errorf("one SQLite app = %v, want 1 app", got)
	}
}

// Requirement 14.2: the group names no database, cluster, namespace, pod
// or app, on any golden page.
func TestDatabasesNameNothing(t *testing.T) {
	for name, doc := range map[string]map[string]any{"full": fullDaily(t), "alarms": alarms(t), "since": since(t)} {
		body := page(t, doc)
		start := strings.Index(body, "<h3>Databases and backups</h3>")
		end := strings.Index(body[start:], "</section>")
		if start < 0 || end < 0 {
			t.Fatalf("%s: no Databases and backups group", name)
		}
		group := strings.ToLower(body[start : start+end])
		for _, leak := range []string{"immich", "keycloak", "mealie", "home-assistant", "theater", "sonarr", "radarr",
			"prowlarr", "lidarr", "bazarr", "qbittorrent", "paperless", "audiobookshelf", "calibre", "grafana",
			"signoz", "jellyfin", "plex", "valkey-", "argocd", "-db", "postgresql-", "namespace", "pod", "s3://", "bucket"} {
			if strings.Contains(group, leak) {
				t.Errorf("%s: the databases group contains %q", name, leak)
			}
		}
	}
}
