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
		{"databases, all up", r(databasesStatus(8, 8)), r(statusOK, "Up")},
		{"databases, one down", r(databasesStatus(7, 8)), r(statusBad, "Down")},
		{"databases, none", r(databasesStatus(0, 0)), r(statusNone, noData)},
		{"wal, all archiving", r(walStatus(8, 0, 8)), r(statusOK, "Archiving")},
		{"wal, one behind", r(walStatus(7, 1, 8)), r(statusWarn, "Behind")},
		{"wal, one failing", r(walStatus(7, 0, 8)), r(statusBad, "Failing")},
		{"wal, one behind, one failing", r(walStatus(6, 1, 8)), r(statusBad, "Failing")},
		{"wal, none", r(walStatus(0, 0, 0)), r(statusNone, noData)},
		{"base, all fresh", r(baseBackupStatus(8, 8)), r(statusOK, "Fresh")},
		{"base, one stale", r(baseBackupStatus(7, 8)), r(statusBad, "Stale")},
		{"base, none", r(baseBackupStatus(0, 0)), r(statusNone, noData)},
		{"restore, all passed", r(restoreStatus(8, 0, 8)), r(statusOK, "Passed")},
		{"restore, one overdue", r(restoreStatus(7, 0, 8)), r(statusWarn, "Overdue")},
		{"restore, one failed", r(restoreStatus(7, 1, 8)), r(statusBad, "Failed")},
		{"restore, none", r(restoreStatus(0, 0, 0)), r(statusNone, noData)},
		{"freshness, 100%", r(freshnessStatus(new(100.0))), r(statusOK, "Met")},
		{"freshness, 99%", r(freshnessStatus(new(99.0))), r(statusOK, "Met")},
		{"freshness, under 99%", r(freshnessStatus(new(98.999))), r(statusBad, "Missed")},
		{"freshness, no series", r(freshnessStatus(nil)), r(statusNone, noData)},
	} {
		if tc.got != tc.want {
			t.Errorf("%s: %v, want %v", tc.name, tc.got, tc.want)
		}
	}
}

func TestDurationText(t *testing.T) {
	for s, want := range map[int]string{70292: "19 h 31 min", 414: "6 min 54 s", 3600: "1 h", 59: "59 s", 0: "0 s", 2658197: "30 d 18 h"} {
		if got := durationText(s); got != want {
			t.Errorf("durationText(%d) = %q, want %q", s, got, want)
		}
	}
}

func TestDatabaseTiles(t *testing.T) {
	labels := []string{"PostgreSQL", "WAL archiving", "Base backups", "Point-in-time recovery", "Restore tests", "Backup freshness"}
	var none []tile
	for _, l := range labels {
		none = append(none, noDataTile(l))
	}
	if diff := cmp.Diff(none, databaseTiles(snapshot.Databases{})); diff != "" {
		t.Errorf("databaseTiles(count 0) mismatch (-want +got):\n%s", diff)
	}

	// The figures without a series: their detail lines are left out, the
	// recovery window and the freshness have no data.
	got := databaseTiles(snapshot.Databases{Count: 1, Up: 1, WALArchiving: 1, BaseFresh: 1, RestorePassed: 1})
	want := []tile{
		{Label: "PostgreSQL", Value: one("1", "database"), Status: statusOK, Word: "Up",
			Details: []string{"Seen in the rolling 24 h", "1 up"}},
		{Label: "WAL archiving", Value: one("1", "of 1"), Status: statusOK, Word: "Archiving"},
		{Label: "Base backups", Value: one("1", "of 1"), Status: statusOK, Word: "Fresh",
			Details: []string{"Nightly, each in the rolling 26 h"}},
		noDataTile("Point-in-time recovery"),
		{Label: "Restore tests", Value: one("1", "of 1"), Status: statusOK, Word: "Passed",
			Details: []string{"Weekly, rolling 8 days"}},
		noDataTile("Backup freshness"),
	}
	if diff := cmp.Diff(want, got); diff != "" {
		t.Errorf("databaseTiles(null figures) mismatch (-want +got):\n%s", diff)
	}

	// A window of under a day is 0 days; one day is singular.
	for s, value := range map[int][]part{86399: one("0", "days"), 86400: one("1", "day"), 172800: one("2", "days")} {
		got := databaseTiles(snapshot.Databases{Count: 1, RecoveryWindowSeconds: &s})[3]
		if diff := cmp.Diff(value, got.Value); diff != "" {
			t.Errorf("recovery window %d s mismatch (-want +got):\n%s", s, diff)
		}
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
			"prowlarr", "lidarr", "bazarr", "qbittorrent", "-db", "postgresql-", "namespace", "pod", "s3://", "bucket"} {
			if strings.Contains(group, leak) {
				t.Errorf("%s: the databases group contains %q", name, leak)
			}
		}
	}
}
