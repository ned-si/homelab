package collector

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// scorecardAPI is a fake Scorecard API: it answers the fixture, edited by
// edit, or code when set, and counts the calls.
type scorecardAPI struct {
	mu     sync.Mutex
	code   int
	edit   func(map[string]any)
	calls  int
	agents []string
}

func (a *scorecardAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.calls++
	a.agents = append(a.agents, r.Header.Get("User-Agent"))
	if a.code != 0 {
		w.WriteHeader(a.code)
		return
	}
	b, err := os.ReadFile("testdata/scorecard.json")
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	if a.edit != nil {
		var doc map[string]any
		if err := json.Unmarshal(b, &doc); err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		a.edit(doc)
		b, _ = json.Marshal(doc)
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(b)
}

func (e *env) withScorecard(t *testing.T) *scorecardAPI {
	t.Helper()
	a := &scorecardAPI{}
	srv := httptest.NewServer(a)
	t.Cleanup(srv.Close)
	e.c.Scorecard = &Scorecard{URL: srv.URL + "/projects/github.com/ned-si/homelab", UserAgent: "homelab-dashboard/test", Client: srv.Client()}
	return a
}

func lastPush(t *testing.T, e *env) *snapshot.Snapshot {
	t.Helper()
	b := e.pods[0].bodies
	if len(b) == 0 {
		t.Fatal("no push")
	}
	s, err := snapshot.Validate(b[len(b)-1])
	if err != nil {
		t.Fatalf("Validate(pushed) = %v", err)
	}
	return s
}

func str(s string) *string { return &s }

// Requirement 13.5: the score to one decimal, its date and every check in
// name order, the inconclusive one without a score.
func TestScorecardResult(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	api := e.withScorecard(t)
	if !e.c.Cycle(t.Context()) {
		t.Fatal("Cycle() = false")
	}
	n := func(i int) *int { return &i }
	score := 7.5
	want := snapshot.Scorecard{
		AsOf:  str("2026-11-20T17:00:00+01:00"),
		Score: &score,
		Date:  str("2026-11-20T15:06:49+01:00"),
		Checks: []snapshot.ScorecardCheck{
			{Name: "Binary-Artifacts", Score: n(10), Reason: "no binaries found in the repo"},
			{Name: "Branch-Protection", Score: n(4), Reason: "branch protection is not maximal on development and all release branches"},
			{Name: "CI-Tests", Score: n(10), Reason: "30 out of 30 merged PRs checked by a CI test -- score normalized to 10"},
			{Name: "CII-Best-Practices", Score: n(2), Reason: "badge detected: InProgress"},
			{Name: "Code-Review", Score: n(0), Reason: "Found 0/28 approved changesets -- score normalized to 0"},
			{Name: "Contributors", Score: n(0), Reason: "project has 0 contributing companies or organizations -- score normalized to 0"},
			{Name: "Dangerous-Workflow", Score: n(10), Reason: "no dangerous workflow patterns detected"},
			{Name: "Dependency-Update-Tool", Score: n(10), Reason: "update tool detected"},
			{Name: "Fuzzing", Score: n(10), Reason: "project is fuzzed"},
			{Name: "License", Score: n(10), Reason: "license file detected"},
			{Name: "Maintained", Score: n(10), Reason: "30 commit(s) and 29 issue activity found in the last 90 days -- score normalized to 10"},
			{Name: "Packaging", Score: n(10), Reason: "packaging workflow detected"},
			{Name: "Pinned-Dependencies", Score: n(10), Reason: "all dependencies are pinned"},
			{Name: "SAST", Score: n(9), Reason: "SAST tool detected but not run on all commits"},
			{Name: "Security-Policy", Score: n(10), Reason: "security policy file detected"},
			{Name: "Signed-Releases", Reason: "no releases found"},
			{Name: "Token-Permissions", Score: n(10), Reason: "GitHub workflow tokens follow principle of least privilege"},
			{Name: "Vulnerabilities", Score: n(0), Reason: "29 existing vulnerabilities detected"},
		},
	}
	if diff := cmp.Diff(want, lastPush(t, e).SupplyChain.Scorecard); diff != "" {
		t.Errorf("scorecard (-want +got):\n%s", diff)
	}
	if got := api.agents[0]; got != "homelab-dashboard/test" {
		t.Errorf("User-Agent = %q", got)
	}
}

// Before the first fetch, and without a client, the block is empty and the
// snapshot still goes out.
func TestScorecardNone(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	if !e.c.Cycle(t.Context()) {
		t.Fatal("Cycle() = false")
	}
	sc := lastPush(t, e).SupplyChain.Scorecard
	if sc.AsOf != nil || sc.Score != nil || sc.Date != nil || len(sc.Checks) != 0 {
		t.Errorf("scorecard = %+v, want empty", sc)
	}
}

// Requirement 13.6: unknown names, a name twice, scores outside -1 to 10
// and reasons that are not plain text are dropped and counted.
func TestScorecardDropsChecks(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	api := e.withScorecard(t)
	api.edit = func(d map[string]any) {
		check := func(name string) map[string]any {
			for _, c := range d["checks"].([]any) {
				if m := c.(map[string]any); m["name"] == name {
					return m
				}
			}
			t.Errorf("no check %s in the fixture", name)
			return map[string]any{}
		}
		check("Code-Review")["name"] = "Made-Up"
		check("Contributors")["reason"] = strings.Repeat("x", 161)
		check("Vulnerabilities")["reason"] = "29 existing\nvulnerabilities"
		check("CII-Best-Practices")["score"] = 11
		check("Fuzzing")["score"] = -2
		d["checks"] = append(d["checks"].([]any), map[string]any{"name": "SAST", "score": 0, "reason": "again"})
	}
	if !e.c.Cycle(t.Context()) {
		t.Fatal("Cycle() = false")
	}
	var names []string
	for _, c := range lastPush(t, e).SupplyChain.Scorecard.Checks {
		names = append(names, c.Name)
	}
	want := []string{"Binary-Artifacts", "Branch-Protection", "CI-Tests", "Dangerous-Workflow", "Dependency-Update-Tool",
		"License", "Maintained", "Packaging", "Pinned-Dependencies", "SAST", "Security-Policy", "Signed-Releases",
		"Token-Permissions"}
	if diff := cmp.Diff(want, names); diff != "" {
		t.Errorf("checks (-want +got):\n%s", diff)
	}
	if got := testutil.ToFloat64(e.m.Errors.WithLabelValues("scorecard")); got != 6 {
		t.Errorf("collect_errors_total{scorecard} = %v, want 6", got)
	}
}

// One attempt an hour; a failed one keeps the last result, whose as_of
// then says from when.
func TestScorecardHourlyKeepsLast(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	api := e.withScorecard(t)
	for range 3 {
		if !e.c.Cycle(t.Context()) {
			t.Fatal("Cycle() = false")
		}
		e.now = e.now.Add(time.Minute)
	}
	if api.calls != 1 {
		t.Errorf("%d calls in 3 minutes, want 1", api.calls)
	}
	api.code = http.StatusServiceUnavailable
	e.now = zurich(2026, 11, 20, 18, 0)
	if !e.c.Cycle(t.Context()) {
		t.Fatal("Cycle() with the Scorecard API down = false")
	}
	if api.calls != 2 {
		t.Errorf("%d calls after an hour, want 2", api.calls)
	}
	sc := lastPush(t, e).SupplyChain.Scorecard
	if sc.AsOf == nil || *sc.AsOf != "2026-11-20T17:00:00+01:00" || sc.Score == nil {
		t.Errorf("scorecard after a failed fetch = %+v, want the result of 17:00", sc)
	}
	if got := testutil.ToFloat64(e.m.Runs.WithLabelValues("scorecard", "failure")); got != 1 {
		t.Errorf("collect_runs_total{scorecard,failure} = %v, want 1", got)
	}
}

func TestScorecardRefusesBadAnswer(t *testing.T) {
	for name, edit := range map[string]func(map[string]any){
		"no score":    func(d map[string]any) { delete(d, "score") },
		"score of 11": func(d map[string]any) { d["score"] = 11 },
		"no date":     func(d map[string]any) { d["date"] = "last week" },
	} {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
			e.withScorecard(t).edit = edit
			if _, _, err := e.c.Scorecard.Result(t.Context(), e.now); err == nil {
				t.Error("Result() = nil error, want one")
			}
		})
	}
}

func TestScorecardRedirect(t *testing.T) {
	for target, ok := range map[string]bool{
		"https://api.scorecard.dev/projects/github.com/ned-si/homelab":          true,
		"https://api.securityscorecards.dev/projects/github.com/ned-si/homelab": true,
		"http://api.scorecard.dev/projects/github.com/ned-si/homelab":           false,
		"https://example.com/projects/github.com/ned-si/homelab":                false,
	} {
		u, err := url.Parse(target)
		if err != nil {
			t.Fatal(err)
		}
		if err := ScorecardRedirect(&http.Request{URL: u}, nil); (err == nil) != ok {
			t.Errorf("ScorecardRedirect(%s) = %v, want allowed %v", target, err, ok)
		}
	}
}
