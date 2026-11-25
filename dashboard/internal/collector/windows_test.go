package collector

import (
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// The rolling windows of design.md, "Time windows", and the rework rate
// (acceptance criteria 23 and 30).

// ciSlices returns the created filters of the CI median's listings, in
// order, the first page of each.
func (f *fake) ciSlices() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, call := range f.github {
		u, _ := url.Parse(call)
		q := u.Query()
		if strings.HasSuffix(u.Path, "/actions/workflows/ci.yaml/runs") && q.Get("status") == "success" && q.Get("page") == "1" {
			out = append(out, q.Get("created"))
		}
	}
	return out
}

// The CI median covers every successful run of the 30 days, listed in
// 24-hour slices with no gap and no overlap, for windows of 719, 720 and
// 721 hours.
func TestCIMedianWindow(t *testing.T) {
	for _, tc := range []struct {
		now    time.Time
		hours  int
		slices int
	}{
		{zurich(2026, 4, 10, 17, 0), 719, 30},
		{zurich(2026, 12, 20, 17, 0), 720, 30},
		{zurich(2026, 11, 20, 17, 0), 721, 31},
	} {
		t.Run(tc.now.Format(snapshot.DateLayout), func(t *testing.T) {
			e := newEnv(t, tc.now, http.StatusNoContent)
			e.withToken(t)
			start := tc.now.In(snapshot.Zurich).AddDate(0, 0, -snapshot.Days)
			if got := int(tc.now.Sub(start).Hours()); got != tc.hours {
				t.Fatalf("window of %d h, want %d", got, tc.hours)
			}
			// 450 runs of 100 to 549 s, one every 5 min from the window's
			// start: more than the 300 newest, and 3 pages in a slice. A run
			// created at the end is outside the window.
			for k := range 450 {
				e.fake.ciRuns = append(e.fake.ciRuns, fakeRun{start.Add(time.Duration(k) * 5 * time.Minute), 100 + k})
			}
			e.fake.ciRuns = append(e.fake.ciRuns, fakeRun{tc.now, 20000})
			p := e.push(t).Project
			// The median of 100..549 is 324.5, rounded half to even.
			if diff := cmp.Diff(i(324), p.CIMedianSeconds30d); diff != "" {
				t.Errorf("ci_median_seconds_30d mismatch (-want +got):\n%s", diff)
			}
			got := e.fake.ciSlices()
			if len(got) != tc.slices {
				t.Fatalf("%d slices, want %d: %v", len(got), tc.slices, got)
			}
			next := utc(start)
			for n, c := range got {
				from, to, _ := strings.Cut(c, "..")
				if from != next {
					t.Errorf("slice %d starts at %s, want %s", n, from, next)
				}
				end, err := time.Parse(time.RFC3339, to)
				if err != nil {
					t.Fatal(err)
				}
				if span := end.Add(time.Second).Sub(mustUTC(t, from)); span > ciSlice {
					t.Errorf("slice %d spans %v, more than %v", n, span, ciSlice)
				}
				next = utc(end.Add(time.Second))
			}
			if want := utc(tc.now); next != want {
				t.Errorf("the last slice ends before %s, want %s", next, want)
			}
		})
	}
}

func mustUTC(t *testing.T, s string) time.Time {
	t.Helper()
	v, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// A slice at the runs API's cap of 1,000 results fails the project block,
// rather than an undercount.
func TestCIMedianCap(t *testing.T) {
	e := doraEnv(t)
	day := doraNow.Add(-3 * 24 * time.Hour)
	for k := range runsCap {
		e.fake.ciRuns = append(e.fake.ciRuns, fakeRun{day.Add(time.Duration(k) * time.Minute), 300})
	}
	if e.c.Cycle(t.Context()) {
		t.Error("Cycle() with a slice of 1,000 runs = true, want the project block failed and no push")
	}
	if _, _, err := e.c.readProject(t.Context(), doraNow); err == nil || !strings.Contains(err.Error(), "cap") {
		t.Errorf("readProject() = %v, want the cap error", err)
	}
}

// Without the token the CI median lists no runs and is null.
func TestCIMedianWithoutToken(t *testing.T) {
	e := newEnv(t, doraNow, http.StatusNoContent)
	if got := e.push(t).Project.CIMedianSeconds30d; got != nil {
		t.Errorf("ci_median_seconds_30d without a token = %d, want null", *got)
	}
	if n := len(e.fake.ciSlices()); n != 0 {
		t.Errorf("%d listings of runs for the median without a token, want none", n)
	}
}

// Incidents count when they started in the window and ended: a firing
// already firing at the window's start and a rollback of a change merged
// before the window are left out.
func TestIncidentsStartInWindow(t *testing.T) {
	e := doraEnv(t)
	start := doraNow.In(snapshot.Zurich).AddDate(0, 0, -snapshot.Days)
	e.fake.alerts = []firing{
		{map[string]string{"alertname": "Before"}, start.Add(-time.Hour), start.Add(30 * time.Minute)},
		{map[string]string{"alertname": "After"}, start.Add(2 * time.Hour), start.Add(2*time.Hour + 10*time.Minute)},
	}
	m := doraNow.Add(-48 * time.Hour)
	e.fake.prs = []fakePR{{Title: `Revert "feat: old"`, Labels: []string{"auto-rollback"}, CreatedAt: m.Add(-10 * time.Minute),
		MergedAt: m, Files: []string{"deploy/a.yaml"}, OID: "fff",
		Message: "Revert \"feat: old\"\n\nThis reverts commit 0123456789abcdef0123456789abcdef01234567.",
		Synced:  []time.Time{m.Add(5 * time.Minute)}}}
	p := e.push(t).Project
	if diff := cmp.Diff([3]*int{i(1), i(600), i(1)}, [3]*int{p.Incidents30d, p.RestoreSeconds, p.FailedChanges30d}); diff != "" {
		t.Errorf("incidents, restore, failed changes mismatch (-want +got):\n%s", diff)
	}
}

// TestRework is the table test of the rework rule (requirements.md, 10.9).
func TestRework(t *testing.T) {
	start := doraNow.In(snapshot.Zurich).AddDate(0, 0, -snapshot.Days)
	from := doraNow.Add(-72 * time.Hour)
	to := from.Add(20 * time.Minute)
	incident := []interval{{start: from, end: to}}
	deploy := []string{"deploy/apps/a.yaml"}
	tests := []struct {
		name string
		pr   fakePR
		want int
	}{
		{"fix inside the incident", fakePR{Title: "fix: x", MergedAt: from.Add(10 * time.Minute), Files: deploy}, 1},
		{"fix at the incident's start", fakePR{Title: "fix: x", MergedAt: from, Files: deploy}, 1},
		{"fix 24 h after its end", fakePR{Title: "fix(cook): x", MergedAt: to.Add(24 * time.Hour), Files: deploy}, 1},
		{"fix 24 h and 1 s after its end", fakePR{Title: "fix: x", MergedAt: to.Add(24*time.Hour + time.Second), Files: deploy}, 0},
		{"fix before the incident", fakePR{Title: "fix: x", MergedAt: from.Add(-time.Second), Files: deploy}, 0},
		{"breaking fix", fakePR{Title: "fix!: x", MergedAt: from, Files: deploy}, 1},
		{"fix that deploys nothing", fakePR{Title: "fix: x", MergedAt: from, Files: []string{"docs/x.md"}}, 0},
		{"feat during the incident", fakePR{Title: "feat: x", MergedAt: from, Files: deploy}, 0},
		{"fix without the colon", fakePR{Title: "fixes: x", MergedAt: from, Files: deploy}, 0},
		{"rollback far from any incident", fakePR{Title: "feat: x", Labels: []string{"auto-rollback"}, MergedAt: doraNow.Add(-time.Hour)}, 1},
		{"fix forward", fakePR{Title: "docs: x", Labels: []string{"fix-forward"}, MergedAt: doraNow.Add(-time.Hour)}, 1},
		{"rollback titled fix during the incident, once", fakePR{Title: `fix: Revert "feat: x"`, Labels: []string{"auto-rollback"},
			MergedAt: from, Files: deploy}, 1},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			m := merged{title: tc.pr.Title, createdAt: tc.pr.MergedAt.Add(-time.Hour), mergedAt: tc.pr.MergedAt, labels: tc.pr.Labels}
			for _, f := range tc.pr.Files {
				m.deploys = m.deploys || strings.HasPrefix(f, "deploy/") || strings.HasPrefix(f, "clusters/")
			}
			p := snapshot.Project{Deploys30d: 10}
			setDORA(&p, []merged{m}, incident, start, doraNow)
			want := &snapshot.Rework{Count: tc.want, Deploys: 10, Rate: f64(float64(tc.want) / 10)}
			if diff := cmp.Diff(want, p.Rework); diff != "" {
				t.Errorf("rework mismatch (-want +got):\n%s", diff)
			}
		})
	}
	p := snapshot.Project{}
	setDORA(&p, nil, nil, start, doraNow)
	if diff := cmp.Diff(&snapshot.Rework{}, p.Rework); diff != "" {
		t.Errorf("rework without a deploy mismatch (-want +got):\n%s", diff)
	}
}

// doraFixture is testdata/dora-window.json, which
// tests/bash/test_dashboard_dora_check.sh feeds to
// scripts/dashboard-dora-check.sh.
type doraFixture struct {
	End     time.Time `json:"end"`
	Firings []struct {
		Labels map[string]string `json:"labels"`
		From   time.Time         `json:"from"`
		To     time.Time         `json:"to"`
	} `json:"firings"`
	PRs []struct {
		Title     string    `json:"title"`
		CreatedAt time.Time `json:"createdAt"`
		MergedAt  time.Time `json:"mergedAt"`
		Labels    struct {
			Nodes []struct {
				Name string `json:"name"`
			} `json:"nodes"`
		} `json:"labels"`
		Files struct {
			Nodes []struct {
				Path string `json:"path"`
			} `json:"nodes"`
		} `json:"files"`
		MergeCommit struct {
			OID     string `json:"oid"`
			Message string `json:"message"`
			Status  *struct {
				Contexts []struct {
					CreatedAt time.Time `json:"createdAt"`
				} `json:"contexts"`
			} `json:"status"`
		} `json:"mergeCommit"`
	} `json:"prs"`
	Want struct {
		FailedChanges int `json:"failed_changes_30d"`
		Incidents     int `json:"incidents_30d"`
		Restore       int `json:"restore_seconds"`
		Rework        int `json:"rework_count"`
	} `json:"want"`
}

// The collector agrees with the recount of scripts/dashboard-dora-check.sh
// on a fixture with a firing that crosses the window's start.
func TestDORAWindowFixture(t *testing.T) {
	b, err := os.ReadFile("testdata/dora-window.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx doraFixture
	if err := json.Unmarshal(b, &fx); err != nil {
		t.Fatal(err)
	}
	e := newEnv(t, fx.End, http.StatusNoContent)
	e.withToken(t)
	for _, f := range fx.Firings {
		e.fake.alerts = append(e.fake.alerts, firing{f.Labels, f.From, f.To})
	}
	for _, n := range fx.PRs {
		pr := fakePR{Title: n.Title, CreatedAt: n.CreatedAt, MergedAt: n.MergedAt, OID: n.MergeCommit.OID, Message: n.MergeCommit.Message}
		for _, l := range n.Labels.Nodes {
			pr.Labels = append(pr.Labels, l.Name)
		}
		for _, f := range n.Files.Nodes {
			pr.Files = append(pr.Files, f.Path)
		}
		if s := n.MergeCommit.Status; s != nil {
			for _, c := range s.Contexts {
				pr.Synced = append(pr.Synced, c.CreatedAt)
			}
		}
		e.fake.prs = append(e.fake.prs, pr)
	}
	p := e.push(t).Project
	if p.Rework == nil {
		t.Fatal("rework = null with the token")
	}
	w := fx.Want
	if diff := cmp.Diff([4]*int{&w.FailedChanges, &w.Incidents, &w.Restore, &w.Rework},
		[4]*int{p.FailedChanges30d, p.Incidents30d, p.RestoreSeconds, &p.Rework.Count}); diff != "" {
		t.Errorf("failed changes, incidents, restore, rework mismatch (-want +got):\n%s", diff)
	}
}
