package snapshot

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
)

func readValid(t testing.TB) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/valid.json")
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// mutate decodes the valid fixture, applies f and encodes it again.
func mutate(t *testing.T, f func(doc map[string]any)) []byte {
	t.Helper()
	var doc map[string]any
	if err := json.Unmarshal(readValid(t), &doc); err != nil {
		t.Fatal(err)
	}
	f(doc)
	b, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func obj(doc map[string]any, path ...string) map[string]any {
	m := doc
	for _, p := range path {
		m = m[p].(map[string]any)
	}
	return m
}

func apps(doc map[string]any) []any {
	return obj(doc, "daily")["apps"].([]any)
}

func TestValidateAcceptsFixture(t *testing.T) {
	s, err := Validate(readValid(t))
	if err != nil {
		t.Fatalf("Validate(valid.json) = %v, want nil", err)
	}
	if got, want := s.Daily.Covers, "2026-11-19"; got != want {
		t.Errorf("Daily.Covers = %q, want %q", got, want)
	}
	if got := s.Daily.Apps[6].AvailabilityDaily[0]; got != nil {
		t.Errorf("landing availability_daily[0] = %v, want nil", *got)
	}
}

func TestValidateRefuses(t *testing.T) {
	tests := []struct {
		name     string
		edit     func(doc map[string]any)
		notShown bool
	}{
		{"missing key", func(d map[string]any) { delete(d, "project") }, false},
		{"extra key at the top", func(d map[string]any) { d["extra"] = 1 }, false},
		{"extra key in daily", func(d map[string]any) { obj(d, "daily")["extra"] = 1 }, false},
		{"extra key in an app", func(d map[string]any) { apps(d)[0].(map[string]any)["extra"] = 1 }, false},
		{"extra key in cluster", func(d map[string]any) { obj(d, "cluster")["consumption"] = 1 }, false},
		{"extra key in project", func(d map[string]any) { obj(d, "project")["extra"] = 1 }, false},
		{"wrong schema version", func(d map[string]any) { d["schema_version"] = 2 }, false},
		{"availability above 100", func(d map[string]any) { apps(d)[0].(map[string]any)["availability_30d"] = 100.1 }, false},
		{"budget below -100", func(d map[string]any) { apps(d)[0].(map[string]any)["error_budget_remaining_30d"] = -101 }, false},
		{"29 daily values", func(d map[string]any) {
			a := apps(d)[0].(map[string]any)
			a["availability_daily"] = a["availability_daily"].([]any)[1:]
		}, false},
		{"too many nodes", func(d map[string]any) { obj(d, "cluster")["nodes"] = 11 }, false},
		{"bad version string", func(d map[string]any) { obj(d, "cluster")["talos_version"] = "1.14.6" }, false},
		{"bad timestamp", func(d map[string]any) { d["generated_at"] = "2026-11-20 17:00" }, false},
		{"app outside the allow-list", func(d map[string]any) {
			a := apps(d)[0].(map[string]any)
			a["id"], a["name"] = "grafana", "Grafana"
		}, true},
		{"hidden app", func(d map[string]any) {
			a := apps(d)[0].(map[string]any)
			a["id"], a["name"] = "sonarr", "Sonarr"
		}, true},
		{"apps out of order", func(d map[string]any) {
			as := apps(d)
			as[0], as[1] = as[1], as[0]
		}, true},
		{"one app missing", func(d map[string]any) { obj(d, "daily")["apps"] = apps(d)[1:] }, true},
		{"cluster as_of after generated_at", func(d map[string]any) {
			obj(d, "cluster")["as_of"] = "2026-11-20T17:00:01+01:00"
		}, false},
		{"project as_of after generated_at", func(d map[string]any) {
			obj(d, "project")["as_of"] = "2026-11-20T18:00:00+01:00"
		}, false},
		{"computed_at after generated_at", func(d map[string]any) {
			obj(d, "daily")["computed_at"] = "2026-11-20T17:30:00+01:00"
		}, false},
		{"covers on the day it was computed", func(d map[string]any) { obj(d, "daily")["covers"] = "2026-11-20" }, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Validate(mutate(t, tc.edit))
			if err == nil {
				t.Fatalf("Validate() = nil, want an error")
			}
			if got := errors.Is(err, ErrNotShown); got != tc.notShown {
				t.Errorf("errors.Is(%v, ErrNotShown) = %v, want %v", err, got, tc.notShown)
			}
		})
	}
}

func TestValidateRefusesOversizedBody(t *testing.T) {
	body := append(readValid(t), make([]byte, MaxSize)...)
	if _, err := Validate(body); err == nil {
		t.Error("Validate(oversized) = nil, want an error")
	}
}

func TestShownAppsAreNotHidden(t *testing.T) {
	for _, a := range Shown() {
		for _, v := range []string{a.ID, a.SLOApp, strings.ToLower(a.Name)} {
			if Hidden(v) {
				t.Errorf("shown app %q: %q is download or indexer tooling, never shown", a.ID, v)
			}
		}
	}
}

func TestHidden(t *testing.T) {
	for _, s := range []string{"sonarr", "radarr", "qbittorrent", "prowlarr", "theater", "someotherarr"} {
		if !Hidden(s) {
			t.Errorf("Hidden(%q) = false, want true", s)
		}
	}
	for _, s := range []string{"immich", "media", "blog"} {
		if Hidden(s) {
			t.Errorf("Hidden(%q) = true, want false", s)
		}
	}
}

func TestRounding(t *testing.T) {
	pct := []struct {
		in   float64
		want float64
	}{
		{0.99956, 99.9},
		{0.9995, 99.9},
		{0.995, 99.5},
		{1.0, 100},
		{1.2, 100},
		{-0.1, 0},
	}
	for _, tc := range pct {
		if got := PercentDown(tc.in); got != tc.want {
			t.Errorf("PercentDown(%v) = %v, want %v", tc.in, got, tc.want)
		}
	}
	budget := []struct {
		in   float64
		want int
	}{
		{0.125, 12},
		{0.135, 14},
		{-0.625, -62},
		{-3, -100},
		{2, 100},
	}
	for _, tc := range budget {
		if got := Budget(tc.in); got != tc.want {
			t.Errorf("Budget(%v) = %d, want %d", tc.in, got, tc.want)
		}
	}
	share := []struct {
		part, total, want int
	}{
		{1, 8, 12},
		{3, 8, 38},
		{1, 200, 0},
		{3, 200, 2},
		{0, 0, 0},
	}
	for _, tc := range share {
		if got := Share(tc.part, tc.total); got != tc.want {
			t.Errorf("Share(%d, %d) = %d, want %d", tc.part, tc.total, got, tc.want)
		}
	}
	if got, want := Median([]float64{900, 600, 700}), 700.0; got != want {
		t.Errorf("Median(odd) = %v, want %v", got, want)
	}
	if got, want := Median([]float64{600, 700, 900, 601}), 650.5; got != want {
		t.Errorf("Median(even) = %v, want %v", got, want)
	}
	seconds := []struct {
		in   float64
		want int
	}{
		{650.5, 650},
		{651.5, 652},
		{0.2, 1},
	}
	for _, tc := range seconds {
		if got := RoundSeconds(tc.in); got != tc.want {
			t.Errorf("RoundSeconds(%v) = %d, want %d", tc.in, got, tc.want)
		}
	}
}

func TestDays(t *testing.T) {
	// The last Sunday of October: the day is 25 hours long.
	d := time.Date(2026, 10, 25, 0, 0, 0, 0, Zurich)
	if got, want := AddDays(d, 1).Sub(d), 25*time.Hour; got != want {
		t.Errorf("AddDays(25 October, 1) - 25 October = %v, want %v", got, want)
	}
	if got, want := Day(time.Date(2026, 11, 19, 23, 30, 0, 0, time.UTC)).Format(DateLayout), "2026-11-20"; got != want {
		t.Errorf("Day(23:30Z) = %s, want %s", got, want)
	}
	if got, want := FormatTime(time.Date(2026, 7, 1, 10, 0, 0, 5, time.UTC)), "2026-07-01T12:00:00+02:00"; got != want {
		t.Errorf("FormatTime() = %s, want %s", got, want)
	}
}

func TestSignAndVerify(t *testing.T) {
	_, key, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	_, other, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	body := readValid(t)
	sig := Sign(key, body)
	pub := key.Public().(ed25519.PublicKey)
	otherPub := other.Public().(ed25519.PublicKey)
	tests := []struct {
		name   string
		keys   []ed25519.PublicKey
		header string
		body   []byte
		want   bool
	}{
		{"right key", []ed25519.PublicKey{pub}, sig, body, true},
		{"second of two keys", []ed25519.PublicKey{otherPub, pub}, sig, body, true},
		{"other key", []ed25519.PublicKey{otherPub}, sig, body, false},
		{"changed body", []ed25519.PublicKey{pub}, sig, append([]byte(" "), body...), false},
		{"no prefix", []ed25519.PublicKey{pub}, strings.TrimPrefix(sig, "ed25519="), body, false},
		{"not base64", []ed25519.PublicKey{pub}, "ed25519=!!", body, false},
		{"empty", []ed25519.PublicKey{pub}, "", body, false},
	}
	for _, tc := range tests {
		if got := Verify(tc.keys, tc.header, tc.body); got != tc.want {
			t.Errorf("%s: Verify() = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestParseKeys(t *testing.T) {
	pub1, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	pub2, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	got, err := ParsePrivateKey(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	if err != nil {
		t.Fatalf("ParsePrivateKey() = %v", err)
	}
	if !got.Equal(priv) {
		t.Error("ParsePrivateKey() returned another key")
	}
	var pems []byte
	for _, p := range []ed25519.PublicKey{pub1, pub2} {
		der, err := x509.MarshalPKIXPublicKey(p)
		if err != nil {
			t.Fatal(err)
		}
		pems = append(pems, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})...)
	}
	keys, err := ParsePublicKeys(pems)
	if err != nil {
		t.Fatalf("ParsePublicKeys() = %v", err)
	}
	if diff := cmp.Diff([]ed25519.PublicKey{pub1, pub2}, keys); diff != "" {
		t.Errorf("ParsePublicKeys() mismatch (-want +got):\n%s", diff)
	}
	if _, err := ParsePublicKeys([]byte("nothing")); err == nil {
		t.Error("ParsePublicKeys(no PEM) = nil error, want an error")
	}
	if _, err := ParsePrivateKey([]byte("nothing")); err == nil {
		t.Error("ParsePrivateKey(no PEM) = nil error, want an error")
	}
}

func FuzzValidate(f *testing.F) {
	f.Add(readValid(f))
	f.Add([]byte(`{}`))
	f.Add([]byte(`{"schema_version":1}`))
	f.Fuzz(func(t *testing.T, body []byte) {
		s, err := Validate(body)
		if err != nil {
			return
		}
		// Anything accepted must name exactly the shown apps.
		for i, a := range s.Daily.Apps {
			if a.ID != shown[i].ID || Hidden(a.ID) {
				t.Errorf("Validate accepted app %q at %d", a.ID, i)
			}
		}
	})
}
