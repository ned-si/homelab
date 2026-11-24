package metrics

import (
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"
	dto "github.com/prometheus/client_model/go"
)

func labelNames(mf *dto.MetricFamily) []string {
	var names []string
	for _, m := range mf.GetMetric() {
		for _, l := range m.GetLabel() {
			if !slices.Contains(names, l.GetName()) {
				names = append(names, l.GetName())
			}
		}
	}
	slices.Sort(names)
	return names
}

func families(t *testing.T, gather func() ([]*dto.MetricFamily, error)) map[string][]string {
	t.Helper()
	mfs, err := gather()
	if err != nil {
		t.Fatal(err)
	}
	got := map[string][]string{}
	for _, mf := range mfs {
		if name := mf.GetName(); strings.HasPrefix(name, namespace+"_") {
			got[name] = labelNames(mf)
		}
	}
	return got
}

func TestCollectorMetrics(t *testing.T) {
	reg := NewRegistry("collector", "abc123")
	NewCollector(reg)
	want := map[string][]string{
		"homelab_dashboard_build_info":                 {"goversion", "role", "version"},
		"homelab_dashboard_collect_runs_total":         {"block", "result"},
		"homelab_dashboard_collect_errors_total":       {"source"},
		"homelab_dashboard_collect_duration_seconds":   {"block"},
		"homelab_dashboard_push_total":                 {"result"},
		"homelab_dashboard_github_ratelimit_remaining": nil,
		"homelab_dashboard_github_token_valid":         nil,
	}
	if diff := cmp.Diff(want, families(t, reg.Gather)); diff != "" {
		t.Errorf("collector metrics mismatch (-want +got):\n%s", diff)
	}
}

func TestWebMetrics(t *testing.T) {
	reg := NewRegistry("web", "abc123")
	m := NewWeb(reg, func() float64 { return 1 }, func() float64 { return 2 }, func(string) float64 { return 3 })
	m.Requests.WithLabelValues("200", Method("GET")).Inc()
	m.Duration.Observe(0.001)
	want := map[string][]string{
		"homelab_dashboard_build_info":                    {"goversion", "role", "version"},
		"homelab_dashboard_push_rejected_total":           {"reason"},
		"homelab_dashboard_http_requests_total":           {"code", "method"},
		"homelab_dashboard_http_request_duration_seconds": nil,
		"homelab_dashboard_snapshot_age_seconds":          nil,
		"homelab_dashboard_daily_age_seconds":             nil,
		"homelab_dashboard_block_age_seconds":             {"block"},
	}
	if diff := cmp.Diff(want, families(t, reg.Gather)); diff != "" {
		t.Errorf("web metrics mismatch (-want +got):\n%s", diff)
	}
}

func TestMethod(t *testing.T) {
	for in, want := range map[string]string{"GET": "GET", "HEAD": "HEAD", "POST": "other", "/etc/passwd": "other"} {
		if got := Method(in); got != want {
			t.Errorf("Method(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestHandler(t *testing.T) {
	ready := false
	h := Handler(NewRegistry("web", "abc123"), func() bool { return ready })
	tests := []struct {
		path  string
		ready bool
		want  int
	}{
		{"/healthz", false, http.StatusOK},
		{"/readyz", false, http.StatusServiceUnavailable},
		{"/readyz", true, http.StatusOK},
		{"/metrics", false, http.StatusOK},
		{"/other", false, http.StatusNotFound},
	}
	for _, tc := range tests {
		ready = tc.ready
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, tc.path, nil))
		if rec.Code != tc.want {
			t.Errorf("GET %s (ready %v) = %d, want %d", tc.path, tc.ready, rec.Code, tc.want)
		}
	}
}
