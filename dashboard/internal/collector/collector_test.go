package collector

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/ned-si/homelab/dashboard/internal/metrics"
	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// fake is a Prometheus and a GitHub API with the values of the publisher's
// test fake (tests/website/test_publisher.py), so --as-of can be compared
// with the publisher's recorded output.
type fake struct {
	mu          sync.Mutex
	queries     []string
	queryTimes  map[string][]time.Time
	github      []string
	auth        []string
	promFail    bool
	promEmpty   string
	githubCode  int
	githubReset int64
	avail       map[string]float64
	budget      map[string]float64
	osImages    []string
	kubelets    []string
	nodes       float64
	blogSince   time.Time
	noProbe     map[string]bool
}

func newFake() *fake {
	f := &fake{
		queryTimes: map[string][]time.Time{},
		avail: map[string]float64{"media": 0.99956, "cook": 0.9991, "archive": 0.9918, "cinema": 1.0,
			"syncthing": 0.996, "auth": 0.9954, "nedsi": 0.9844, "blog": 0.9995},
		osImages:  []string{"Talos (v1.14.6)"},
		kubelets:  []string{"v1.37.2"},
		nodes:     4,
		blogSince: time.Date(2026, 11, 15, 0, 0, 0, 0, snapshot.Zurich),
		noProbe:   map[string]bool{},
	}
	f.budget = map[string]float64{}
	for k, v := range f.avail {
		f.budget[k] = 1 - (1-v)/0.005
	}
	return f
}

type sample struct {
	Metric map[string]string `json:"metric"`
	Value  [2]any            `json:"value"`
}

func vec(at float64, labels map[string]string, v float64) sample {
	return sample{Metric: labels, Value: [2]any{at, strconv.FormatFloat(v, 'g', -1, 64)}}
}

var appRE = regexp.MustCompile(`app=~"([^"]+)"`)

func (f *fake) prom(query string, at float64) []sample {
	var apps []string
	if m := appRE.FindStringSubmatch(query); m != nil {
		apps = strings.Split(m[1], "|")
	}
	series := func(values map[string]float64, keep func(string) bool) []sample {
		out := []sample{}
		for _, a := range apps {
			if v, ok := values[a]; ok && keep(a) {
				out = append(out, vec(at, map[string]string{"app": a}, v))
			}
		}
		return out
	}
	all := func(string) bool { return true }
	switch {
	case f.promEmpty != "" && strings.HasPrefix(query, f.promEmpty):
		return []sample{}
	case strings.HasPrefix(query, "slo:availability:ratio_rate30d"):
		return series(f.avail, all)
	case strings.HasPrefix(query, "slo:error_budget_remaining:ratio_rate30d"):
		return series(f.budget, all)
	case strings.HasPrefix(query, "1 - slo:probe_error:ratio_rate1d"):
		return series(f.avail, func(a string) bool {
			return !f.noProbe[a] && (a != "blog" || at > float64(f.blogSince.Unix()))
		})
	case query == "count(kube_node_info)":
		return []sample{vec(at, map[string]string{}, f.nodes)}
	case query == "count(argocd_app_info)":
		return []sample{vec(at, map[string]string{}, 55)}
	case query == "count by (os_image) (kube_node_info)":
		out := []sample{}
		for _, v := range f.osImages {
			out = append(out, vec(at, map[string]string{"os_image": v}, 1))
		}
		return out
	case query == "count by (kubelet_version) (kube_node_info)":
		out := []sample{}
		for _, v := range f.kubelets {
			out = append(out, vec(at, map[string]string{"kubelet_version": v}, 1))
		}
		return out
	}
	panic("unexpected query " + query)
}

func (f *fake) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	reply := func(code int, body any) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		_ = json.NewEncoder(w).Encode(body)
	}
	if r.URL.Path == "/api/v1/query" {
		if err := r.ParseForm(); err != nil {
			reply(http.StatusBadRequest, nil)
			return
		}
		q := r.Form.Get("query")
		at, _ := strconv.ParseFloat(r.Form.Get("time"), 64)
		f.queries = append(f.queries, q)
		f.queryTimes[q] = append(f.queryTimes[q], time.Unix(int64(at), 0))
		if f.promFail {
			reply(http.StatusServiceUnavailable, map[string]string{"status": "error", "errorType": "unavailable", "error": "boom"})
			return
		}
		reply(http.StatusOK, map[string]any{"status": "success",
			"data": map[string]any{"resultType": "vector", "result": f.prom(q, at)}})
		return
	}
	f.github = append(f.github, r.URL.RequestURI())
	f.auth = append(f.auth, r.Header.Get("Authorization"))
	w.Header().Set("X-RateLimit-Remaining", "42")
	if f.githubCode != 0 {
		if f.githubReset != 0 {
			w.Header().Set("X-RateLimit-Remaining", "0")
			w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(f.githubReset, 10))
		}
		reply(f.githubCode, map[string]string{"message": "no"})
		return
	}
	switch {
	case r.URL.Path == "/search/issues":
		n := 300
		if strings.Contains(r.URL.Query().Get("q"), "author:app/renovate") {
			n = 120
		}
		reply(http.StatusOK, map[string]any{"total_count": n, "incomplete_results": false, "items": []any{}})
	case strings.HasSuffix(r.URL.Path, "/actions/workflows/ci.yaml/runs"):
		start := time.Date(2026, 11, 10, 10, 0, 0, 0, time.UTC)
		var runs []map[string]string
		for _, s := range []int{600, 700, 900} {
			runs = append(runs, map[string]string{
				"run_started_at": start.Format(time.RFC3339),
				"updated_at":     start.Add(time.Duration(s) * time.Second).Format(time.RFC3339),
			})
		}
		reply(http.StatusOK, map[string]any{"total_count": len(runs), "workflow_runs": runs})
	default:
		reply(http.StatusNotFound, nil)
	}
}

func (f *fake) count(prefix string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, q := range f.queries {
		if strings.HasPrefix(q, prefix) {
			n++
		}
	}
	return n
}

func (f *fake) githubCalls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.github)
}

// pod is a fake web pod that records the pushes it gets.
type pod struct {
	mu     sync.Mutex
	code   int
	bodies [][]byte
	sigs   []string
}

func (p *pod) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p.mu.Lock()
	defer p.mu.Unlock()
	b, _ := io.ReadAll(r.Body)
	if r.URL.Path != PushPath || r.Header.Get("Content-Type") != "application/json" {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	p.bodies = append(p.bodies, b)
	p.sigs = append(p.sigs, r.Header.Get(snapshot.SignatureHeader))
	w.WriteHeader(p.code)
}

type env struct {
	fake *fake
	pods []*pod
	c    *Collector
	m    *metrics.Collector
	now  time.Time
	pub  ed25519.PublicKey
}

func newEnv(t *testing.T, now time.Time, codes ...int) *env {
	t.Helper()
	e := &env{fake: newFake(), now: now}
	srv := httptest.NewServer(e.fake)
	t.Cleanup(srv.Close)
	var targets []string
	for _, code := range codes {
		p := &pod{code: code}
		ps := httptest.NewServer(p)
		t.Cleanup(ps.Close)
		e.pods = append(e.pods, p)
		targets = append(targets, ps.URL)
	}
	prom, err := NewPrometheus(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	pub, key, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	e.pub = pub
	tokenFile := filepath.Join(t.TempDir(), "token")
	e.m = metrics.NewCollector(prometheus.NewRegistry())
	e.c = &Collector{
		Prometheus: prom,
		GitHub: &GitHub{
			BaseURL: srv.URL, Repo: "ned-si/homelab", Workflow: "ci.yaml", TokenFile: tokenFile,
			UserAgent: "homelab-dashboard/test", Client: srv.Client(),
			Remaining: func(n int) { e.m.RateLimitRemaining.Set(float64(n)) },
		},
		Pusher: &Pusher{
			Targets: func(context.Context) ([]string, error) { return targets, nil },
			Client:  srv.Client(),
		},
		Key:     key,
		Metrics: e.m,
		Logger:  slog.New(slog.NewTextHandler(io.Discard, nil)),
		Now:     func() time.Time { return e.now },
	}
	return e
}

func (e *env) withToken(t *testing.T) {
	t.Helper()
	if err := os.WriteFile(e.c.GitHub.TokenFile, []byte("test-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func zurich(y int, mo time.Month, d, h, mi int) time.Time {
	return time.Date(y, mo, d, h, mi, 0, 0, snapshot.Zurich)
}

func TestDailyCovers(t *testing.T) {
	tests := []struct {
		now  time.Time
		want string
	}{
		{zurich(2026, 11, 20, 3, 44), "2026-11-18"},
		{zurich(2026, 11, 20, 3, 45), "2026-11-19"},
		{zurich(2026, 11, 20, 23, 59), "2026-11-19"},
		{zurich(2026, 11, 21, 0, 0), "2026-11-19"},
		{zurich(2026, 3, 30, 4, 0), "2026-03-29"},
		{zurich(2026, 10, 26, 4, 0), "2026-10-25"},
	}
	for _, tc := range tests {
		if got := DailyCovers(tc.now).Format(snapshot.DateLayout); got != tc.want {
			t.Errorf("DailyCovers(%v) = %s, want %s", tc.now, got, tc.want)
		}
	}
}

func TestCyclePushesFullSnapshot(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent, http.StatusNoContent)
	e.withToken(t)
	if !e.c.Cycle(t.Context()) {
		t.Fatal("Cycle() = false, want true")
	}
	for i, p := range e.pods {
		if len(p.bodies) != 1 {
			t.Fatalf("pod %d got %d pushes, want 1", i, len(p.bodies))
		}
		if !snapshot.Verify([]ed25519.PublicKey{e.pub}, p.sigs[0], p.bodies[0]) {
			t.Errorf("pod %d: signature does not verify", i)
		}
	}
	s, err := snapshot.Validate(e.pods[0].bodies[0])
	if err != nil {
		t.Fatalf("Validate(pushed) = %v", err)
	}
	if got, want := s.GeneratedAt, "2026-11-20T17:00:00+01:00"; got != want {
		t.Errorf("generated_at = %s, want %s", got, want)
	}
	if got, want := s.Daily.Covers, "2026-11-19"; got != want {
		t.Errorf("daily.covers = %s, want %s", got, want)
	}
	if got, want := s.Cluster, (snapshot.Cluster{AsOf: s.GeneratedAt, Nodes: 4, Apps: 55,
		TalosVersion: "v1.14.6", KubernetesVersion: "v1.37.2"}); got != want {
		t.Errorf("cluster = %+v, want %+v", got, want)
	}
	if got, want := s.Project, (snapshot.Project{AsOf: s.GeneratedAt, PRsMerged30d: 300, RenovateShare30d: 40,
		CIMedianSeconds30d: 700}); got != want {
		t.Errorf("project = %+v, want %+v", got, want)
	}
	if got := testutil.ToFloat64(e.m.Pushes.WithLabelValues("accepted")); got != 2 {
		t.Errorf("push_total{accepted} = %v, want 2", got)
	}
	if got := testutil.ToFloat64(e.m.TokenValid); got != 1 {
		t.Errorf("github_token_valid = %v, want 1", got)
	}
	if got := testutil.ToFloat64(e.m.RateLimitRemaining); got != 42 {
		t.Errorf("github_ratelimit_remaining = %v, want 42", got)
	}
	for _, a := range e.fake.auth {
		if a != "Bearer test-token" {
			t.Errorf("Authorization = %q, want the token", a)
		}
	}
	// Only the shown apps are ever queried.
	for _, q := range e.fake.queries {
		if m := appRE.FindStringSubmatch(q); m != nil && snapshot.Hidden(m[1]) {
			t.Errorf("query %q names hidden tooling", q)
		}
	}
}

func TestPusherOneRefusing(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent, http.StatusUnauthorized)
	if e.c.Cycle(t.Context()) {
		t.Error("Cycle() = true with one pod refusing, want false")
	}
	if got := testutil.ToFloat64(e.m.Pushes.WithLabelValues("accepted")); got != 1 {
		t.Errorf("push_total{accepted} = %v, want 1", got)
	}
	if got := testutil.ToFloat64(e.m.Pushes.WithLabelValues("rejected")); got != 1 {
		t.Errorf("push_total{rejected} = %v, want 1", got)
	}
}

func TestFailingSourceKeepsLastBlock(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	if !e.c.Cycle(t.Context()) {
		t.Fatal("first Cycle() = false")
	}
	e.fake.promFail = true
	e.now = e.now.Add(time.Minute)
	if !e.c.Cycle(t.Context()) {
		t.Fatal("Cycle() with Prometheus down = false, want a push with the last cluster block")
	}
	s, err := snapshot.Validate(e.pods[0].bodies[1])
	if err != nil {
		t.Fatal(err)
	}
	if got, want := s.Cluster.AsOf, "2026-11-20T17:00:00+01:00"; got != want {
		t.Errorf("cluster.as_of = %s, want the last good %s", got, want)
	}
	if got := testutil.ToFloat64(e.m.Errors.WithLabelValues("prometheus")); got != 1 {
		t.Errorf("collect_errors_total{prometheus} = %v, want 1", got)
	}
	if got := testutil.ToFloat64(e.m.Runs.WithLabelValues("cluster", "failure")); got != 1 {
		t.Errorf("collect_runs_total{cluster,failure} = %v, want 1", got)
	}
}

func TestNoPushUntilEveryBlock(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	e.fake.promEmpty = "slo:availability"
	if e.c.Cycle(t.Context()) {
		t.Error("Cycle() without a daily block = true, want false")
	}
	if len(e.pods[0].bodies) != 0 {
		t.Errorf("got %d pushes, want none", len(e.pods[0].bodies))
	}
	// The daily block is retried at the next cycle.
	e.fake.promEmpty = ""
	e.now = e.now.Add(time.Minute)
	if !e.c.Cycle(t.Context()) {
		t.Error("Cycle() after recovery = false, want true")
	}
}

func TestEmptyClusterResult(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	e.fake.promEmpty = "count(kube_node_info)"
	if e.c.Cycle(t.Context()) {
		t.Error("Cycle() with no nodes = true, want false")
	}
}

func TestBudgetClampedAndNoProbeDay(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	e.fake.budget["nedsi"] = -3.2
	e.fake.noProbe["cook"] = true
	s, _, err := e.c.Collect(t.Context(), e.now, DailyCovers(e.now))
	if err != nil {
		t.Fatal(err)
	}
	if got := s.Daily.Apps[6].ErrorBudgetRemaining30d; got != -100 {
		t.Errorf("landing budget = %d, want -100", got)
	}
	for i, v := range s.Daily.Apps[1].AvailabilityDaily {
		if v != nil {
			t.Errorf("mealie availability_daily[%d] = %v, want null", i, *v)
		}
	}
}

func TestVersionMidUpgrade(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	e.fake.osImages = []string{"Talos (v1.14.10)", "Talos (v1.14.9)"}
	e.fake.kubelets = []string{"v1.38.0", "v1.37.2"}
	s, _, err := e.c.Collect(t.Context(), e.now, DailyCovers(e.now))
	if err != nil {
		t.Fatal(err)
	}
	if got, want := s.Cluster.TalosVersion, "v1.14.9"; got != want {
		t.Errorf("talos_version = %s, want %s", got, want)
	}
	if got, want := s.Cluster.KubernetesVersion, "v1.37.2"; got != want {
		t.Errorf("kubernetes_version = %s, want %s", got, want)
	}
	e.fake.osImages = []string{"Talos (unknown)"}
	if _, _, err := e.c.Collect(t.Context(), e.now, DailyCovers(e.now)); err == nil {
		t.Error("Collect() with no version in os_image = nil error, want an error")
	}
}

func TestDailyQueriesAtZurichMidnights(t *testing.T) {
	for _, covers := range []time.Time{zurich(2026, 3, 29, 0, 0), zurich(2026, 10, 25, 0, 0)} {
		t.Run(covers.Format(snapshot.DateLayout), func(t *testing.T) {
			e := newEnv(t, covers.AddDate(0, 0, 1).Add(5*time.Hour))
			if _, err := daily(t.Context(), e.c.Prometheus, covers); err != nil {
				t.Fatal(err)
			}
			var times []time.Time
			for q, ts := range e.fake.queryTimes {
				if strings.HasPrefix(q, "1 - slo:probe_error") {
					times = ts
				}
			}
			if len(times) != snapshot.Days {
				t.Fatalf("%d daily queries, want %d", len(times), snapshot.Days)
			}
			for i, at := range times {
				l := at.In(snapshot.Zurich)
				if l.Hour() != 0 || l.Minute() != 0 {
					t.Errorf("daily query %d at %v, want a Zurich midnight", i, l)
				}
			}
			if got, want := times[len(times)-1], snapshot.AddDays(covers, 1); !got.Equal(want) {
				t.Errorf("last daily query at %v, want %v", got, want)
			}
		})
	}
}

func TestDailyCadence(t *testing.T) {
	// Start-up before 03:45 serves the day before yesterday, then
	// yesterday from the first cycle after 03:45; once a day only.
	e := newEnv(t, zurich(2026, 11, 20, 3, 40), http.StatusNoContent)
	e.c.Cycle(t.Context())
	if got, want := e.c.daily.Covers, "2026-11-18"; got != want {
		t.Errorf("covers at 03:40 = %s, want %s", got, want)
	}
	e.now = zurich(2026, 11, 20, 3, 44)
	e.c.Cycle(t.Context())
	if n := e.fake.count("slo:availability"); n != 1 {
		t.Errorf("daily computed %d times by 03:44, want 1", n)
	}
	e.now = zurich(2026, 11, 20, 3, 45)
	e.c.Cycle(t.Context())
	if got, want := e.c.daily.Covers, "2026-11-19"; got != want {
		t.Errorf("covers at 03:45 = %s, want %s", got, want)
	}
	e.now = zurich(2026, 11, 20, 17, 0)
	e.c.Cycle(t.Context())
	if n := e.fake.count("slo:availability"); n != 2 {
		t.Errorf("daily computed %d times by 17:00, want 2", n)
	}
	if n := e.fake.count("count(kube_node_info)"); n != 4 {
		t.Errorf("cluster refreshed %d times in 4 cycles, want 4", n)
	}
}

func TestProjectCadence(t *testing.T) {
	tests := []struct {
		name    string
		token   bool
		cadence time.Duration
	}{
		{"with a token", true, 15 * time.Minute},
		{"anonymous", false, 60 * time.Minute},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			start := zurich(2026, 11, 20, 17, 0)
			e := newEnv(t, start, http.StatusNoContent)
			if tc.token {
				e.withToken(t)
			}
			e.c.Cycle(t.Context())
			calls := e.fake.githubCalls()
			e.now = start.Add(tc.cadence - time.Minute)
			e.c.Cycle(t.Context())
			if got := e.fake.githubCalls(); got != calls {
				t.Errorf("GitHub calls before the cadence: %d, want %d", got, calls)
			}
			e.now = start.Add(tc.cadence)
			e.c.Cycle(t.Context())
			if got := e.fake.githubCalls(); got != 2*calls {
				t.Errorf("GitHub calls at the cadence: %d, want %d", got, 2*calls)
			}
			for _, a := range e.fake.auth {
				if (a != "") != tc.token {
					t.Errorf("Authorization = %q with token %v", a, tc.token)
				}
			}
		})
	}
}

func TestRateLimitMovesRefresh(t *testing.T) {
	start := zurich(2026, 11, 20, 17, 0)
	e := newEnv(t, start, http.StatusNoContent)
	e.withToken(t)
	reset := start.Add(40 * time.Minute)
	e.fake.githubCode, e.fake.githubReset = http.StatusForbidden, reset.Unix()
	e.c.Cycle(t.Context())
	if got, want := e.c.nextProject, reset.Add(30*time.Second); !got.Equal(want) {
		t.Errorf("next project refresh = %v, want %v", got, want)
	}
	if got := testutil.ToFloat64(e.m.RateLimitRemaining); got != 0 {
		t.Errorf("github_ratelimit_remaining = %v, want 0", got)
	}
	e.fake.githubCode, e.fake.githubReset = 0, 0
	calls := e.fake.githubCalls()
	e.now = start.Add(20 * time.Minute)
	e.c.Cycle(t.Context())
	if got := e.fake.githubCalls(); got != calls {
		t.Errorf("GitHub called before the reset: %d calls, want %d", got, calls)
	}
	e.now = reset.Add(time.Minute)
	if !e.c.Cycle(t.Context()) {
		t.Error("Cycle() after the reset = false, want true")
	}
}

func TestTokenRejected(t *testing.T) {
	start := zurich(2026, 11, 20, 17, 0)
	e := newEnv(t, start, http.StatusNoContent)
	e.withToken(t)
	e.c.Cycle(t.Context())
	e.fake.githubCode = http.StatusUnauthorized
	e.now = start.Add(15 * time.Minute)
	if !e.c.Cycle(t.Context()) {
		t.Fatal("Cycle() after a 401 = false, want a push with the last project block")
	}
	if got := testutil.ToFloat64(e.m.TokenValid); got != 0 {
		t.Errorf("github_token_valid = %v, want 0", got)
	}
	if got := testutil.ToFloat64(e.m.Errors.WithLabelValues("github")); got != 1 {
		t.Errorf("collect_errors_total{github} = %v, want 1", got)
	}
	for i, a := range e.fake.auth {
		if a == "" {
			t.Errorf("GitHub call %d was anonymous: no fallback wanted", i)
		}
	}
	s, err := snapshot.Validate(e.pods[0].bodies[1])
	if err != nil {
		t.Fatal(err)
	}
	if got, want := s.Project.AsOf, "2026-11-20T17:00:00+01:00"; got != want {
		t.Errorf("project.as_of = %s, want the last good %s", got, want)
	}
}

func TestValidationFailurePushesNothing(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	// Eleven nodes is outside the schema's range.
	e.fake.nodes = 11
	if e.c.Cycle(t.Context()) {
		t.Error("Cycle() with an invalid snapshot = true, want false")
	}
	if len(e.pods[0].bodies) != 0 {
		t.Errorf("got %d pushes, want none", len(e.pods[0].bodies))
	}
	if got := testutil.ToFloat64(e.m.Errors.WithLabelValues("validation")); got != 1 {
		t.Errorf("collect_errors_total{validation} = %v, want 1", got)
	}
}

// TestAsOfMatchesPublisher compares --as-of with the publisher's output
// for the same fake, recorded in testdata/publisher-figures.json.
func TestAsOfMatchesPublisher(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0))
	covers := zurich(2026, 11, 19, 0, 0)
	s, _, err := e.c.Collect(t.Context(), snapshot.AddDays(covers, 1), covers)
	if err != nil {
		t.Fatal(err)
	}
	f, err := ToFigures(s)
	if err != nil {
		t.Fatal(err)
	}
	got := normalise(t, f)
	want := readJSON(t, "testdata/publisher-figures.json")
	delete(got, "computed_at")
	delete(want, "computed_at")
	if diff := cmp.Diff(want, got); diff != "" {
		t.Errorf("--as-of mismatch with the publisher (-want +got):\n%s", diff)
	}
	wantCalls := []string{
		"/search/issues?per_page=1&q=repo%3Aned-si%2Fhomelab+is%3Apr+is%3Amerged+merged%3A2026-10-20T22%3A00%3A00Z..2026-11-19T22%3A59%3A59Z",
		"/search/issues?per_page=1&q=repo%3Aned-si%2Fhomelab+is%3Apr+is%3Amerged+merged%3A2026-10-20T22%3A00%3A00Z..2026-11-19T22%3A59%3A59Z+author%3Aapp%2Frenovate",
		"/repos/ned-si/homelab/actions/workflows/ci.yaml/runs?created=2026-10-20T22%3A00%3A00Z..2026-11-19T22%3A59%3A59Z&exclude_pull_requests=true&page=1&per_page=100&status=success",
	}
	if diff := cmp.Diff(wantCalls, e.fake.github); diff != "" {
		t.Errorf("GitHub calls mismatch (-want +got):\n%s", diff)
	}
}

func normalise(t *testing.T, v any) map[string]any {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func readJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(path) //nolint:gosec // G304: a fixture under testdata/.
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.NewDecoder(bytes.NewReader(b)).Decode(&m); err != nil {
		t.Fatal(err)
	}
	return m
}
