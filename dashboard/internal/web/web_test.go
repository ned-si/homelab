package web

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"encoding/xml"
	"errors"
	"flag"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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
		{"app outside the allow-list", func(t *testing.T, h *harness) int {
			doc := fixture(t)
			app := doc["daily"].(map[string]any)["apps"].([]any)[0].(map[string]any)
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
		{http.MethodPost, "/homelab/"},
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
	rec := h.get(t, http.MethodGet, "/homelab/snapshot.json")
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
	// covers 2026-11-19 ends at 2026-11-20 00:00.
	if got, want := h.s.DailyAge(), (17*time.Hour + 30*time.Second).Seconds(); got != want {
		t.Errorf("DailyAge() = %v, want %v", got, want)
	}
}

func TestHeadersOnEveryResponse(t *testing.T) {
	h := newHarness(t)
	page := h.get(t, http.MethodGet, "/homelab/")
	tests := []struct {
		name   string
		method string
		path   string
		header []string
		want   int
	}{
		{"page", http.MethodGet, "/homelab/", nil, http.StatusOK},
		{"head", http.MethodHead, "/homelab/", nil, http.StatusOK},
		{"redirect", http.MethodGet, "/homelab", nil, http.StatusMovedPermanently},
		{"not modified", http.MethodGet, "/homelab/", []string{"If-None-Match", page.Header().Get("ETag")}, http.StatusNotModified},
		{"not found", http.MethodGet, "/homelab/nope", nil, http.StatusNotFound},
		{"not found outside", http.MethodGet, "/", nil, http.StatusNotFound},
		{"no snapshot yet", http.MethodGet, "/homelab/snapshot.json", nil, http.StatusNotFound},
		{"post", http.MethodPost, "/homelab/", nil, http.StatusMethodNotAllowed},
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
	if got := h.get(t, http.MethodPost, "/homelab/").Header().Get("Allow"); got != "GET, HEAD" {
		t.Errorf("Allow = %q, want %q", got, "GET, HEAD")
	}
	if got := h.get(t, http.MethodGet, "/homelab").Header().Get("Location"); got != "/homelab/" {
		t.Errorf("Location = %q, want a relative /homelab/", got)
	}
	if got := h.get(t, http.MethodHead, "/homelab/").Body.Len(); got != 0 {
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
		"/homelab/":              "no-cache",
		"/homelab/snapshot.json": "no-cache",
		h.s.cssPath:              "public, max-age=31536000, immutable",
	} {
		rec := h.get(t, http.MethodGet, path)
		if rec.Code != http.StatusOK {
			t.Errorf("GET %s = %d, want 200", path, rec.Code)
		}
		if got := rec.Header().Get("Cache-Control"); got != want {
			t.Errorf("GET %s Cache-Control = %q, want %q", path, got, want)
		}
	}
	if !regexp.MustCompile(`^/homelab/assets/dashboard\.[0-9a-f]{8}\.css$`).MatchString(h.s.cssPath) {
		t.Errorf("stylesheet path %q has no content hash", h.s.cssPath)
	}
}

func TestAccessLog(t *testing.T) {
	h := newHarness(t)
	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/homelab/?secret=1", nil)
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
	for _, p := range []string{"/wp-admin/", "/.env", "/homelab/../../etc/passwd"} {
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

func TestSparklineMarkup(t *testing.T) {
	v := func(x float64) *float64 { return &x }
	inputs := [][]*float64{
		make([]*float64, snapshot.Days),
		{v(99.9), nil, v(100), v(85), nil, v(12.3456)},
		{nil, v(100)},
	}
	numeric := regexp.MustCompile(`^-?[0-9]+(\.[0-9])?( -?[0-9]+(\.[0-9])?)*$`)
	points := regexp.MustCompile(`^([0-9]+\.[0-9],[0-9]+\.[0-9] ?)+$`)
	allowed := map[string]bool{"svg": true, "line": true, "polyline": true, "circle": true}
	for _, in := range inputs {
		dec := xml.NewDecoder(strings.NewReader(string(sparkline(in))))
		for {
			tok, err := dec.Token()
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				t.Fatalf("sparkline is not well-formed: %v", err)
			}
			switch el := tok.(type) {
			case xml.StartElement:
				if !allowed[el.Name.Local] {
					t.Errorf("element <%s> in a sparkline", el.Name.Local)
				}
				for _, a := range el.Attr {
					switch a.Name.Local {
					case "class":
						if a.Value != "spark" && a.Value != "target" {
							t.Errorf("class %q", a.Value)
						}
					case "role":
						if a.Value != "img" {
							t.Errorf("role %q", a.Value)
						}
					case "aria-label":
						if !regexp.MustCompile(`^(No daily values yet|Daily availability, lowest [0-9]+\.[0-9]%)$`).MatchString(a.Value) {
							t.Errorf("aria-label %q", a.Value)
						}
					case "points":
						if !points.MatchString(a.Value) {
							t.Errorf("points %q", a.Value)
						}
					default:
						if !numeric.MatchString(a.Value) {
							t.Errorf("%s=%q is not numeric", a.Name.Local, a.Value)
						}
					}
				}
			case xml.CharData:
				if strings.TrimSpace(string(el)) != "" {
					t.Errorf("text %q in a sparkline", el)
				}
			}
		}
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

func fullDaily(t *testing.T) map[string]any {
	t.Helper()
	doc := fixture(t)
	for _, a := range doc["daily"].(map[string]any)["apps"].([]any) {
		days := a.(map[string]any)["availability_daily"].([]any)
		for i := range days {
			if days[i] == nil {
				days[i] = 100.0
			}
		}
	}
	return doc
}

func TestGoldenPages(t *testing.T) {
	tests := []struct {
		name string
		doc  func(t *testing.T) map[string]any
		now  time.Time
	}{
		{"full", fullDaily, fixtureNow},
		{"since", fixture, fixtureNow},
		{"stale-live", fixture, fixtureNow.Add(2 * time.Hour)},
		{"stale-daily", fixture, fixtureNow.Add(3 * 24 * time.Hour)},
		{"empty", nil, fixtureNow},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t)
			if tc.doc != nil {
				if code := h.pushDoc(t, tc.doc(t)); code != http.StatusNoContent {
					t.Fatalf("push = %d", code)
				}
			}
			h.now = tc.now
			rec := h.get(t, http.MethodGet, "/homelab/")
			if rec.Code != http.StatusOK {
				t.Fatalf("GET /homelab/ = %d", rec.Code)
			}
			checkMarkup(t, rec.Body.String())
			golden(t, filepath.Join("testdata", tc.name+".golden.html"), rec.Body.Bytes())
		})
	}
	h := newHarness(t)
	rec := h.get(t, http.MethodGet, "/homelab/nope")
	checkMarkup(t, rec.Body.String())
	golden(t, "testdata/notfound.golden.html", rec.Body.Bytes())
}

func checkMarkup(t *testing.T, body string) {
	t.Helper()
	for _, bad := range []string{"<script", "style=", "<style", "<form", "<iframe", " on"} {
		if bad == " on" {
			if regexp.MustCompile(`<[^>]+\son[a-z]+=`).MatchString(body) {
				t.Error("an on* attribute in the page")
			}
			continue
		}
		if strings.Contains(body, bad) {
			t.Errorf("the page contains %q", bad)
		}
	}
}

func TestPageTexts(t *testing.T) {
	h := newHarness(t)
	if code := h.pushDoc(t, fixture(t)); code != http.StatusNoContent {
		t.Fatalf("push = %d", code)
	}
	for _, tc := range []struct {
		now  time.Time
		want []string
		not  []string
	}{
		{fixtureNow, []string{"99.5%", "since 16 November", "-62%", "5 min 05 s", "Opened by Renovate</dt><dd>50%"},
			[]string{"Live figures from", "daily update is failing", "No figures yet"}},
		{fixtureNow.Add(6 * time.Minute), []string{"Live figures from <time datetime=\"2026-11-20T17:00:00&#43;01:00\">20 November 2026, 17:00</time>"}, nil},
		{fixtureNow.Add(3 * 24 * time.Hour), []string{"Availability figures are from <time datetime=\"2026-11-19\">19 November 2026</time>: the daily update is failing."}, nil},
	} {
		h.now = tc.now
		body := h.get(t, http.MethodGet, "/homelab/").Body.String()
		for _, w := range tc.want {
			if !strings.Contains(body, w) {
				t.Errorf("at %v the page lacks %q", tc.now, w)
			}
		}
		for _, n := range tc.not {
			if strings.Contains(body, n) {
				t.Errorf("at %v the page contains %q", tc.now, n)
			}
		}
	}
}

func TestDuration(t *testing.T) {
	for s, want := range map[int]string{59: "59 s", 60: "1 min 00 s", 305: "5 min 05 s"} {
		if got := duration(s); got != want {
			t.Errorf("duration(%d) = %q, want %q", s, got, want)
		}
	}
}
