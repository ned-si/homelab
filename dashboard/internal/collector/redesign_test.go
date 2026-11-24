package collector

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
	promv1 "github.com/prometheus/client_golang/api/prometheus/v1"
	"github.com/prometheus/common/model"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// The tests of the redesign's blocks (design.md, "Tests", the redesign rows).

func f64(x float64) *float64 { return &x }
func i(x int) *int           { return &x }

func (e *env) push(t *testing.T) *snapshot.Snapshot {
	t.Helper()
	if !e.c.Cycle(t.Context()) {
		t.Fatal("Cycle() = false, want a push")
	}
	bodies := e.pods[0].bodies
	s, err := snapshot.Validate(bodies[len(bodies)-1])
	if err != nil {
		t.Fatalf("Validate(pushed) = %v", err)
	}
	return s
}

func TestLiveBlocks(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	s := e.push(t)
	if got, want := s.SchemaVersion, snapshot.Version; got != want {
		t.Errorf("schema_version = %d, want %d", got, want)
	}

	a := s.Availability
	if got, want := [2]string{a.Days[0], a.Days[29]}, [2]string{"2026-10-22", "2026-11-20"}; got != want {
		t.Errorf("availability.days from %s to %s, want %s to %s", got[0], got[1], want[0], want[1])
	}
	immich := a.Apps[0]
	if diff := cmp.Diff(snapshot.LiveApp{ID: "immich", Name: "Immich", State: snapshot.StateUp,
		Availability30d: f64(99.9), ErrorBudgetRemaining30d: i(91)}, snapshot.LiveApp{ID: immich.ID, Name: immich.Name,
		State: immich.State, Availability30d: immich.Availability30d, ErrorBudgetRemaining30d: immich.ErrorBudgetRemaining30d}); diff != "" {
		t.Errorf("immich mismatch (-want +got):\n%s", diff)
	}
	for d, v := range immich.AvailabilityDaily {
		if v == nil || *v != 99.9 {
			t.Errorf("immich availability_daily[%d] = %v, want 99.9", d, v)
		}
	}
	// The blog's probes start on 15 November: no value before.
	blog := a.Apps[8].AvailabilityDaily
	if blog[23] != nil || blog[24] == nil {
		t.Errorf("blog availability_daily[23], [24] = %v, %v, want null then a value", blog[23], blog[24])
	}

	if diff := cmp.Diff([]snapshot.Cert{
		{ID: "lilalala", Name: "*.lilalala.com", DaysLeft: i(39)},
		{ID: "nedsi", Name: "nedsi.io", DaysLeft: i(82)},
		{ID: "homelab", Name: "homelab.nedsi.io"},
	}, s.Certificates.Certs); diff != "" {
		t.Errorf("certificates mismatch (-want +got):\n%s", diff)
	}

	node := func(name string, ready bool) snapshot.NodeUse {
		return snapshot.NodeUse{Name: name, Ready: ready, CPU: f64(61.2), Memory: f64(61.2), Disk: f64(61.2),
			CPUPressure: f64(4.3), MemoryPressure: f64(4.3), IOPressure: f64(4.3), NetErrorsPerSecond: f64(0.01)}
	}
	want := snapshot.Cluster{
		AsOf: s.GeneratedAt, Nodes: 4, Apps: 55, TalosVersion: "v1.14.6", KubernetesVersion: "v1.37.2",
		Synced: 54, Healthy: 55,
		NodeUse: []snapshot.NodeUse{node("homelab-n0", false), node("homelab-n1", true), node("homelab-n2", true), node("homelab-n3", true)},
		NAS: snapshot.NAS{Up: true, PoolHealthy: new(true), Pool: f64(47.9), CPU: f64(47.9), Memory: f64(47.9),
			LoadPerCore: f64(0.25), DeviceErrors: i(0), ScrubErrors: i(0)},
		Gateway:     snapshot.Gateway{RequestsPerSecond: f64(0.63), Errors5xx: f64(0.59), LatencyP95Ms: i(41)},
		Restarts24h: 3,
		Volumes:     snapshot.Volumes{Count: 35, UsedBytes: 410000000000, CapacityBytes: 1100000000000, Fullest: 80.8},
	}
	if diff := cmp.Diff(want, s.Cluster); diff != "" {
		t.Errorf("cluster mismatch (-want +got):\n%s", diff)
	}
	// Without a token the DORA figures wait for the first refresh with one.
	p := s.Project
	if p.LeadTimeSeconds != nil || p.LeadTimeCount != nil || p.FailedChanges30d != nil || p.ChangeFailureRate != nil ||
		p.Incidents30d != nil || p.RestoreSeconds != nil {
		t.Errorf("DORA figures without a token = %+v, want null", p)
	}
	if e.fake.graphql != 0 || len(e.fake.ranges) != 0 {
		t.Errorf("%d GraphQL and %d range queries without a token, want none", e.fake.graphql, len(e.fake.ranges))
	}
}

// Acceptance criterion 16: a failing probe turns the state to down and
// lowers today's bar in the same cycle.
func TestProbeDownSameCycle(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	s := e.push(t)
	if got := s.Availability.Apps[1]; got.State != snapshot.StateUp || *got.AvailabilityDaily[29] != 99.9 {
		t.Fatalf("mealie state %s, today %v, want up and 99.9", got.State, *got.AvailabilityDaily[29])
	}
	e.fake.down["cook"] = true
	e.now = e.now.Add(time.Minute)
	got := e.push(t).Availability.Apps[1]
	if got.State != snapshot.StateDown {
		t.Errorf("mealie state = %s, want down", got.State)
	}
	if *got.AvailabilityDaily[29] != 90 {
		t.Errorf("mealie today = %v, want 90", *got.AvailabilityDaily[29])
	}
	e.fake.noProbe["cook"] = true
	e.now = e.now.Add(time.Minute)
	if got := e.push(t).Availability.Apps[1]; got.State != snapshot.StateNone || got.AvailabilityDaily[29] != nil {
		t.Errorf("mealie without probes: state %s, today %v, want none and null", got.State, got.AvailabilityDaily[29])
	}
}

func TestStateOfSeveralProbes(t *testing.T) {
	o := snapshot.ShownApp{ID: "observability", SLOApp: "observability", ProbeApps: []string{"grafana", "signoz", "prometheus", "alertmanager"}}
	tests := []struct {
		probes map[string]float64
		want   string
	}{
		{map[string]float64{"grafana": 1, "signoz": 1, "prometheus": 1, "alertmanager": 1}, snapshot.StateUp},
		{map[string]float64{"grafana": 1, "signoz": 0, "prometheus": 1, "alertmanager": 1}, snapshot.StateDown},
		{map[string]float64{"grafana": 1}, snapshot.StateUp},
		{map[string]float64{}, snapshot.StateNone},
	}
	for _, tc := range tests {
		if got := state(o, tc.probes); got != tc.want {
			t.Errorf("state(%v) = %s, want %s", tc.probes, got, tc.want)
		}
	}
	e := newEnv(t, zurich(2026, 11, 20, 17, 0))
	shown := []snapshot.ShownApp{{ID: "immich", SLOApp: "media"}, o}
	got, err := todayValues(t.Context(), e.c.Prometheus, shown, e.now, snapshot.Day(e.now))
	if err != nil {
		t.Fatal(err)
	}
	if diff := cmp.Diff(map[string]float64{"media": 0.999, "observability": 0.75}, got); diff != "" {
		t.Errorf("todayValues() mismatch (-want +got):\n%s", diff)
	}
	want := `avg(avg_over_time(probe_success{job=~"blackbox-public|blackbox-internal", app=~"grafana|signoz|prometheus|alertmanager"}[61200s]))`
	if e.fake.count(want) != 1 {
		t.Errorf("no query %s in %v", want, e.fake.queries)
	}
}

func TestTodayWindow(t *testing.T) {
	tests := []struct {
		now  time.Time
		want string
	}{
		{zurich(2026, 11, 20, 0, 0).Add(30 * time.Second), "[60s]"},
		{zurich(2026, 11, 20, 17, 0), "[61200s]"},
		// The last Sunday of March: 02:00 does not exist, 10:00 is 9 h in.
		{zurich(2026, 3, 29, 10, 0), "[32400s]"},
	}
	for _, tc := range tests {
		e := newEnv(t, tc.now, http.StatusNoContent)
		e.c.Cycle(t.Context())
		if n := e.fake.count(`avg by (app) (avg_over_time(probe_success{job="blackbox-public", app=~"media|cook|archive|watch|syncthing|auth|nedsi|blog|homelab"}` + tc.want + "))"); n != 1 {
			t.Errorf("at %v: %d queries of today's bar with %s, want 1: %v", tc.now, n, tc.want, e.fake.queries)
		}
	}
}

// The 29 finished days are read once per Zurich day, at the midnights
// before today, across both changes of summer time.
func TestFinishedDaysOnce(t *testing.T) {
	for _, day := range []time.Time{zurich(2026, 3, 30, 0, 0), zurich(2026, 10, 26, 0, 0)} {
		t.Run(day.Format(snapshot.DateLayout), func(t *testing.T) {
			e := newEnv(t, day.Add(9*time.Hour))
			finished := func() []time.Time {
				return e.fake.queryTimes["1 - slo:probe_error:ratio_rate1d"+sloSelector()]
			}
			if _, err := e.c.readAvailability(t.Context(), e.now); err != nil {
				t.Fatal(err)
			}
			times := finished()
			if len(times) != snapshot.Days-1 {
				t.Fatalf("%d finished-day queries, want %d", len(times), snapshot.Days-1)
			}
			for d, at := range times {
				if want := snapshot.AddDays(day, d-(snapshot.Days-2)); !at.Equal(want) {
					t.Errorf("finished-day query %d at %v, want %v", d, at.In(snapshot.Zurich), want)
				}
			}
			e.now = day.Add(23 * time.Hour)
			if _, err := e.c.readAvailability(t.Context(), e.now); err != nil {
				t.Fatal(err)
			}
			if got := len(finished()); got != snapshot.Days-1 {
				t.Errorf("%d finished-day queries later the same day, want %d", got, snapshot.Days-1)
			}
			e.now = snapshot.AddDays(day, 1).Add(30 * time.Second)
			if _, err := e.c.readAvailability(t.Context(), e.now); err != nil {
				t.Fatal(err)
			}
			if got := len(finished()); got != 2*(snapshot.Days-1) {
				t.Errorf("%d finished-day queries after midnight, want %d", got, 2*(snapshot.Days-1))
			}
		})
	}
}

func TestNoUseSeries(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	e.fake.noUse, e.fake.noNAS, e.fake.noGateway = true, true, true
	s := e.push(t)
	for _, n := range s.Cluster.NodeUse {
		if n.CPU != nil || n.Memory != nil || n.Disk != nil || n.IOPressure != nil || n.NetErrorsPerSecond != nil {
			t.Errorf("node %s without series = %+v, want null figures", n.Name, n)
		}
	}
	if diff := cmp.Diff(snapshot.NAS{}, s.Cluster.NAS); diff != "" {
		t.Errorf("nas without series mismatch (-want +got):\n%s", diff)
	}
	if diff := cmp.Diff(snapshot.Gateway{}, s.Cluster.Gateway); diff != "" {
		t.Errorf("gateway without series mismatch (-want +got):\n%s", diff)
	}
	if s.Cluster.AsOf != s.GeneratedAt {
		t.Errorf("cluster.as_of = %s, want this cycle's %s", s.Cluster.AsOf, s.GeneratedAt)
	}
}

func TestNodeCountMismatchKeepsBlock(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	first := e.push(t)
	e.fake.promEmpty = readyQuery
	e.now = e.now.Add(time.Minute)
	if got := e.push(t).Cluster.AsOf; got != first.Cluster.AsOf {
		t.Errorf("cluster.as_of = %s, want the last good %s", got, first.Cluster.AsOf)
	}
}

// doraNow is the collection time of the DORA tests; the window starts 30
// Zurich days earlier.
var doraNow = zurich(2026, 11, 20, 17, 0)

func doraEnv(t *testing.T) *env {
	t.Helper()
	e := newEnv(t, doraNow, http.StatusNoContent)
	e.withToken(t)
	return e
}

func TestLeadTime(t *testing.T) {
	e := doraEnv(t)
	m := doraNow.Add(-48 * time.Hour)
	e.fake.prs = []fakePR{
		// Synced 30 min after the merge, opened 2 h before: 2.5 h.
		{Title: "a", CreatedAt: m.Add(-2 * time.Hour), MergedAt: m, Files: []string{"deploy/apps/x.yaml"}, OID: "aaa", Synced: []time.Time{m.Add(45 * time.Minute), m.Add(30 * time.Minute)}},
		// No status yet: left out.
		{Title: "b", CreatedAt: doraNow.Add(-2 * time.Hour), MergedAt: doraNow.Add(-time.Hour), Files: []string{"clusters/homelab/x.yaml"}, OID: "bbb"},
		// A status 25 h after the merge (a late bulk post): left out for good.
		{Title: "c", CreatedAt: m.Add(-time.Hour), MergedAt: m, Files: []string{"deploy/x.yaml"}, OID: "ccc", Synced: []time.Time{m.Add(25 * time.Hour)}},
		// Deploys nothing: its lead time ends at the merge, 1 h.
		{Title: "d", CreatedAt: m.Add(-time.Hour), MergedAt: m, Files: []string{"docs/x.md"}, OID: "ddd"},
		// More files than one page: counted as deploying, 3 h.
		{Title: "e", CreatedAt: m.Add(-170 * time.Minute), MergedAt: m, Files: []string{"docs/y.md"}, MoreFiles: 1, OID: "eee", Synced: []time.Time{m.Add(10 * time.Minute)}},
	}
	p := e.push(t).Project
	if diff := cmp.Diff([2]*int{i(9000), i(3)}, [2]*int{p.LeadTimeSeconds, p.LeadTimeCount}); diff != "" {
		t.Errorf("lead time and count mismatch (-want +got):\n%s", diff)
	}
}

func TestMergedPages(t *testing.T) {
	e := doraEnv(t)
	for n := range 250 {
		e.fake.prs = append(e.fake.prs, fakePR{Title: fmt.Sprint(n), CreatedAt: doraNow.Add(-2 * time.Hour), MergedAt: doraNow.Add(-time.Hour)})
	}
	prs, err := e.c.GitHub.mergedPRs(t.Context(), doraNow.AddDate(0, 0, -30), doraNow)
	if err != nil {
		t.Fatal(err)
	}
	if len(prs) != 250 || e.fake.graphql != 3 {
		t.Errorf("mergedPRs() = %d pull requests in %d pages, want 250 in 3", len(prs), e.fake.graphql)
	}
	for n := range 751 {
		e.fake.prs = append(e.fake.prs, fakePR{Title: fmt.Sprint(n)})
	}
	if _, err := e.c.GitHub.mergedPRs(t.Context(), doraNow.AddDate(0, 0, -30), doraNow); err == nil {
		t.Error("mergedPRs() above 1000 results = nil error, want an error, not an undercount")
	}
	if e.c.Cycle(t.Context()) {
		t.Error("Cycle() with 1001 merged pull requests = true, want the project block failed and no push")
	}
}

func TestFailedChanges(t *testing.T) {
	e := doraEnv(t)
	m := doraNow.Add(-time.Hour)
	for _, p := range []fakePR{
		{Title: "feat: x", Labels: []string{"auto-rollback"}},
		{Title: "fix: y", Labels: []string{"fix-forward"}},
		{Title: `Revert "feat: z"`},
		{Title: "revert: w"},
		{Title: "fix: reverting is not a revert", Labels: []string{"renovate"}},
	} {
		p.CreatedAt, p.MergedAt = m.Add(-time.Hour), m
		e.fake.prs = append(e.fake.prs, p)
	}
	p := e.push(t).Project
	// Four failed changes over the 300 deploys of the search.
	if diff := cmp.Diff([2]any{i(4), f64(1.3)}, [2]any{p.FailedChanges30d, p.ChangeFailureRate}); diff != "" {
		t.Errorf("failed changes and rate mismatch (-want +got):\n%s", diff)
	}
}

func TestIncidents(t *testing.T) {
	e := doraEnv(t)
	t1 := doraNow.Add(-72 * time.Hour)
	t2 := doraNow.Add(-24 * time.Hour)
	e.fake.alerts = []firing{
		// 30 min, overlapping the rollback below: one incident of 45 min.
		{map[string]string{"alertname": "SLOBurn", "app": "cook"}, t1, t1.Add(30 * time.Minute)},
		// Still firing at the end of the window: not ended, not counted.
		{map[string]string{"alertname": "HomelabNASDown"}, doraNow.Add(-10 * time.Minute), doraNow},
		// Two firings of one alert, 10 min apart: two incidents of 0 and 1 min.
		{map[string]string{"alertname": "X"}, t2.Add(-6 * time.Hour), t2.Add(-6 * time.Hour)},
		{map[string]string{"alertname": "X", "instance": "b"}, t2.Add(-5*time.Hour - 50*time.Minute), t2.Add(-5*time.Hour - 49*time.Minute)},
	}
	e.fake.prs = []fakePR{
		{Title: "feat: break", CreatedAt: t1, MergedAt: t1.Add(10 * time.Minute), Files: []string{"deploy/a.yaml"},
			OID: "0123456789abcdef0123456789abcdef01234567", Synced: []time.Time{t1.Add(12 * time.Minute)}},
		{Title: `Revert "feat: break"`, Labels: []string{"auto-rollback"}, CreatedAt: t1.Add(20 * time.Minute), MergedAt: t1.Add(40 * time.Minute),
			Files: []string{"deploy/a.yaml"}, OID: "fff", Message: "Revert \"feat: break\"\n\nThis reverts commit 0123456789abcdef0123456789abcdef01234567.",
			Synced: []time.Time{t1.Add(45 * time.Minute)}},
		// A revert whose message names no commit: from its creation, 5 min.
		{Title: "revert: by hand", CreatedAt: t2, MergedAt: t2.Add(3 * time.Minute), Files: []string{"deploy/b.yaml"}, OID: "eee",
			Synced: []time.Time{t2.Add(5 * time.Minute)}},
	}
	p := e.push(t).Project
	// Incidents of 0, 1, 5 and 45 min: the median is 3 min.
	if diff := cmp.Diff([2]*int{i(4), i(180)}, [2]*int{p.Incidents30d, p.RestoreSeconds}); diff != "" {
		t.Errorf("incidents and restore mismatch (-want +got):\n%s", diff)
	}
	start := doraNow.In(snapshot.Zurich).AddDate(0, 0, -30)
	if !e.fake.ranges[0].start.Equal(start) || !e.fake.ranges[len(e.fake.ranges)-1].end.Equal(doraNow) {
		t.Errorf("range queries from %v to %v, want %v to %v", e.fake.ranges[0].start, e.fake.ranges[len(e.fake.ranges)-1].end, start, doraNow)
	}
	for n, r := range e.fake.ranges {
		if points := int(r.end.Sub(r.start)/r.step) + 1; points > 11000 || r.step != time.Minute {
			t.Errorf("range query %d: %d points at a %v step, want at most 11000 at 1m", n, points, r.step)
		}
		if n > 0 && !r.start.Equal(e.fake.ranges[n-1].end) {
			t.Errorf("range query %d starts at %v, want the previous end %v", n, r.start, e.fake.ranges[n-1].end)
		}
	}
}

func TestMergeIntervals(t *testing.T) {
	at := func(m int) time.Time { return doraNow.Add(time.Duration(m) * time.Minute) }
	got := mergeIntervals([]interval{
		{start: at(10), end: at(20)},
		{start: at(0), end: at(5)},
		{start: at(15), end: at(30), open: true},
		{start: at(5), end: at(6)},
		{start: at(40), end: at(41)},
	})
	want := []interval{{start: at(0), end: at(6)}, {start: at(10), end: at(30), open: true}, {start: at(40), end: at(41)}}
	if diff := cmp.Diff(want, got, cmp.AllowUnexported(interval{})); diff != "" {
		t.Errorf("mergeIntervals() mismatch (-want +got):\n%s", diff)
	}
}

func TestCIRuns(t *testing.T) {
	e := newEnv(t, doraNow, http.StatusNoContent)
	start := doraNow.Add(-time.Hour).UTC()
	run := func(n int, conclusion, sha, message string, seconds int) map[string]any {
		return map[string]any{"run_number": n, "conclusion": conclusion, "head_sha": sha,
			"run_started_at": start.Format(time.RFC3339), "updated_at": start.Add(time.Duration(seconds) * time.Second).Format(time.RFC3339),
			"head_commit": map[string]any{"message": message}}
	}
	e.fake.runs = []map[string]any{
		run(9, "success", "6d0407e2aa", "chore(deps): update theater stack (#12) (#1602)\n\nbody (#7)", 298),
		run(8, "failure", "a433737abe", "feat: x (#1601)", 341),
		run(7, "cancelled", "e8e93ebd00", "fix: no number", 95),
		run(6, "timed_out", "2ec595b600", "docs: y (#1574)", 3600),
		run(5, "action_required", "b24598b700", "docs: z", 0),
		run(4, "success", "c000000000", "one too many", 1),
	}
	start0 := snapshot.FormatTime(start)
	want := []snapshot.CIRun{
		{Run: 9, Result: "success", Commit: "6d0407e", PR: i(1602), StartedAt: start0, DurationSeconds: 298},
		{Run: 8, Result: "failure", Commit: "a433737", PR: i(1601), StartedAt: start0, DurationSeconds: 341},
		{Run: 7, Result: "cancelled", Commit: "e8e93eb", StartedAt: start0, DurationSeconds: 95},
		{Run: 6, Result: "other", Commit: "2ec595b", PR: i(1574), StartedAt: start0, DurationSeconds: 3600},
		{Run: 5, Result: "other", Commit: "b24598b", StartedAt: start0, DurationSeconds: 0},
	}
	if diff := cmp.Diff(want, e.push(t).Project.CIRuns); diff != "" {
		t.Errorf("ci_runs mismatch (-want +got):\n%s", diff)
	}
}

// Without a token the DORA figures keep their last value.
func TestDORAWithoutToken(t *testing.T) {
	e := doraEnv(t)
	e.fake.prs = []fakePR{{Title: "a", CreatedAt: doraNow.Add(-2 * time.Hour), MergedAt: doraNow.Add(-time.Hour)}}
	first := e.push(t).Project
	if first.LeadTimeSeconds == nil || *first.LeadTimeSeconds != 3600 {
		t.Fatalf("lead_time_seconds with a token = %v, want 3600", first.LeadTimeSeconds)
	}
	if err := os.Remove(e.c.GitHub.TokenFile); err != nil {
		t.Fatal(err)
	}
	e.fake.prs = nil
	e.now = doraNow.Add(15 * time.Minute)
	got := e.push(t).Project
	if got.AsOf == first.AsOf {
		t.Fatal("the project block was not refreshed")
	}
	if diff := cmp.Diff(first.LeadTimeSeconds, got.LeadTimeSeconds); diff != "" || got.Incidents30d == nil {
		t.Errorf("DORA figures without a token not kept (-want +got):\n%s", diff)
	}
}

// Acceptance criterion 19: no namespace, pod, volume or hidden app reaches
// the snapshot, though the alerts, titles and commit messages name them.
func TestNoNamesInSnapshot(t *testing.T) {
	e := doraEnv(t)
	e.fake.alerts = []firing{{map[string]string{"alertname": "ArrIndexersFailing", "namespace": "theater",
		"instance": "https://theater.lilalala.com/", "app": "sonarr"}, doraNow.Add(-3 * time.Hour), doraNow.Add(-2 * time.Hour)}}
	e.fake.prs = []fakePR{{Title: "fix(theater): sonarr pvc", CreatedAt: doraNow.Add(-2 * time.Hour), MergedAt: doraNow.Add(-time.Hour),
		Files: []string{"apps/theater/sonarr.yaml"}, Message: "fix(theater): radarr namespace"}}
	e.fake.runs = []map[string]any{{"run_number": 3, "conclusion": "success", "head_sha": "abcdef1234",
		"run_started_at": "2026-11-20T15:00:00Z", "updated_at": "2026-11-20T15:05:00Z",
		"head_commit": map[string]any{"message": "fix(theater): qbittorrent pod (#5)"}}}
	e.push(t)
	_, dry, err := e.c.Collect(t.Context(), e.now)
	if err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string][]byte{"push": e.pods[0].bodies[0], "dry run": dry} {
		for _, leak := range []string{"theater", "sonarr", "radarr", "qbittorrent", "namespace", "pod", "pvc", "Arr"} {
			if strings.Contains(string(body), leak) {
				t.Errorf("the %s snapshot contains %q", name, leak)
			}
		}
	}
}

// The security block: each signal's two counts and 28 buckets, the 24 h
// count never above the 7 d one, null without a series except the
// expected-zero signals.
func TestSecurityBlock(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	s := e.push(t).Security
	if s.AsOf != "2026-11-20T17:00:00+01:00" {
		t.Errorf("security.as_of = %s, want the cycle's time", s.AsOf)
	}
	shown := snapshot.ShownSignals()
	if len(s.Signals) != len(shown) {
		t.Fatalf("%d signals, want %d", len(s.Signals), len(shown))
	}
	for n, sig := range s.Signals {
		if sig.ID != shown[n].ID {
			t.Errorf("signal %d is %s, want %s", n, sig.ID, shown[n].ID)
		}
		day, week, bucket := i(12), i(41), i(2)
		if sig.ID == "runtime_detections" {
			day, week, bucket = i(0), i(0), i(0)
		}
		if diff := cmp.Diff([2]*int{day, week}, [2]*int{sig.Count24h, sig.Count7d}); diff != "" {
			t.Errorf("%s counts mismatch (-want +got):\n%s", sig.ID, diff)
		}
		if len(sig.Buckets) != snapshot.Buckets {
			t.Fatalf("%s: %d buckets, want %d", sig.ID, len(sig.Buckets), snapshot.Buckets)
		}
		for b, v := range sig.Buckets {
			if diff := cmp.Diff(bucket, v); diff != "" {
				t.Errorf("%s bucket %d mismatch (-want +got):\n%s", sig.ID, b, diff)
			}
		}
	}
	want := strings.ReplaceAll(shown[0].Query, snapshot.Window, "24h")
	if e.fake.count(want) != 1 {
		t.Errorf("no query %s", want)
	}

	// Extrapolation: 24 h above 7 d is clamped, so the snapshot stays valid.
	e.fake.secDay, e.fake.secWeek = 41.2, 40.6
	e.now = e.now.Add(time.Minute)
	if got := e.push(t).Security.Signals[0]; *got.Count24h != 41 || *got.Count7d != 41 {
		t.Errorf("clamped counts = %d, %d, want 41, 41", *got.Count24h, *got.Count7d)
	}

	e.fake.noSecurity = true
	e.now = e.now.Add(time.Minute)
	for _, sig := range e.push(t).Security.Signals {
		zero := sig.ID == "admission_denied" || sig.ID == "runtime_detections"
		if got := sig.Count24h != nil && sig.Buckets[0] != nil; got != zero {
			t.Errorf("%s without a series: counts set %v, want %v", sig.ID, got, zero)
		}
	}
}

// The buckets are a range query over the 7 days ending at the cycle, one
// point every 6 hours.
func TestSecurityBucketsRange(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0))
	sig := snapshot.ShownSignals()[0]
	var got promRange
	q := &recordingQuerier{Querier: e.c.Prometheus, onRange: func(r promv1.Range) {
		got = promRange{r.Start, r.End, r.Step}
	}}
	if _, err := buckets(t.Context(), q, "x", strings.ReplaceAll(sig.Query, snapshot.Window, "6h"), e.now); err != nil {
		t.Fatal(err)
	}
	want := promRange{e.now.Add(-162 * time.Hour), e.now, 6 * time.Hour}
	if diff := cmp.Diff(want, got, cmp.AllowUnexported(promRange{})); diff != "" {
		t.Errorf("bucket range mismatch (-want +got):\n%s", diff)
	}
}

type recordingQuerier struct {
	Querier
	onRange func(promv1.Range)
}

func (r *recordingQuerier) QueryRange(ctx context.Context, query string, rg promv1.Range) (model.Matrix, error) {
	r.onRange(rg)
	return r.Querier.QueryRange(ctx, query, rg)
}
