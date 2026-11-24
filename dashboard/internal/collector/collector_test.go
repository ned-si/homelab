package collector

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"net/http/httptest"
	"net/url"
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

// fake is a Prometheus and a GitHub API.
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

	// Version 2.
	down      map[string]bool
	certDays  map[string]float64
	noUse     bool
	noNAS     bool
	noGateway bool
	alerts    []firing
	ranges    []promRange
	prs       []fakePR
	runs      []map[string]any
	graphql   int
}

// firing is a paging alert's firing in the fake ALERTS series.
type firing struct {
	labels   map[string]string
	from, to time.Time
}

type promRange struct {
	start, end time.Time
	step       time.Duration
}

// fakePR is a merged pull request of the fake GraphQL search.
type fakePR struct {
	Title     string
	CreatedAt time.Time
	MergedAt  time.Time
	Labels    []string
	Files     []string
	// MoreFiles is added to the file count beyond Files.
	MoreFiles int
	OID       string
	Message   string
	// Synced are the times of argocd/* success statuses.
	Synced []time.Time
}

func newFake() *fake {
	f := &fake{
		queryTimes: map[string][]time.Time{},
		avail: map[string]float64{"media": 0.99956, "cook": 0.9991, "archive": 0.9918, "watch": 1.0,
			"syncthing": 0.996, "auth": 0.9954, "observability": 0.9990, "nedsi": 0.9844, "blog": 0.9995, "homelab": 0.9999},
		osImages:  []string{"Talos (v1.14.6)"},
		kubelets:  []string{"v1.37.2"},
		nodes:     4,
		blogSince: time.Date(2026, 11, 15, 0, 0, 0, 0, snapshot.Zurich),
		noProbe:   map[string]bool{},
		down:      map[string]bool{},
		certDays:  map[string]float64{"lilalala": 39.7, "nedsi": 82.2},
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
	if out, ok := f.prom2(query, at, apps); ok {
		return out
	}
	panic("unexpected query " + query)
}

func (f *fake) nodeNames() []string {
	var names []string
	for i := range int(f.nodes) {
		names = append(names, fmt.Sprintf("homelab-n%d", i))
	}
	return names
}

// prom2 answers the queries of version 2.
func (f *fake) prom2(query string, at float64, apps []string) ([]sample, bool) {
	one := func(v float64) []sample { return []sample{vec(at, map[string]string{}, v)} }
	none := []sample{}
	perNode := func(v float64) []sample {
		out := []sample{}
		if f.noUse {
			return out
		}
		for _, n := range f.nodeNames() {
			out = append(out, vec(at, map[string]string{"nodename": n}, v))
		}
		return out
	}
	switch {
	case strings.HasPrefix(query, "min by (app) (probe_success{"):
		out := []sample{}
		for _, a := range apps {
			if f.noProbe[a] {
				continue
			}
			v := 1.0
			if f.down[a] {
				v = 0
			}
			out = append(out, vec(at, map[string]string{"app": a}, v))
		}
		return out, true
	case strings.HasPrefix(query, `avg by (app) (avg_over_time(probe_success{job="blackbox-public"`):
		out := []sample{}
		for _, a := range apps {
			if f.noProbe[a] {
				continue
			}
			v := 0.999
			if f.down[a] {
				v = 0.9
			}
			out = append(out, vec(at, map[string]string{"app": a}, v))
		}
		return out, true
	case strings.HasPrefix(query, "avg(avg_over_time(probe_success{"):
		return one(0.75), true
	case strings.HasPrefix(query, "floor((min(probe_ssl_earliest_cert_expiry"):
		for _, k := range []string{"homelab", "lilalala", "nedsi"} {
			if strings.Contains(query, k) {
				if v, ok := f.certDays[k]; ok {
					return one(math.Floor(v)), true
				}
				return none, true
			}
		}
	case query == `count(argocd_app_info{sync_status="Synced"})`:
		return one(54), true
	case query == `count(argocd_app_info{health_status="Healthy"})`:
		return one(55), true
	case query == readyQuery:
		out := []sample{}
		for i, n := range f.nodeNames() {
			out = append(out, vec(at, map[string]string{"node": n}, float64(min(1, i))))
		}
		return out, true
	case strings.Contains(query, "node_uname_info"):
		switch {
		case strings.Contains(query, "errs_total"):
			return perNode(0.0123), true
		case strings.Contains(query, "pressure"):
			return perNode(0.04321), true
		}
		return perNode(0.61234), true
	case strings.Contains(query, "truenas_") || strings.Contains(query, "nas:pool"):
		if f.noNAS {
			return none, true
		}
		switch {
		case strings.Contains(query, "errors"):
			return one(0), true
		case strings.Contains(query, "up") || strings.Contains(query, "healthy"):
			return one(1), true
		case strings.Contains(query, "load1"):
			return one(0.25), true
		}
		return one(0.4787), true
	case strings.Contains(query, "envoy_"):
		if f.noGateway {
			return none, true
		}
		switch {
		case strings.HasPrefix(query, "histogram_quantile"):
			return one(40.9), true
		case strings.Contains(query, `envoy_response_code_class="5"`):
			return one(0.0059), true
		}
		return one(0.6333), true
	case strings.HasPrefix(query, "sum(increase(kube_pod_container_status_restarts_total"):
		return one(3.6), true
	case query == "count(kubelet_volume_stats_capacity_bytes)":
		return one(35), true
	case query == "sum(kubelet_volume_stats_used_bytes)":
		return one(4.1e11), true
	case query == "sum(kubelet_volume_stats_capacity_bytes)":
		return one(1.1e12), true
	case strings.HasPrefix(query, "max(kubelet_volume_stats_used_bytes"):
		return one(0.80825), true
	}
	return nil, false
}

type series struct {
	Metric map[string]string `json:"metric"`
	Values [][2]any          `json:"values"`
}

// promRangeReply answers the ALERTS range query from f.alerts.
func (f *fake) promRangeReply(query string, r promRange) []series {
	if query != alertExpr {
		panic("unexpected range query " + query)
	}
	out := []series{}
	for _, a := range f.alerts {
		s := series{Metric: a.labels}
		for t := r.start; !t.After(r.end); t = t.Add(r.step) {
			if !t.Before(a.from) && !t.After(a.to) {
				s.Values = append(s.Values, [2]any{float64(t.Unix()), "1"})
			}
		}
		if len(s.Values) > 0 {
			out = append(out, s)
		}
	}
	return out
}

func (f *fake) graphQLReply(w http.ResponseWriter, r *http.Request, reply func(int, any)) {
	f.graphql++
	var req struct {
		Variables struct {
			Q     string  `json:"q"`
			After *string `json:"after"`
		} `json:"variables"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		reply(http.StatusBadRequest, nil)
		return
	}
	first := 0
	if req.Variables.After != nil {
		first, _ = strconv.Atoi(*req.Variables.After)
	}
	last := min(first+100, len(f.prs))
	var nodes []any
	for _, p := range f.prs[first:last] {
		var labels, files, contexts []any
		for _, l := range p.Labels {
			labels = append(labels, map[string]any{"name": l})
		}
		for _, path := range p.Files {
			files = append(files, map[string]any{"path": path})
		}
		for _, t := range p.Synced {
			contexts = append(contexts, map[string]any{"context": "argocd/app", "state": "SUCCESS", "createdAt": t.UTC().Format(time.RFC3339)})
		}
		contexts = append(contexts, map[string]any{"context": "ci", "state": "SUCCESS", "createdAt": p.MergedAt.UTC().Format(time.RFC3339)})
		nodes = append(nodes, map[string]any{
			"title": p.Title, "createdAt": p.CreatedAt.UTC().Format(time.RFC3339), "mergedAt": p.MergedAt.UTC().Format(time.RFC3339),
			"labels":      map[string]any{"nodes": labels},
			"files":       map[string]any{"totalCount": len(p.Files) + p.MoreFiles, "nodes": files},
			"mergeCommit": map[string]any{"oid": p.OID, "message": p.Message, "status": map[string]any{"contexts": contexts}},
		})
	}
	reply(http.StatusOK, map[string]any{"data": map[string]any{"search": map[string]any{
		"issueCount": len(f.prs),
		"pageInfo":   map[string]any{"hasNextPage": last < len(f.prs), "endCursor": strconv.Itoa(last)},
		"nodes":      nodes,
	}}})
}

func (f *fake) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	reply := func(code int, body any) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		_ = json.NewEncoder(w).Encode(body)
	}
	if r.URL.Path == "/api/v1/query_range" {
		if err := r.ParseForm(); err != nil {
			reply(http.StatusBadRequest, nil)
			return
		}
		start, _ := strconv.ParseFloat(r.Form.Get("start"), 64)
		end, _ := strconv.ParseFloat(r.Form.Get("end"), 64)
		step, _ := strconv.ParseFloat(r.Form.Get("step"), 64)
		pr := promRange{time.Unix(int64(start), 0), time.Unix(int64(end), 0), time.Duration(step) * time.Second}
		f.ranges = append(f.ranges, pr)
		if f.promFail {
			reply(http.StatusServiceUnavailable, map[string]string{"status": "error", "errorType": "unavailable", "error": "boom"})
			return
		}
		reply(http.StatusOK, map[string]any{"status": "success",
			"data": map[string]any{"resultType": "matrix", "result": f.promRangeReply(r.Form.Get("query"), pr)}})
		return
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
	case r.URL.Path == "/graphql" && r.Method == http.MethodPost:
		f.graphQLReply(w, r, reply)
	case r.URL.Path == "/search/issues":
		n := 300
		if strings.Contains(r.URL.Query().Get("q"), "author:app/renovate") {
			n = 120
		}
		reply(http.StatusOK, map[string]any{"total_count": n, "incomplete_results": false, "items": []any{}})
	case strings.HasSuffix(r.URL.Path, "/actions/workflows/ci.yaml/runs") && r.URL.Query().Get("status") == "completed":
		reply(http.StatusOK, map[string]any{"total_count": len(f.runs), "workflow_runs": f.runs})
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
	cl := s.Cluster
	cl.NodeUse, cl.NAS, cl.Gateway, cl.Volumes = nil, snapshot.NAS{}, snapshot.Gateway{}, snapshot.Volumes{}
	if diff := cmp.Diff(snapshot.Cluster{AsOf: s.GeneratedAt, Nodes: 4, Apps: 55, TalosVersion: "v1.14.6",
		KubernetesVersion: "v1.37.2", Synced: 54, Healthy: 55, Restarts24h: 3}, cl); diff != "" {
		t.Errorf("cluster mismatch (-want +got):\n%s", diff)
	}
	if got, want := [4]int{s.Project.PRsMerged30d, s.Project.RenovateShare30d, s.Project.CIMedianSeconds30d,
		s.Project.Deploys30d}, [4]int{300, 40, 700, 300}; got != want {
		t.Errorf("project prs, renovate, ci median, deploys = %v, want %v", got, want)
	}
	if s.Project.AsOf != s.GeneratedAt {
		t.Errorf("project.as_of = %s, want %s", s.Project.AsOf, s.GeneratedAt)
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
	// The availability, certificates and cluster blocks each failed once.
	if got := testutil.ToFloat64(e.m.Errors.WithLabelValues("prometheus")); got != 3 {
		t.Errorf("collect_errors_total{prometheus} = %v, want 3", got)
	}
	if got := testutil.ToFloat64(e.m.Runs.WithLabelValues("cluster", "failure")); got != 1 {
		t.Errorf("collect_runs_total{cluster,failure} = %v, want 1", got)
	}
}

func TestNoPushUntilEveryBlock(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	e.fake.promEmpty = "count(kube_node_info)"
	if e.c.Cycle(t.Context()) {
		t.Error("Cycle() without a cluster block = true, want false")
	}
	if len(e.pods[0].bodies) != 0 {
		t.Errorf("got %d pushes, want none", len(e.pods[0].bodies))
	}
	// The cluster block is retried at the next cycle.
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
	s, _, err := e.c.Collect(t.Context(), e.now)
	if err != nil {
		t.Fatal(err)
	}
	if got := s.Availability.Apps[7].ErrorBudgetRemaining30d; got == nil || *got != -100 {
		t.Errorf("landing budget = %v, want -100", got)
	}
	for i, v := range s.Availability.Apps[1].AvailabilityDaily {
		if v != nil {
			t.Errorf("mealie availability_daily[%d] = %v, want null", i, *v)
		}
	}
}

func TestVersionMidUpgrade(t *testing.T) {
	e := newEnv(t, zurich(2026, 11, 20, 17, 0), http.StatusNoContent)
	e.fake.osImages = []string{"Talos (v1.14.10)", "Talos (v1.14.9)"}
	e.fake.kubelets = []string{"v1.38.0", "v1.37.2"}
	s, _, err := e.c.Collect(t.Context(), e.now)
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
	if _, _, err := e.c.Collect(t.Context(), e.now); err == nil {
		t.Error("Collect() with no version in os_image = nil error, want an error")
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

// TestProjectWindow pins the definition of prs_merged_30d: pull requests
// merged into main in the 30 Zurich days ending at the cycle, so the window
// is an hour longer across the end of summer time.
func TestProjectWindow(t *testing.T) {
	tests := []struct {
		now  time.Time
		want string
	}{
		{zurich(2026, 12, 20, 17, 0), "merged:2026-11-20T16:00:00Z..2026-12-20T15:59:59Z"},
		{zurich(2026, 11, 20, 17, 0), "merged:2026-10-21T15:00:00Z..2026-11-20T15:59:59Z"},
	}
	for _, tc := range tests {
		e := newEnv(t, tc.now, http.StatusNoContent)
		e.c.Cycle(t.Context())
		var got []string
		for _, call := range e.fake.github {
			u, err := url.Parse(call)
			if err != nil {
				t.Fatal(err)
			}
			if u.Path == "/search/issues" {
				got = append(got, u.Query().Get("q"))
			}
		}
		prefix := "repo:ned-si/homelab is:pr is:merged base:main " + tc.want
		want := []string{prefix, prefix + " author:app/renovate"}
		if diff := cmp.Diff(want, got); diff != "" {
			t.Errorf("at %v search queries mismatch (-want +got):\n%s", tc.now, diff)
		}
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
