package web

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"flag"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

var update = flag.Bool("update", false, "rewrite the golden files in testdata/")

// The fixture's generated_at is 17:00:00; the clock is 30 s later.
var fixtureNow = time.Date(2026, 11, 20, 17, 0, 30, 0, snapshot.Zurich)

type harness struct {
	s    *Server
	key  ed25519.PrivateKey
	now  time.Time
	logs bytes.Buffer
	reg  *prometheus.Registry
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	pub, key, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	h := &harness{key: key, now: fixtureNow, reg: prometheus.NewRegistry()}
	h.s, err = New(Options{
		Logger:   slog.New(slog.NewJSONHandler(&h.logs, nil)),
		Registry: h.reg,
		Now:      func() time.Time { return h.now },
		Keys:     []ed25519.PublicKey{pub},
	})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func fixture(t *testing.T) map[string]any {
	t.Helper()
	b, err := os.ReadFile("testdata/snapshot.json")
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	return doc
}

func encode(t *testing.T, doc map[string]any) []byte {
	t.Helper()
	b, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func (h *harness) push(t *testing.T, body []byte, sig string, mutate ...func(*http.Request)) int {
	t.Helper()
	req := httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/v1/snapshot", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(snapshot.SignatureHeader, sig)
	for _, m := range mutate {
		m(req)
	}
	rec := httptest.NewRecorder()
	h.s.Push().ServeHTTP(rec, req)
	return rec.Code
}

func (h *harness) pushDoc(t *testing.T, doc map[string]any) int {
	t.Helper()
	body := encode(t, doc)
	return h.push(t, body, snapshot.Sign(h.key, body))
}

func (h *harness) get(t *testing.T, method, path string, header ...string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequestWithContext(t.Context(), method, path, nil)
	for i := 0; i+1 < len(header); i += 2 {
		req.Header.Set(header[i], header[i+1])
	}
	rec := httptest.NewRecorder()
	h.s.Public().ServeHTTP(rec, req)
	return rec
}

func TestPushChecks(t *testing.T) {
	_, other, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name   string
		send   func(t *testing.T, h *harness) int
		want   int
		reason string
	}{
		{"valid", func(t *testing.T, h *harness) int { return h.pushDoc(t, fixture(t)) }, http.StatusNoContent, ""},
		{"too large", func(t *testing.T, h *harness) int {
			body := make([]byte, snapshot.MaxSize+1)
			return h.push(t, body, snapshot.Sign(h.key, body))
		}, http.StatusRequestEntityTooLarge, "size"},
		{"wrong content type", func(t *testing.T, h *harness) int {
			body := encode(t, fixture(t))
			return h.push(t, body, snapshot.Sign(h.key, body), func(r *http.Request) { r.Header.Set("Content-Type", "text/plain") })
		}, http.StatusBadRequest, "content_type"},
		{"unsigned", func(t *testing.T, h *harness) int { return h.push(t, encode(t, fixture(t)), "") }, http.StatusUnauthorized, "signature"},
		{"signed by another key", func(t *testing.T, h *harness) int {
			body := encode(t, fixture(t))
			return h.push(t, body, snapshot.Sign(other, body))
		}, http.StatusUnauthorized, "signature"},
		{"too old", func(t *testing.T, h *harness) int {
			h.now = fixtureNow.Add(6 * time.Minute)
			return h.pushDoc(t, fixture(t))
		}, http.StatusConflict, "replay"},
		{"in the future", func(t *testing.T, h *harness) int {
			h.now = fixtureNow.Add(-2 * time.Minute)
			return h.pushDoc(t, fixture(t))
		}, http.StatusConflict, "replay"},
		{"replayed", func(t *testing.T, h *harness) int {
			if code := h.pushDoc(t, fixture(t)); code != http.StatusNoContent {
				t.Fatalf("first push = %d", code)
			}
			return h.pushDoc(t, fixture(t))
		}, http.StatusConflict, "replay"},
		{"extra key", func(t *testing.T, h *harness) int {
			doc := fixture(t)
			doc["household"] = map[string]any{"consumption_kwh": 12}
			return h.pushDoc(t, doc)
		}, http.StatusBadRequest, "schema"},
		{"version 2", func(t *testing.T, h *harness) int {
			doc := fixture(t)
			doc["schema_version"] = 2
			doc["daily"] = map[string]any{"covers": "2026-11-19"}
			return h.pushDoc(t, doc)
		}, http.StatusBadRequest, "schema"},
		{"certificate outside the allow-list", func(t *testing.T, h *harness) int {
			doc := fixture(t)
			c := doc["certificates"].(map[string]any)["certs"].([]any)[0].(map[string]any)
			c["id"], c["name"] = "example", "example.org"
			return h.pushDoc(t, doc)
		}, http.StatusBadRequest, "allowlist"},
		{"app outside the allow-list", func(t *testing.T, h *harness) int {
			doc := fixture(t)
			app := doc["availability"].(map[string]any)["apps"].([]any)[0].(map[string]any)
			app["id"], app["name"] = "sonarr", "Sonarr"
			return h.pushDoc(t, doc)
		}, http.StatusBadRequest, "allowlist"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t)
			if got := tc.send(t, h); got != tc.want {
				t.Errorf("push = %d, want %d", got, tc.want)
			}
			if tc.reason != "" {
				if got := testutil.ToFloat64(h.s.metrics.PushRejected.WithLabelValues(tc.reason)); got != 1 {
					t.Errorf("push_rejected_total{reason=%q} = %v, want 1", tc.reason, got)
				}
				if strings.Contains(h.logs.String(), "schema_version") {
					t.Error("a refused push logged its body")
				}
			}
		})
	}
}

func TestPushReceiverRoutes(t *testing.T) {
	h := newHarness(t)
	for _, tc := range []struct{ method, path string }{
		{http.MethodGet, "/v1/snapshot"},
		{http.MethodPost, "/v1/other"},
		{http.MethodPost, "/"},
	} {
		req := httptest.NewRequestWithContext(t.Context(), tc.method, tc.path, nil)
		rec := httptest.NewRecorder()
		h.s.Push().ServeHTTP(rec, req)
		if rec.Code != http.StatusNotFound {
			t.Errorf("%s %s on the push port = %d, want 404", tc.method, tc.path, rec.Code)
		}
	}
}

func TestPushNewerReplacesAndKeyRotation(t *testing.T) {
	h := newHarness(t)
	if code := h.pushDoc(t, fixture(t)); code != http.StatusNoContent {
		t.Fatalf("first push = %d", code)
	}
	// Rotation: the new key is added next to the old one.
	newPub, newKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	h.s.SetKeys([]ed25519.PublicKey{h.key.Public().(ed25519.PublicKey), newPub})
	h.now = fixtureNow.Add(time.Minute)
	doc := fixture(t)
	doc["generated_at"] = "2026-11-20T17:01:00+01:00"
	doc["cluster"].(map[string]any)["as_of"] = "2026-11-20T17:01:00+01:00"
	body := encode(t, doc)
	if code := h.push(t, body, snapshot.Sign(newKey, body)); code != http.StatusNoContent {
		t.Fatalf("push signed by the new key = %d, want 204", code)
	}
	rec := h.get(t, http.MethodGet, "/snapshot.json")
	if !bytes.Equal(rec.Body.Bytes(), body) {
		t.Error("snapshot.json is not the newer snapshot")
	}
}

func TestReady(t *testing.T) {
	h := newHarness(t)
	if h.s.Ready() {
		t.Error("Ready() at start = true, want false")
	}
	h.now = fixtureNow.Add(119 * time.Second)
	if h.s.Ready() {
		t.Error("Ready() after 119 s = true, want false")
	}
	h.now = fixtureNow.Add(120 * time.Second)
	if !h.s.Ready() {
		t.Error("Ready() after 120 s = false, want true")
	}
	h = newHarness(t)
	if code := h.pushDoc(t, fixture(t)); code != http.StatusNoContent {
		t.Fatalf("push = %d", code)
	}
	if !h.s.Ready() {
		t.Error("Ready() with a snapshot = false, want true")
	}
}

func TestAges(t *testing.T) {
	h := newHarness(t)
	h.now = fixtureNow.Add(10 * time.Second)
	if got := h.s.SnapshotAge(); got != 10 {
		t.Errorf("SnapshotAge() without a snapshot = %v, want 10 (since start)", got)
	}
	h.now = fixtureNow
	if code := h.pushDoc(t, fixture(t)); code != http.StatusNoContent {
		t.Fatalf("push = %d", code)
	}
	if got := h.s.SnapshotAge(); got != 30 {
		t.Errorf("SnapshotAge() = %v, want 30", got)
	}
	for block, want := range map[string]float64{"availability": 30, "certificates": 30, "cluster": 30, "project": 510, "security": 30} {
		if got := h.s.BlockAge(block); got != want {
			t.Errorf("BlockAge(%q) = %v, want %v", block, got, want)
		}
	}
}

func TestBlockAgeWithoutSnapshot(t *testing.T) {
	h := newHarness(t)
	h.now = fixtureNow.Add(10 * time.Second)
	if got := h.s.BlockAge("availability"); got != 10 {
		t.Errorf("BlockAge() without a snapshot = %v, want 10 (since start)", got)
	}
}

func TestHeadersOnEveryResponse(t *testing.T) {
	h := newHarness(t)
	page := h.get(t, http.MethodGet, "/")
	tests := []struct {
		name   string
		method string
		path   string
		header []string
		want   int
	}{
		{"page", http.MethodGet, "/", nil, http.StatusOK},
		{"head", http.MethodHead, "/", nil, http.StatusOK},
		{"not modified", http.MethodGet, "/", []string{"If-None-Match", page.Header().Get("ETag")}, http.StatusNotModified},
		{"not found", http.MethodGet, "/nope", nil, http.StatusNotFound},
		{"old path", http.MethodGet, "/homelab/", nil, http.StatusNotFound},
		{"old path without slash", http.MethodGet, "/homelab", nil, http.StatusNotFound},
		{"no snapshot yet", http.MethodGet, "/snapshot.json", nil, http.StatusNotFound},
		{"post", http.MethodPost, "/", nil, http.StatusMethodNotAllowed},
		{"delete elsewhere", http.MethodDelete, "/nope", nil, http.StatusMethodNotAllowed},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rec := h.get(t, tc.method, tc.path, tc.header...)
			if rec.Code != tc.want {
				t.Fatalf("%s %s = %d, want %d", tc.method, tc.path, rec.Code, tc.want)
			}
			for _, sh := range headers {
				if got := rec.Header().Get(sh[0]); got != sh[1] {
					t.Errorf("%s = %q, want %q", sh[0], got, sh[1])
				}
			}
		})
	}
	if got := h.get(t, http.MethodPost, "/").Header().Get("Allow"); got != "GET, HEAD" {
		t.Errorf("Allow = %q, want %q", got, "GET, HEAD")
	}
	if got := h.get(t, http.MethodGet, "/homelab").Header().Get("Location"); got != "" {
		t.Errorf("Location = %q, want no redirect", got)
	}
	if got := h.get(t, http.MethodHead, "/").Body.Len(); got != 0 {
		t.Errorf("HEAD body = %d bytes, want 0", got)
	}

	// headers.golden: the response headers of the page, for the comparison
	// with the HTTPRoute's (tests/test_security_controls.py, task 4).
	var b strings.Builder
	names := slices.Sorted(func(yield func(string) bool) {
		for k := range page.Header() {
			if !yield(k) {
				return
			}
		}
	})
	for _, k := range names {
		if k == "Etag" || k == "Content-Length" {
			continue
		}
		b.WriteString(k + ": " + page.Header().Get(k) + "\n")
	}
	golden(t, "testdata/headers.golden", []byte(b.String()))
}

func TestCacheControl(t *testing.T) {
	h := newHarness(t)
	if code := h.pushDoc(t, fixture(t)); code != http.StatusNoContent {
		t.Fatalf("push = %d", code)
	}
	for path, want := range map[string]string{
		"/":              "no-cache",
		"/snapshot.json": "no-cache",
		h.s.cssPath:      "public, max-age=31536000, immutable",
	} {
		rec := h.get(t, http.MethodGet, path)
		if rec.Code != http.StatusOK {
			t.Errorf("GET %s = %d, want 200", path, rec.Code)
		}
		if got := rec.Header().Get("Cache-Control"); got != want {
			t.Errorf("GET %s Cache-Control = %q, want %q", path, got, want)
		}
	}
	if !regexp.MustCompile(`^/assets/dashboard\.[0-9a-f]{8}\.css$`).MatchString(h.s.cssPath) {
		t.Errorf("stylesheet path %q has no content hash", h.s.cssPath)
	}
}

func TestAccessLog(t *testing.T) {
	h := newHarness(t)
	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/?secret=1", nil)
	req.RemoteAddr = "203.0.113.7:4242"
	req.Header.Set("User-Agent", "curious-agent/1.0")
	req.Header.Set("Referer", "https://example.org/")
	h.s.Public().ServeHTTP(httptest.NewRecorder(), req)
	line := h.logs.String()
	for _, leak := range []string{"203.0.113.7", "curious-agent", "example.org", "secret"} {
		if strings.Contains(line, leak) {
			t.Errorf("access log %q contains %q", line, leak)
		}
	}
	var entry map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &entry); err != nil {
		t.Fatalf("access log is not one JSON line: %v", err)
	}
	var keys []string
	for k := range entry {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	want := []string{"bytes", "duration_ms", "level", "method", "msg", "path", "status", "time"}
	if diff := cmp.Diff(want, keys); diff != "" {
		t.Errorf("access log keys mismatch (-want +got):\n%s", diff)
	}
}

func TestNoLabelFromPath(t *testing.T) {
	h := newHarness(t)
	for _, p := range []string{"/wp-admin/", "/.env", "/../../etc/passwd"} {
		h.get(t, http.MethodGet, p)
		h.get(t, "PROPFIND", p)
	}
	mfs, err := h.reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, mf := range mfs {
		for _, m := range mf.GetMetric() {
			for _, l := range m.GetLabel() {
				if strings.ContainsAny(l.GetValue(), "/.") {
					t.Errorf("%s{%s=%q}: a label value from the request", mf.GetName(), l.GetName(), l.GetValue())
				}
			}
		}
	}
	if got := testutil.ToFloat64(h.s.metrics.Requests.WithLabelValues("405", "other")); got != 3 {
		t.Errorf("http_requests_total{code=405,method=other} = %v, want 3", got)
	}
}

func golden(t *testing.T, path string, got []byte) {
	t.Helper()
	if *update {
		if err := os.WriteFile(path, got, 0o600); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path) //nolint:gosec // G304: a golden file under testdata/.
	if err != nil {
		t.Fatalf("%v (run go test -update)", err)
	}
	if diff := cmp.Diff(string(want), string(got)); diff != "" {
		t.Errorf("%s mismatch (-want +got):\n%s", path, diff)
	}
}
