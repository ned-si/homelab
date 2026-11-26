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
	return obj(doc, "availability")["apps"].([]any)
}

func item(doc map[string]any, block, list string, i int) map[string]any {
	return obj(doc, block)[list].([]any)[i].(map[string]any)
}

func TestValidateAcceptsFixture(t *testing.T) {
	s, err := Validate(readValid(t))
	if err != nil {
		t.Fatalf("Validate(valid.json) = %v, want nil", err)
	}
	if got := s.Availability.Apps[7].AvailabilityDaily[0]; got != nil {
		t.Errorf("landing availability_daily[0] = %v, want nil", *got)
	}
	if got := s.Certificates.Certs[2].DaysLeft; got != nil {
		t.Errorf("homelab days_left = %v, want nil", *got)
	}
	if got, want := s.Availability.Days[len(s.Availability.Days)-1], "2026-11-20"; got != want {
		t.Errorf("last of availability.days = %s, want %s", got, want)
	}
}

// TestNoFreeText pins the keys that hold text: each is either
// from a compiled list or bounded by a pattern a sentence cannot match.
func TestNoFreeText(t *testing.T) {
	s, err := Validate(readValid(t))
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(struct {
		A Availability
		C Certificates
		N []NodeUse
		R []CIRun
		S Security
	}{s.Availability, s.Certificates, s.Cluster.NodeUse, s.Project.CIRuns, s.Security})
	if err != nil {
		t.Fatal(err)
	}
	var walk func(path string, v any)
	walk = func(path string, v any) {
		switch v := v.(type) {
		case map[string]any:
			for k, x := range v {
				walk(path+"."+k, x)
			}
		case []any:
			for _, x := range v {
				walk(path, x)
			}
		case string:
			if strings.ContainsAny(v, " _/") && !strings.HasSuffix(path, ".name") && !strings.HasSuffix(path, ".id") {
				t.Errorf("%s = %q: free text", path, v)
			}
		}
	}
	var doc any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	walk("", doc)
	names := map[string]bool{}
	for _, a := range Shown() {
		names[a.Name] = true
	}
	for _, c := range ShownCerts() {
		names[c.Name] = true
	}
	for _, sig := range ShownSignals() {
		names[sig.ID], names[sig.Name] = true, true
	}
	for _, a := range s.Availability.Apps {
		if !names[a.Name] {
			t.Errorf("availability app name %q is not compiled in", a.Name)
		}
	}
	for _, sig := range s.Security.Signals {
		if !names[sig.ID] || !names[sig.Name] {
			t.Errorf("security signal %q (%q) is not compiled in", sig.ID, sig.Name)
		}
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
		{"a daily block", func(d map[string]any) { d["daily"] = map[string]any{"covers": "2026-11-19"} }, false},
		{"extra key in an app", func(d map[string]any) { apps(d)[0].(map[string]any)["extra"] = 1 }, false},
		{"extra key in cluster", func(d map[string]any) { obj(d, "cluster")["consumption"] = 1 }, false},
		{"extra key in project", func(d map[string]any) { obj(d, "project")["extra"] = 1 }, false},
		{"version 3", func(d map[string]any) { d["schema_version"] = 3 }, false},
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
		{"one app missing", func(d map[string]any) { obj(d, "availability")["apps"] = apps(d)[1:] }, true},
		{"cluster as_of after generated_at", func(d map[string]any) {
			obj(d, "cluster")["as_of"] = "2026-11-20T17:00:01+01:00"
		}, false},
		{"project as_of after generated_at", func(d map[string]any) {
			obj(d, "project")["as_of"] = "2026-11-20T18:00:00+01:00"
		}, false},

		// The redesign's blocks.
		{"no availability", func(d map[string]any) { delete(d, "availability") }, false},
		{"no certificates", func(d map[string]any) { delete(d, "certificates") }, false},
		{"no node_use", func(d map[string]any) { delete(obj(d, "cluster"), "node_use") }, false},
		{"no ci_runs", func(d map[string]any) { delete(obj(d, "project"), "ci_runs") }, false},
		{"no state", func(d map[string]any) { delete(item(d, "availability", "apps", 0), "state") }, false},
		{"extra key in availability", func(d map[string]any) { obj(d, "availability")["extra"] = 1 }, false},
		{"extra key in a live app", func(d map[string]any) { item(d, "availability", "apps", 0)["extra"] = 1 }, false},
		{"extra key in a certificate", func(d map[string]any) { item(d, "certificates", "certs", 0)["extra"] = 1 }, false},
		{"extra key in a node", func(d map[string]any) { item(d, "cluster", "node_use", 0)["pod"] = "x" }, false},
		{"extra key in nas", func(d map[string]any) { obj(d, "cluster", "nas")["extra"] = 1 }, false},
		{"extra key in gateway", func(d map[string]any) { obj(d, "cluster", "gateway")["route"] = "x" }, false},
		{"extra key in volumes", func(d map[string]any) { obj(d, "cluster", "volumes")["name"] = "x" }, false},
		{"extra key in a ci run", func(d map[string]any) { item(d, "project", "ci_runs", 0)["title"] = "x" }, false},
		{"unknown state", func(d map[string]any) { item(d, "availability", "apps", 0)["state"] = "degraded" }, false},
		{"live availability above 100", func(d map[string]any) {
			item(d, "availability", "apps", 0)["availability_30d"] = 100.1
		}, false},
		{"days_left above 400", func(d map[string]any) { item(d, "certificates", "certs", 0)["days_left"] = 401 }, false},
		{"cpu above 100", func(d map[string]any) { item(d, "cluster", "node_use", 0)["cpu"] = 100.5 }, false},
		{"negative network errors", func(d map[string]any) {
			item(d, "cluster", "node_use", 0)["net_errors_per_second"] = -1
		}, false},
		{"negative restarts", func(d map[string]any) { obj(d, "cluster")["restarts_24h"] = -1 }, false},
		{"change failure rate above 100", func(d map[string]any) { obj(d, "project")["change_failure_rate"] = 101 }, false},
		{"unknown ci result", func(d map[string]any) { item(d, "project", "ci_runs", 0)["result"] = "skipped" }, false},
		{"long commit", func(d map[string]any) { item(d, "project", "ci_runs", 0)["commit"] = "6d0407e2" }, false},
		{"29 days", func(d map[string]any) {
			a := obj(d, "availability")
			a["days"] = a["days"].([]any)[1:]
		}, false},
		{"days not consecutive", func(d map[string]any) {
			obj(d, "availability")["days"].([]any)[3] = "2026-10-26"
		}, false},
		{"days ending yesterday", func(d map[string]any) {
			days := obj(d, "availability")["days"].([]any)
			for i := range days {
				t, _ := ParseDate(days[i].(string))
				days[i] = AddDays(t, -1).Format(DateLayout)
			}
		}, false},
		{"availability as_of after generated_at", func(d map[string]any) {
			obj(d, "availability")["as_of"] = "2026-11-20T17:00:01+01:00"
		}, false},
		{"certificates as_of after generated_at", func(d map[string]any) {
			obj(d, "certificates")["as_of"] = "2026-11-20T17:00:01+01:00"
		}, false},
		{"synced above apps", func(d map[string]any) { obj(d, "cluster")["synced"] = 56 }, false},
		{"healthy above apps", func(d map[string]any) { obj(d, "cluster")["healthy"] = 56 }, false},
		{"node_use shorter than nodes", func(d map[string]any) {
			c := obj(d, "cluster")
			c["node_use"] = c["node_use"].([]any)[1:]
		}, false},
		{"nodes out of order", func(d map[string]any) {
			n := obj(d, "cluster")["node_use"].([]any)
			n[0], n[1] = n[1], n[0]
		}, false},
		{"ci_runs out of order", func(d map[string]any) {
			r := obj(d, "project")["ci_runs"].([]any)
			r[0], r[1] = r[1], r[0]
		}, false},
		{"six ci runs", func(d map[string]any) {
			p := obj(d, "project")
			r := p["ci_runs"].([]any)
			p["ci_runs"] = append(r, r[len(r)-1])
		}, false},
		{"live app outside the allow-list", func(d map[string]any) {
			a := item(d, "availability", "apps", 0)
			a["id"], a["name"] = "grafana", "Grafana"
		}, true},
		{"hidden live app", func(d map[string]any) {
			a := item(d, "availability", "apps", 0)
			a["id"], a["name"] = "radarr", "Radarr"
		}, true},
		{"live apps out of order", func(d map[string]any) {
			as := obj(d, "availability")["apps"].([]any)
			as[0], as[1] = as[1], as[0]
		}, true},
		{"unknown certificate", func(d map[string]any) {
			c := item(d, "certificates", "certs", 0)
			c["id"], c["name"] = "example", "example.org"
		}, true},
		{"one certificate missing", func(d map[string]any) {
			c := obj(d, "certificates")
			c["certs"] = c["certs"].([]any)[1:]
		}, true},
		{"node named like hidden tooling", func(d map[string]any) {
			item(d, "cluster", "node_use", 3)["name"] = "sonarr"
		}, true},
		{"free text as a node name", func(d map[string]any) {
			item(d, "cluster", "node_use", 0)["name"] = "Hello World"
		}, false},

		// Version 4, the security block.
		{"no security", func(d map[string]any) { delete(d, "security") }, false},
		{"extra key in security", func(d map[string]any) { obj(d, "security")["top_paths"] = []any{"/wp-admin"} }, false},
		{"extra key in a signal", func(d map[string]any) { item(d, "security", "signals", 0)["rule"] = "x" }, false},
		{"no buckets", func(d map[string]any) { delete(item(d, "security", "signals", 0), "buckets") }, false},
		{"27 buckets", func(d map[string]any) {
			sig := item(d, "security", "signals", 0)
			sig["buckets"] = sig["buckets"].([]any)[1:]
		}, false},
		{"negative count", func(d map[string]any) { item(d, "security", "signals", 0)["count_24h"] = -1 }, false},
		{"24 h above 7 days", func(d map[string]any) {
			sig := item(d, "security", "signals", 0)
			sig["count_24h"], sig["count_7d"] = 10, 9
		}, false},
		{"security as_of after generated_at", func(d map[string]any) {
			obj(d, "security")["as_of"] = "2026-11-20T17:00:01+01:00"
		}, false},
		{"unknown signal", func(d map[string]any) {
			sig := item(d, "security", "signals", 0)
			sig["id"], sig["name"] = "signin_lockouts", "Brute-force lockouts"
		}, true},
		{"signals out of order", func(d map[string]any) {
			sigs := obj(d, "security")["signals"].([]any)
			sigs[0], sigs[1] = sigs[1], sigs[0]
		}, true},
		// Version 5: shares, totals, the 403 part and the unattributed 4xx.
		{"share above 1", func(d map[string]any) { item(d, "security", "signals", 0)["share_24h"] = 1.5 }, false},
		{"no share key", func(d map[string]any) { delete(item(d, "security", "signals", 0), "share_7d") }, false},
		{"unattributed on another signal", func(d map[string]any) {
			item(d, "security", "signals", 1)["unattributed_24h"] = 3
		}, false},
		{"one signal missing", func(d map[string]any) {
			sec := obj(d, "security")
			sec["signals"] = sec["signals"].([]any)[1:]
		}, true},
		// Version 6: the rework rate, the CI median nullable.
		{"version 5", func(d map[string]any) { d["schema_version"] = 5 }, false},
		{"no rework", func(d map[string]any) { delete(obj(d, "project"), "rework") }, false},
		{"extra key in rework", func(d map[string]any) { obj(d, "project", "rework")["titles"] = []any{"fix: x"} }, false},
		{"rework rate above 1", func(d map[string]any) { obj(d, "project", "rework")["rate"] = 1.5 }, false},
		{"rework count above deploys", func(d map[string]any) {
			r := obj(d, "project", "rework")
			r["count"], r["deploys"] = 10, 9
		}, false},
		// Version 7: the supply chain block.
		{"version 6", func(d map[string]any) { d["schema_version"] = 6 }, false},
		{"no supply chain", func(d map[string]any) { delete(d, "supply_chain") }, false},
		{"images out of order", func(d map[string]any) {
			imgs := obj(d, "supply_chain")["images"].([]any)
			imgs[0], imgs[1] = imgs[1], imgs[0]
		}, false},
		{"an image missing", func(d map[string]any) {
			sc := obj(d, "supply_chain")
			sc["images"] = sc["images"].([]any)[:1]
		}, false},
		{"another builder", func(d map[string]any) {
			obj(d, "supply_chain")["images"].([]any)[0].(map[string]any)["builder"] = "self-hosted runner"
		}, false},
		{"level 3", func(d map[string]any) {
			obj(d, "supply_chain")["images"].([]any)[0].(map[string]any)["level"] = 3
		}, false},
		{"level without verification", func(d map[string]any) {
			obj(d, "supply_chain")["images"].([]any)[0].(map[string]any)["verified"] = false
		}, false},
		{"extra key in an image", func(d map[string]any) {
			obj(d, "supply_chain")["images"].([]any)[0].(map[string]any)["pod"] = "homelab-dashboard-web-1"
		}, false},
		{"supply chain after generated_at", func(d map[string]any) {
			obj(d, "supply_chain")["as_of"] = "2026-11-20T18:00:00+01:00"
		}, false},
		// Version 8: the Scorecard result.
		{"version 7", func(d map[string]any) { d["schema_version"] = 7 }, false},
		{"no scorecard", func(d map[string]any) { delete(obj(d, "supply_chain"), "scorecard") }, false},
		{"score above 10", func(d map[string]any) { obj(d, "supply_chain", "scorecard")["score"] = 10.5 }, false},
		{"a score without as_of", func(d map[string]any) { obj(d, "supply_chain", "scorecard")["as_of"] = nil }, false},
		{"scorecard after generated_at", func(d map[string]any) {
			obj(d, "supply_chain", "scorecard")["as_of"] = "2026-11-20T17:01:00+01:00"
		}, false},
		// Version 9: every check, in name order.
		{"version 8", func(d map[string]any) { d["schema_version"] = 8 }, false},
		{"the lowest checks of version 8", func(d map[string]any) {
			sc := obj(d, "supply_chain", "scorecard")
			sc["lowest"] = sc["checks"]
			delete(sc, "checks")
		}, false},
		{"a check twice", func(d map[string]any) {
			sc := obj(d, "supply_chain", "scorecard")
			sc["checks"] = append(sc["checks"].([]any), scorecardCheck(d, len(sc["checks"].([]any))-1))
		}, false},
		{"21 checks", func(d map[string]any) {
			sc := obj(d, "supply_chain", "scorecard")
			for len(sc["checks"].([]any)) < 21 {
				sc["checks"] = append(sc["checks"].([]any), map[string]any{"name": "Webhooks", "score": 10, "reason": "r"})
			}
		}, false},
		{"a score of -1", func(d map[string]any) {
			scorecardCheck(d, 0)["score"] = -1
		}, false},
		{"a check not compiled", func(d map[string]any) {
			scorecardCheck(d, 0)["name"] = "Made-Up"
		}, false},
		{"a reason with a control character", func(d map[string]any) {
			scorecardCheck(d, 0)["reason"] = "line one\nline two"
		}, false},
		{"a reason over 160 characters", func(d map[string]any) {
			scorecardCheck(d, 0)["reason"] = strings.Repeat("a", 161)
		}, false},
		{"checks not in name order", func(d map[string]any) {
			c := obj(d, "supply_chain", "scorecard")["checks"].([]any)
			c[0], c[1] = c[1], c[0]
		}, false},
		{"extra key in a check", func(d map[string]any) {
			scorecardCheck(d, 0)["details"] = []any{"Warn: no approvals"}
		}, false},
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

// Version 5 carries every percentage and the error budget at full
// precision.
func TestValidateFullPrecision(t *testing.T) {
	s, err := Validate(mutate(t, func(d map[string]any) {
		item(d, "availability", "apps", 1)["error_budget_remaining_30d"] = 25.004
		obj(d, "project")["renovate_share_30d"] = 33.333
	}))
	if err != nil {
		t.Fatalf("Validate() = %v", err)
	}
	if got := *s.Availability.Apps[0].Availability30d; got != 99.957 {
		t.Errorf("availability_30d = %v, want 99.957", got)
	}
	if got := *s.Availability.Apps[1].ErrorBudgetRemaining30d; got != 25.004 {
		t.Errorf("error_budget_remaining_30d = %v, want 25.004", got)
	}
	if got := s.Project.RenovateShare30d; got != 33.333 {
		t.Errorf("renovate_share_30d = %v, want 33.333", got)
	}
}

// Version 6: without the token the rework rate and the CI median are null.
func TestValidateNullProjectFigures(t *testing.T) {
	s, err := Validate(mutate(t, func(d map[string]any) {
		p := obj(d, "project")
		p["rework"], p["ci_median_seconds_30d"] = nil, nil
	}))
	if err != nil {
		t.Fatalf("Validate() = %v", err)
	}
	if s.Project.Rework != nil || s.Project.CIMedianSeconds30d != nil {
		t.Errorf("rework, ci median = %v, %v, want null", s.Project.Rework, s.Project.CIMedianSeconds30d)
	}
}

func scorecardCheck(doc map[string]any, i int) map[string]any {
	return obj(doc, "supply_chain", "scorecard")["checks"].([]any)[i].(map[string]any)
}

// Before the first fetch the Scorecard result is empty, and the snapshot
// still valid.
func TestValidateNoScorecardYet(t *testing.T) {
	s, err := Validate(mutate(t, func(d map[string]any) {
		sc := obj(d, "supply_chain", "scorecard")
		sc["as_of"], sc["score"], sc["date"], sc["checks"] = nil, nil, nil, []any{}
	}))
	if err != nil {
		t.Fatalf("Validate() = %v", err)
	}
	if sc := s.SupplyChain.Scorecard; sc.Score != nil || len(sc.Checks) != 0 {
		t.Errorf("scorecard = %+v, want empty", sc)
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
		for _, v := range append([]string{a.ID, a.SLOApp, strings.ToLower(a.Name)}, a.Probes()...) {
			if Hidden(v) {
				t.Errorf("shown app %q: %q is download or indexer tooling, never shown", a.ID, v)
			}
		}
	}
}

func TestShownCertsAreNotHidden(t *testing.T) {
	for _, c := range ShownCerts() {
		for _, v := range []string{c.ID, c.Name, c.Instance} {
			if Hidden(v) {
				t.Errorf("shown certificate %q: %q is download or indexer tooling, never shown", c.ID, v)
			}
		}
	}
}

// The signals count events of a series born inside the window, and every
// expression sums its selectors away.
func TestSignalQueries(t *testing.T) {
	want := `sum((keycloak_user_events_total{event="login", error!=""} unless keycloak_user_events_total{event="login", error!=""} offset <w>)` +
		` or increase(keycloak_user_events_total{event="login", error!=""}[<w>]))`
	got := map[string]ShownSignal{}
	for _, sig := range ShownSignals() {
		got[sig.ID] = sig
		if !strings.HasPrefix(sig.Query, "sum(") && !strings.HasPrefix(sig.Query, "count(") && !strings.HasPrefix(sig.Query, "(sum(") {
			t.Errorf("%s: %q is not a sum over the cluster", sig.ID, sig.Query)
		}
		if strings.Contains(sig.Query, " by (") {
			t.Errorf("%s: %q keeps a label", sig.ID, sig.Query)
		}
		if Hidden(sig.ID) || Hidden(strings.ToLower(sig.Name)) {
			t.Errorf("%s: names download or indexer tooling", sig.ID)
		}
		if zero := strings.Contains(sig.Query, "vector(0)"); zero != sig.ExpectedZero {
			t.Errorf("%s: or vector(0) is %v, want it only on expected-zero signals", sig.ID, zero)
		}
		if strings.Contains(strings.ToLower(sig.Name), "observe") {
			t.Errorf("%s: %q says observe mode", sig.ID, sig.Name)
		}
	}
	if diff := cmp.Diff(want, got["signin_failed"].Query); diff != "" {
		t.Errorf("signin_failed query mismatch (-want +got):\n%s", diff)
	}
	c := func(s string) string {
		return "sum((" + s + " unless " + s + " offset <w>) or increase(" + s + "[<w>]))"
	}
	p := `envoy_http_conn_manager_prefix=~"listener-secure|listener-insecure"`
	reqs := `envoy_http_downstream_rq_total{` + p + `}`
	gw := " or on() (0 * sum(" + reqs + "))"
	up := `envoy_cluster_upstream_rq{envoy_cluster_name=~"gateway/.+", envoy_response_code=`
	for _, tc := range []struct{ id, field, got, want string }{
		{"gateway_unknown", "query", got["gateway_unknown"].Query, c(`envoy_http_no_route{`+p+`}`) + " + (" +
			c(`envoy_cluster_upstream_rq{envoy_cluster_name=~"gateway/.+/(website|homelab-dashboard)_.+", envoy_response_code="404"}`) + gw + ")"},
		{"gateway_unknown", "total", got["gateway_unknown"].Total, c(reqs)},
		{"gateway_refused", "query", got["gateway_refused"].Query, c(up+`~"401|403"}`) + gw},
		{"gateway_refused", "part", got["gateway_refused"].Part, c(up+`"403"}`) + gw},
		{"gateway_method", "query", got["gateway_method"].Query, c(up+`"405"}`) + gw},
		{"signin_failed", "total", got["signin_failed"].Total, c(`keycloak_user_events_total{event="login"}`)},
		{"blocked", "query", got["blocked"].Query, "(" +
			c(`apiserver_admission_webhook_rejection_count{name=~"i?vpol\\.validate\\.kyverno\\.svc.*", error_type="no_error"}`) +
			" or vector(0)) + (" + c(`pod_security_evaluations_total{decision="deny", mode="enforce"}`) + " or vector(0))"},
		{"ingress_world", "query", got["ingress_world"].Query,
			c(`hubble_drop_total{reason="POLICY_DENIED", source="reserved:world"}`) + " or on() (0 * sum(hubble_drop_total))"},
		{"runtime_detections", "query", got["runtime_detections"].Query,
			`count(max_over_time(ALERTS{alertname=~"Runtime.+", alertstate="firing"}[<w>])) or vector(0)`},
		{"gateway_unknown", "unattributed", UnattributedQuery, "clamp_min(" +
			c(`envoy_http_downstream_rq_xx{envoy_response_code_class="4", `+p+`}`) + " - " + c(`envoy_http_no_route{`+p+`}`) +
			" - (" + c(up+`~"4.."}`) + gw + "), 0)"},
	} {
		if diff := cmp.Diff(tc.want, tc.got); diff != "" {
			t.Errorf("%s %s mismatch (-want +got):\n%s", tc.id, tc.field, diff)
		}
	}
	if _, ok := got["signin_lockouts"]; ok {
		t.Error("a lockout count would show which usernames exist")
	}
}

func TestProbes(t *testing.T) {
	one := ShownApp{ID: "immich", SLOApp: "media"}
	if diff := cmp.Diff([]string{"media"}, one.Probes()); diff != "" {
		t.Errorf("Probes() of one probe mismatch (-want +got):\n%s", diff)
	}
	many := ShownApp{ID: "observability", SLOApp: "observability", ProbeApps: []string{"grafana", "signoz"}}
	if diff := cmp.Diff([]string{"grafana", "signoz"}, many.Probes()); diff != "" {
		t.Errorf("Probes() of four probes mismatch (-want +got):\n%s", diff)
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
	// Full precision, clamped: the web role rounds once when it formats.
	for _, tc := range []struct {
		name string
		got  float64
		want float64
	}{
		{"ToPercent(0.99957)", ToPercent(0.99957), 100 * 0.99957},
		{"ToPercent(1.2)", ToPercent(1.2), 100},
		{"ToPercent(-0.1)", ToPercent(-0.1), 0},
		{"BudgetPercent(-0.625)", BudgetPercent(-0.625), -62.5},
		{"BudgetPercent(-3)", BudgetPercent(-3), -100},
		{"BudgetPercent(2)", BudgetPercent(2), 100},
		{"SharePercent(1, 8)", SharePercent(1, 8), 12.5},
		{"SharePercent(3, 200)", SharePercent(3, 200), 1.5},
		{"SharePercent(0, 0)", SharePercent(0, 0), 0},
	} {
		if tc.got != tc.want {
			t.Errorf("%s = %v, want %v", tc.name, tc.got, tc.want)
		}
	}
	if got, want := Median([]float64{900, 600, 700}), 700.0; got != want {
		t.Errorf("Median(odd) = %v, want %v", got, want)
	}
	if got, want := Median([]float64{600, 700, 900, 601}), 650.5; got != want {
		t.Errorf("Median(even) = %v, want %v", got, want)
	}
	for _, tc := range []struct {
		in, want float64
	}{{0.625, 0.62}, {0.375, 0.38}} {
		if got := Round(tc.in, 2); got != tc.want {
			t.Errorf("Round(%v, 2) = %v, want %v", tc.in, got, tc.want)
		}
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
		for i, a := range s.Availability.Apps {
			if a.ID != shown[i].ID || Hidden(a.ID) {
				t.Errorf("Validate accepted app %q at %d", a.ID, i)
			}
		}
	})
}
