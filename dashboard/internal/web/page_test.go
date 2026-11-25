package web

import (
	"encoding/xml"
	"errors"
	"html/template"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

func sub(doc map[string]any, name string) map[string]any {
	return doc[name].(map[string]any)
}

func apps(doc map[string]any) []map[string]any {
	var out []map[string]any
	for _, a := range sub(doc, "availability")["apps"].([]any) {
		out = append(out, a.(map[string]any))
	}
	return out
}

func days(t *testing.T, doc map[string]any) []string {
	t.Helper()
	var out []string
	for _, d := range sub(doc, "availability")["days"].([]any) {
		out = append(out, d.(string))
	}
	return out
}

// fullDaily has 30 days for every app but the dashboard's own, so those
// cards have a budget, and one day without probes, so the page has every
// status: Observability ok, Immich warn, Paperless-ngx bad and down, a Plex
// day none, the Homelab dashboard without data.
func fullDaily(t *testing.T) map[string]any {
	t.Helper()
	doc := fixture(t)
	for _, a := range apps(doc) {
		if a["id"] == "homelab" {
			continue
		}
		days := a["availability_daily"].([]any)
		for i := range days {
			if days[i] == nil {
				days[i] = 100.0
			}
		}
		if a["id"] == "plex" {
			days[10] = nil
		}
	}
	return doc
}

// exhausted has one budget at exactly 0 and the rest below it.
func exhausted(t *testing.T) map[string]any {
	t.Helper()
	doc := fullDaily(t)
	for i, a := range apps(doc) {
		if a["id"] == "homelab" {
			continue
		}
		a["error_budget_remaining_30d"] = -100
		a["availability_30d"] = 98.0
		if i == 0 {
			a["error_budget_remaining_30d"] = 0
			a["availability_30d"] = 99.5
		}
	}
	return doc
}

// alarms turns the certificates, cluster and project figures to warn and
// bad, and the Gateway to no data.
func alarms(t *testing.T) map[string]any {
	t.Helper()
	doc := fullDaily(t)
	certs := sub(doc, "certificates")["certs"].([]any)
	certs[0].(map[string]any)["days_left"] = 14
	certs[1].(map[string]any)["days_left"] = 3
	c := sub(doc, "cluster")
	c["synced"], c["restarts_24h"] = 50, 25
	n := c["node_use"].([]any)[0].(map[string]any)
	n["ready"], n["cpu"], n["disk"], n["cpu_pressure"], n["net_errors_per_second"] = false, 96.0, 90.0, 30.0, 1.5
	nas := sub(c, "nas")
	nas["up"], nas["pool_healthy"], nas["load_per_core"], nas["device_errors"], nas["cpu"] = false, false, 1.5, 2, nil
	c["gateway"] = map[string]any{"requests_per_second": nil, "errors_5xx": nil, "latency_p95_ms": nil}
	sub(c, "volumes")["fullest"] = 96.0
	p := sub(doc, "project")
	p["deploys_30d"], p["lead_time_seconds"], p["change_failure_rate"], p["incidents_30d"] = 2, 864000, 20.0, 0
	return doc
}

// staleBlocks has a cluster block 10 minutes and a project block 2 hours
// older than generated_at.
func staleBlocks(t *testing.T) map[string]any {
	t.Helper()
	doc := fixture(t)
	sub(doc, "cluster")["as_of"] = "2026-11-20T16:50:00+01:00"
	sub(doc, "project")["as_of"] = "2026-11-20T15:00:00+01:00"
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
		{"exhausted", exhausted, fixtureNow},
		{"alarms", alarms, fixtureNow},
		{"stale-live", fixture, fixtureNow.Add(2 * time.Hour)},
		{"stale-blocks", staleBlocks, fixtureNow},
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
			rec := h.get(t, http.MethodGet, "/")
			if rec.Code != http.StatusOK {
				t.Fatalf("GET / = %d", rec.Code)
			}
			checkMarkup(t, rec.Body.String())
			golden(t, filepath.Join("testdata", tc.name+".golden.html"), rec.Body.Bytes())
		})
	}
	h := newHarness(t)
	rec := h.get(t, http.MethodGet, "/nope")
	checkMarkup(t, rec.Body.String())
	golden(t, "testdata/notfound.golden.html", rec.Body.Bytes())
}

func checkMarkup(t *testing.T, body string) {
	t.Helper()
	for _, bad := range []string{"<script", "style=", "<style", "<form", "<iframe"} {
		if strings.Contains(body, bad) {
			t.Errorf("the page contains %q", bad)
		}
	}
	if regexp.MustCompile(`<[^>]+\son[a-z]+=`).MatchString(body) {
		t.Error("an on* attribute in the page")
	}
}

func page(t *testing.T, doc map[string]any) string {
	t.Helper()
	h := newHarness(t)
	if code := h.pushDoc(t, doc); code != http.StatusNoContent {
		t.Fatalf("push = %d", code)
	}
	return h.get(t, http.MethodGet, "/").Body.String()
}

func contains(t *testing.T, body string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(body, w) {
			t.Errorf("the page lacks %q", w)
		}
	}
}

// Acceptance criterion 6: one card per shown app, and every status class
// next to its word.
func TestFullPageCardsAndStatuses(t *testing.T) {
	body := page(t, fullDaily(t))
	if got, want := strings.Count(body, `<div class="card">`), len(snapshot.Shown()); got != want {
		t.Errorf("%d cards, want %d (one per shown app)", got, want)
	}
	for _, s := range snapshot.Shown() {
		if !strings.Contains(body, "<h3>"+template.HTMLEscapeString(s.Name)+" <span class=\"state") {
			t.Errorf("no card for %s", s.Name)
		}
	}
	contains(t, body,
		`<span class="status ok">Met</span>`,
		`<span class="status warn">At risk</span>`,
		`<span class="status bad">Missed</span>`,
		`<span class="state ok">Up</span>`,
		`<span class="state bad">Down</span>`,
		`<span class="state none">No data</span>`,
		`class="none"`,
	)
	if !regexp.MustCompile(`<rect class="none"[^>]*><title>2026-11-01: No data</title>`).MatchString(body) {
		t.Error("the day without probes has no none bar titled No data")
	}
	if !regexp.MustCompile(`<rect class="(ok|warn|bad) today"[^>]*><title>2026-11-20 \(today so far\): 99\.80%</title>`).MatchString(body) {
		t.Error("no bar of today so far")
	}
}

// Acceptance criterion 17: the certificates, cluster and project cards with
// each status class next to its word.
func TestCardsStatusWords(t *testing.T) {
	full := page(t, fullDaily(t))
	alarm := page(t, alarms(t))
	for _, tc := range []struct {
		body string
		want []string
	}{
		{full, []string{
			`<p class="tile-label">Unknown host or path</p>
<p class="tile-value ok">4,412 <span class="status ok">Usual</span></p>
<p class="tile-detail">Rolling 24 h, 7.01% of 62,940 requests</p>
<p class="tile-detail">Rolling 7 days: 26,391 (6.12%)</p>`,
			`<p class="tile-value warn">40 <span class="status warn">Above usual</span></p>`,
			`<p class="tile-value warn">1 <span class="status warn">Seen</span></p>`,
			`<p class="tile-value ok">0 <span class="status ok">None</span></p>`,
			`<p class="tile-label">Ingress packets dropped from the internet</p>
<p class="tile-value none"><span class="status none">No data</span></p>`,
			`<p class="tile-value ok">39<span class="unit">days</span> <span class="status ok">Valid</span></p>`,
			`<p class="tile-label">homelab.nedsi.io</p>
<p class="tile-value none"><span class="status none">No data</span></p>`,
			`<p class="tile-value ok">31.20<span class="unit">%</span> <span class="status ok">OK</span></p>`,
			`<p class="tile-value warn">80.40<span class="unit">%</span> <span class="status warn">Warning</span></p>`,
			`<p class="tile-value warn">0.59<span class="unit">%</span> <span class="status warn">Warning</span></p>`,
			`<p class="tile-value ok">41<span class="unit">ms</span> <span class="status ok">OK</span></p>`,
			`<p class="tile-value">0.63<span class="unit">per second</span></p>`,
			`<p class="tile-value warn">55<span class="unit">apps</span> <span class="status warn">Warning</span></p>`,
			`<p class="tile-detail">54 Synced, 55 Healthy</p>`,
			`<p class="tile-detail">384 GiB of 1.0 TiB, fullest 80.80%</p>`,
			`<p class="tile-value ok">709<span class="unit">deploys</span> <span class="status ok">Elite</span></p>`,
			`<p class="tile-detail">23.6 a day</p>`,
			`<p class="tile-value ok">21<span class="unit">min</span> <span class="status ok">Elite</span></p>`,
			`<p class="tile-detail">Median of 640 changes</p>`,
			`<p class="tile-value ok">1.30<span class="unit">%</span> <span class="status ok">Elite</span></p>`,
			`<p class="tile-value ok">25<span class="unit">min</span> <span class="status ok">Elite</span></p>`,
			`<p class="tile-detail">Median of 4 incidents</p>`,
			`<div class="tile accent ok">
<p class="tile-label">Overall level</p>
<p class="tile-value">Elite</p>`,
			`<li><span class="status ok">Success</span> <a href="https://github.com/ned-si/homelab/pull/1602">#1602</a> <code>6d0407e</code> <time datetime="2026-11-20T16:40:12&#43;01:00">20 Nov 16:40</time>, 4<span class="unit">min</span> 58<span class="unit">s</span></li>`,
			`<li><span class="status bad">Failure</span>`,
			`<li><span class="status none">Cancelled</span>`,
			`<li><span class="status warn">Other</span> <code>2ec595b</code>`,
		}},
		{alarm, []string{
			`<p class="tile-value warn">14<span class="unit">days</span> <span class="status warn">Renewal late</span></p>`,
			`<p class="tile-value bad">3<span class="unit">days</span> <span class="status bad">Expiring</span></p>`,
			`<h4>homelab-cp-1 <span class="state bad">Not ready</span></h4>`,
			`<p class="tile-value bad">96.00<span class="unit">%</span> <span class="status bad">Critical</span></p>`,
			`<p class="tile-value warn">90.00<span class="unit">%</span> <span class="status warn">Warning</span></p>`,
			`<p class="tile-value bad">1.50<span class="unit">/s</span> <span class="status bad">Critical</span></p>`,
			`<h4>NAS <span class="state bad">Down</span></h4>`,
			`<p class="tile-value bad">47.90<span class="unit">%</span> <span class="status bad">Critical</span></p>`,
			`<p class="tile-detail">Unhealthy</p>`,
			`<p class="tile-label">CPU</p>
<p class="tile-value none"><span class="status none">No data</span></p>`,
			`<p class="tile-value warn">1.50 <span class="status warn">Warning</span></p>`,
			`<p class="tile-value bad">2 <span class="status bad">Critical</span></p>`,
			`<p class="tile-label">Requests</p>
<p class="tile-value none"><span class="status none">No data</span></p>`,
			`<p class="tile-label">p95 duration</p>
<p class="tile-value none"><span class="status none">No data</span></p>`,
			`<p class="tile-value bad">25 <span class="status bad">Critical</span></p>`,
			`<p class="tile-value bad">35<span class="unit">PVCs</span> <span class="status bad">Critical</span></p>`,
			`<p class="tile-value warn">2<span class="unit">deploys</span> <span class="status warn">Medium</span></p>`,
			`<p class="tile-value warn">10<span class="unit">d</span> <span class="status warn">Medium</span></p>`,
			`<p class="tile-value bad">20.00<span class="unit">%</span> <span class="status bad">Low</span></p>`,
			`<div class="tile accent ok">
<p class="tile-label">Time to restore</p>
<p class="tile-value">None <span class="status ok">No incident</span></p>`,
			`<div class="tile accent bad">
<p class="tile-label">Overall level</p>
<p class="tile-value">Low</p>`,
		}},
	} {
		contains(t, tc.body, tc.want...)
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
		{fixtureNow, []string{
			"Target: 99.50% availability over a rolling 30 days per app.",
			`Updated <time datetime="2026-11-20T17:00:00&#43;01:00">20 November 2026, 17:00</time> (Zurich time).`,
			`<span class="label">since 17 November</span>`,
			"91.40% of the error budget left",
			`<span class="big ok">99.96<span class="unit">%</span></span> <span class="status ok">Met</span>`,
			`5<span class="unit">min</span> 05<span class="unit">s</span>`,
			`aria-label="Opened by Renovate: 50.00%"`,
			`As of <time datetime="2026-11-20T16:52:00&#43;01:00">20 November 2026, 16:52</time>.`,
			"Solar production", "Home automation",
		}, []string{"Live figures from", "Figures from", "No figures yet", "/tags/", "finished day"}},
		{fixtureNow.Add(6 * time.Minute), []string{"Live figures from <time datetime=\"2026-11-20T17:00:00&#43;01:00\">20 November 2026, 17:00</time>"}, nil},
	} {
		h.now = tc.now
		body := h.get(t, http.MethodGet, "/").Body.String()
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

// TestPercentagesTwoDecimals checks that every percentage on the page, in
// text, units, labels and titles, has two decimals.
func TestPercentagesTwoDecimals(t *testing.T) {
	pct := regexp.MustCompile(`([0-9][0-9.]*)(?:<span class="unit">)?%`)
	for name, doc := range map[string]map[string]any{"fixture": fixture(t), "full": fullDaily(t), "exhausted": exhausted(t), "alarms": alarms(t)} {
		body := page(t, doc)
		ms := pct.FindAllStringSubmatch(body, -1)
		if len(ms) == 0 {
			t.Errorf("%s: no percentage on the page", name)
		}
		for _, m := range ms {
			if _, dec, ok := strings.Cut(m[1], "."); !ok || len(dec) != 2 {
				t.Errorf("%s: percentage %q has not two decimals", name, m[0])
			}
		}
	}
}

// Acceptance criterion 29: one rounding, at two decimals, half to even on
// an exact binary tie.
func TestPercent(t *testing.T) {
	for v, want := range map[float64]string{
		99.957: "99.96%", 0.125: "0.12%", 0.375: "0.38%", 0: "0.00%", 100: "100.00%", 99.995: "100.00%", 25.004: "25.00%",
	} {
		if got := percent(v); got != want {
			t.Errorf("percent(%v) = %q, want %q", v, got, want)
		}
	}
}

// From the Cluster card down every label and value sits in a stat tile, no
// label carries a status, and each node and the NAS is one tile group
// (acceptance criterion 22).
func TestStatTiles(t *testing.T) {
	for name, doc := range map[string]map[string]any{"full": fullDaily(t), "alarms": alarms(t)} {
		body := page(t, doc)
		start := strings.Index(body, `id="cluster"`)
		end := strings.Index(body, "<h2>Coming later</h2>")
		if start < 0 || end < start {
			t.Fatalf("%s: no cluster to certificates section", name)
		}
		below := body[start:end]
		for _, old := range []string{`class="big`, `class="label"`, `class="value`, `class="figure"`, `class="stat"`} {
			if strings.Contains(below, old) {
				t.Errorf("%s: %s outside a stat tile from the Cluster card down", name, old)
			}
		}
		if regexp.MustCompile(`class="tile-label [a-z]`).MatchString(below) {
			t.Errorf("%s: a tile label carries a status class", name)
		}
		// Every label is followed by its value in the same tile.
		labels := strings.Count(below, `<p class="tile-label">`)
		if values := strings.Count(below, `<p class="tile-value`); labels == 0 || values != labels {
			t.Errorf("%s: %d tile labels and %d values, want one value per label", name, labels, values)
		}
		if tiles := strings.Count(below, `<div class="tile`) - strings.Count(below, `<div class="tile-group`) -
			strings.Count(below, `<div class="tiles`); tiles != labels {
			t.Errorf("%s: %d tiles and %d labels, want one label per tile", name, tiles, labels)
		}
		groups := strings.Count(below, `<div class="tile-group">`+"\n<h4>")
		if want := len(sub(doc, "cluster")["node_use"].([]any)) + 1; groups != want {
			t.Errorf("%s: %d tile groups, want one per node and the NAS (%d)", name, groups, want)
		}
		if n := strings.Count(below, `<div class="tiles compact">`); n != groups {
			t.Errorf("%s: %d compact grids, want one per group (%d)", name, n, groups)
		}
	}
}

// Every small text about a time window says "rolling", and the page never
// says "observe mode" (Requirements 3.14 and 12.11).
func TestRollingWindows(t *testing.T) {
	body := page(t, fullDaily(t))
	contains(t, body, "rolling 30 days per app", "Project, rolling 30 days", "Gateway, rolling 5 minutes",
		"the rolling 24 h, the rolling 7 days", "Rolling 24 h, 7.01% of 62,940 requests", "Rolling 7 days: 26,391 (6.12%)",
		"Another 760 answered by the Gateway itself cannot be attributed.", "Of these, 12 are 403s",
		"Includes our own weekly security scan.", "Rolling 24 h, 50.00% of 80 sign-ins")
	for _, bad := range []string{"observe mode", "last 30 days", "last 24 hours", "last 7 days", "in 24 h", "in 7 days", "over 30 days"} {
		if strings.Contains(strings.ToLower(body), bad) {
			t.Errorf("the page says %q", bad)
		}
	}
}

// TestSectionOrder checks the order of the page's sections.
func TestSectionOrder(t *testing.T) {
	body := page(t, fixture(t))
	last := -1
	for _, s := range []string{`<header class="page">`, `id="availability"`, `id="cluster"`, "<h3>DORA metrics</h3>", `id="security"`, `id="certificates"`, "<h2>Coming later</h2>"} {
		i := strings.Index(body, s)
		if i < 0 || i < last {
			t.Errorf("%s is missing or out of order", s)
		}
		last = i
	}
}

// A block older than generated_at says so on its own card: 5 minutes, an
// hour for the project block.
func TestBlockStaleness(t *testing.T) {
	body := page(t, staleBlocks(t))
	contains(t, body,
		`Figures from <time datetime="2026-11-20T16:50:00&#43;01:00">20 November 2026, 16:50</time> (Zurich time): this card is not updating.`,
		`Figures from <time datetime="2026-11-20T15:00:00&#43;01:00">20 November 2026, 15:00</time> (Zurich time): this card is not updating.`,
	)
	if n := strings.Count(body, "this card is not updating"); n != 2 {
		t.Errorf("%d stale notices, want 2", n)
	}
	// The fixture's project block is 8 minutes old: under the hour.
	if strings.Contains(page(t, fixture(t)), "this card is not updating") {
		t.Error("the fixture has a stale notice")
	}
}

func TestStatusRules(t *testing.T) {
	v := func(x float64) *float64 { return &x }
	for _, tc := range []struct {
		left float64
		want status
	}{{100, statusOK}, {26, statusOK}, {25.004, statusOK}, {25, statusWarn}, {1, statusWarn}, {0, statusWarn}, {-0.004, statusBad}, {-1, statusBad}, {-100, statusBad}} {
		if got := monthStatus(tc.left); got != tc.want {
			t.Errorf("monthStatus(%v) = %q, want %q", tc.left, got, tc.want)
		}
	}
	// The status reads the raw budget, the text its rounding: 25.004% is
	// "Met" while it reads "25.00%".
	c := card(snapshot.LiveApp{Availability30d: v(99.6), ErrorBudgetRemaining30d: v(25.004), AvailabilityDaily: fullDays()},
		testDays())
	if c.Status != statusOK || c.Word != "Met" || c.BudgetLeft != "25.00" {
		t.Errorf("card with a budget of 25.004 = %q %q %q, want ok, Met, 25.00", c.Status, c.Word, c.BudgetLeft)
	}
	if day := dayStatus(v(99.497)); day != statusWarn || percent(99.497) != "99.50%" {
		t.Errorf("a day of 99.497 = %q %s, want warn while it reads 99.50%%", day, percent(99.497))
	}
	for _, tc := range []struct {
		v    *float64
		want status
	}{{v(100), statusOK}, {v(99.5), statusOK}, {v(99.4), statusWarn}, {v(96.3), statusWarn}, {v(96.25), statusWarn}, {v(96.2), statusBad}, {v(0), statusBad}, {nil, statusNone}} {
		if got := dayStatus(tc.v); got != tc.want {
			t.Errorf("dayStatus(%v) = %q, want %q", tc.v, got, tc.want)
		}
	}
	for s, want := range map[status]string{statusOK: "Met", statusWarn: "At risk", statusBad: "Missed", statusNone: "No data"} {
		if got := monthWord(s); got != want {
			t.Errorf("monthWord(%q) = %q, want %q", s, got, want)
		}
	}
	for state, want := range map[string][2]string{"up": {"ok", "Up"}, "down": {"bad", "Down"}, "none": {"none", "No data"}} {
		if st, w := appState(state); string(st) != want[0] || w != want[1] {
			t.Errorf("appState(%q) = %q %q, want %q %q", state, st, w, want[0], want[1])
		}
	}
}

func TestCertificateRule(t *testing.T) {
	n := func(x int) *int { return &x }
	for _, tc := range []struct {
		days *int
		st   status
		word string
	}{
		{n(90), statusOK, "Valid"}, {n(22), statusOK, "Valid"}, {n(21), statusWarn, "Renewal late"},
		{n(7), statusWarn, "Renewal late"}, {n(6), statusBad, "Expiring"}, {n(-3), statusBad, "Expiring"},
		{nil, statusNone, "No data"},
	} {
		if st, w := certStatus(tc.days); st != tc.st || w != tc.word {
			t.Errorf("certStatus(%v) = %q %q, want %q %q", tc.days, st, w, tc.st, tc.word)
		}
	}
}

// Each threshold of the cluster card on its boundaries: "A to B" includes
// both ends.
func TestClusterRules(t *testing.T) {
	v := func(x float64) *float64 { return &x }
	for _, tc := range []struct {
		name string
		l    limits
		in   []float64
		want []status
	}{
		{"cpu, memory", useLimits, []float64{79.9, 80, 95, 95.1}, []status{statusOK, statusWarn, statusWarn, statusBad}},
		{"disk", diskLimits, []float64{84.9, 85, 92, 92.1}, []status{statusOK, statusWarn, statusWarn, statusBad}},
		{"pressure", pressureLimits, []float64{9.9, 10, 25, 25.1}, []status{statusOK, statusWarn, statusWarn, statusBad}},
		{"pool", poolLimits, []float64{79.9, 80, 90, 90.1}, []status{statusOK, statusWarn, statusWarn, statusBad}},
		{"load per core", loadLimits, []float64{0.99, 1, 2, 2.01}, []status{statusOK, statusWarn, statusWarn, statusBad}},
		{"5xx share", errorShareLimits, []float64{0.49, 0.5, 5, 5.01}, []status{statusOK, statusWarn, statusWarn, statusBad}},
		{"p95", p95Limits, []float64{999, 1000, 5000, 5001}, []status{statusOK, statusWarn, statusWarn, statusBad}},
		{"restarts", restartLimits, []float64{5, 6, 20, 21}, []status{statusOK, statusWarn, statusWarn, statusBad}},
		{"fullest volume", volumeLimits, []float64{84.9, 85, 95, 95.1}, []status{statusOK, statusWarn, statusWarn, statusBad}},
	} {
		for i, x := range tc.in {
			if got := level(v(x), tc.l); got != tc.want[i] {
				t.Errorf("%s: level(%v) = %q, want %q", tc.name, x, got, tc.want[i])
			}
		}
		if got := level(nil, tc.l); got != statusNone {
			t.Errorf("%s: level(nil) = %q, want none", tc.name, got)
		}
	}
	for x, want := range map[float64]status{0: statusOK, 0.01: statusBad, 3: statusBad} {
		if got := errorLevel(v(x)); got != want {
			t.Errorf("errorLevel(%v) = %q, want %q", x, got, want)
		}
	}
	if got := errorLevel(nil); got != statusNone {
		t.Errorf("errorLevel(nil) = %q, want none", got)
	}
	for _, tc := range []struct {
		apps, synced, healthy int
		want                  status
	}{{56, 56, 56, statusOK}, {56, 55, 56, statusWarn}, {56, 56, 55, statusWarn}} {
		if got := argoStatus(tc.apps, tc.synced, tc.healthy); got != tc.want {
			t.Errorf("argoStatus(%d, %d, %d) = %q, want %q", tc.apps, tc.synced, tc.healthy, got, tc.want)
		}
	}
	for s, want := range map[status]string{statusOK: "OK", statusWarn: "Warning", statusBad: "Critical", statusNone: "No data"} {
		if got := levelWord(s); got != want {
			t.Errorf("levelWord(%q) = %q, want %q", s, got, want)
		}
	}
}

// Each DORA band on its boundaries (design.md, "DORA bands").
func TestDORABands(t *testing.T) {
	for deploys, want := range map[int]band{0: bandLow, 1: bandMedium, 3: bandMedium, 4: bandHigh, 29: bandHigh, 30: bandElite, 700: bandElite} {
		if got := deployBand(deploys); got != want {
			t.Errorf("deployBand(%d) = %s, want %s", deploys, got, want)
		}
	}
	for _, tc := range []struct {
		d    time.Duration
		want band
	}{
		{day - time.Second, bandElite}, {day, bandHigh}, {week, bandHigh}, {week + time.Second, bandMedium},
		{month, bandMedium}, {month + time.Second, bandLow},
	} {
		if got := leadBand(tc.d); got != tc.want {
			t.Errorf("leadBand(%v) = %s, want %s", tc.d, got, tc.want)
		}
	}
	for _, tc := range []struct {
		d    time.Duration
		want band
	}{
		{time.Hour - time.Second, bandElite}, {time.Hour, bandHigh}, {day, bandHigh}, {day + time.Second, bandMedium},
		{week, bandMedium}, {week + time.Second, bandLow},
	} {
		if got := restoreBand(tc.d); got != tc.want {
			t.Errorf("restoreBand(%v) = %s, want %s", tc.d, got, tc.want)
		}
	}
	for rate, want := range map[float64]band{0: bandElite, 5: bandElite, 5.1: bandHigh, 10: bandHigh, 10.1: bandMedium, 15: bandMedium, 15.1: bandLow} {
		if got := failureBand(rate); got != want {
			t.Errorf("failureBand(%v) = %s, want %s", rate, got, want)
		}
	}
	for b, want := range map[band]status{bandElite: statusOK, bandHigh: statusOK, bandMedium: statusWarn, bandLow: statusBad} {
		if got := bandStatus(b); got != want {
			t.Errorf("bandStatus(%s) = %q, want %q", b, got, want)
		}
	}
	for _, tc := range []struct {
		bands []band
		want  band
	}{
		{[]band{bandElite, bandElite, bandElite, bandElite}, bandElite},
		{[]band{bandElite, bandHigh, bandElite, bandElite}, bandHigh},
		{[]band{bandHigh, bandMedium, bandElite, bandElite}, bandMedium},
		{[]band{bandElite, bandMedium, bandLow, bandHigh}, bandLow},
		{[]band{bandElite, "", bandElite, bandElite}, ""},
		{nil, ""},
	} {
		if got := overallBand(tc.bands); got != tc.want {
			t.Errorf("overallBand(%q) = %q, want %q", tc.bands, got, tc.want)
		}
	}
	zero, rate, lead := 0, 1.0, 3600
	p := snapshot.Project{Deploys30d: 40, ChangeFailureRate: &rate, Incidents30d: &zero}
	if _, bs := doraTiles(p); overallBand(bs) != "" {
		t.Errorf("doraTiles without a lead time: overall %q, want none", overallBand(bs))
	}
	p.LeadTimeSeconds = &lead
	if _, bs := doraTiles(p); overallBand(bs) != bandElite {
		t.Errorf("doraTiles with no incident: overall %q, want %q", overallBand(bs), bandElite)
	}
	for _, tc := range []struct {
		bands []band
		want  overall
	}{
		{[]band{bandElite, bandHigh, bandElite, bandElite}, overall{Status: statusOK, Word: "High"}},
		{[]band{bandElite, bandMedium, bandElite, bandElite}, overall{Status: statusWarn, Word: "Medium"}},
		{[]band{bandElite, bandLow, bandElite, bandElite}, overall{Status: statusBad, Word: "Low"}},
		{[]band{bandElite, "", bandElite, bandElite}, overall{Status: statusNone, Word: "No data", NoData: true}},
	} {
		if got := doraOverall(tc.bands); got != tc.want {
			t.Errorf("doraOverall(%q) = %+v, want %+v", tc.bands, got, tc.want)
		}
	}
	for result, want := range map[string][2]string{"success": {"ok", "Success"}, "failure": {"bad", "Failure"},
		"cancelled": {"none", "Cancelled"}, "other": {"warn", "Other"}} {
		if st, w := runStatus(result); string(st) != want[0] || w != want[1] {
			t.Errorf("runStatus(%q) = %q %q, want %q %q", result, st, w, want[0], want[1])
		}
	}
}

// testDays are the 30 dates of the fixture, ending on 20 November.
func testDays() []string {
	var ds []string
	for i := range snapshot.Days {
		ds = append(ds, snapshot.AddDays(time.Date(2026, 10, 22, 0, 0, 0, 0, snapshot.Zurich), i).Format(snapshot.DateLayout))
	}
	return ds
}

// fullDays are 30 days at 100%.
func fullDays() []*float64 {
	full := make([]*float64, snapshot.Days)
	for i := range full {
		x := 100.0
		full[i] = &x
	}
	return full
}

func TestCard(t *testing.T) {
	ds := testDays()
	v := func(x float64) *float64 { return &x }
	n := v
	full := fullDays()
	since := make([]*float64, snapshot.Days)
	since[27], since[28], since[29] = v(99), v(100), v(100)
	oneDay := make([]*float64, snapshot.Days)
	oneDay[29] = v(100)
	for _, tc := range []struct {
		name      string
		app       snapshot.LiveApp
		status    status
		word      string
		since     string
		exhausted bool
		meter     bool
		noData    bool
	}{
		{"met", snapshot.LiveApp{Availability30d: v(99.9), ErrorBudgetRemaining30d: n(80), AvailabilityDaily: full}, statusOK, "Met", "", false, true, false},
		{"budget at 0", snapshot.LiveApp{Availability30d: v(99.5), ErrorBudgetRemaining30d: n(0), AvailabilityDaily: full}, statusWarn, "At risk", "", true, true, false},
		{"missed", snapshot.LiveApp{Availability30d: v(99.1), ErrorBudgetRemaining30d: n(-62), AvailabilityDaily: full}, statusBad, "Missed", "", true, true, false},
		// Under 30 days: neutral whatever the figure and the budget.
		{"since, above the target", snapshot.LiveApp{Availability30d: v(99.6), ErrorBudgetRemaining30d: n(20), AvailabilityDaily: since}, statusNone, "", "18 November", false, false, false},
		{"since, below the target", snapshot.LiveApp{Availability30d: v(99.4), ErrorBudgetRemaining30d: n(-90), AvailabilityDaily: since}, statusNone, "", "18 November", false, false, false},
		{"since, today only", snapshot.LiveApp{Availability30d: v(100), ErrorBudgetRemaining30d: n(100), AvailabilityDaily: oneDay}, statusNone, "", "20 November", false, false, false},
		{"no budget", snapshot.LiveApp{Availability30d: v(99.9), AvailabilityDaily: full}, statusNone, "", "", false, false, false},
		{"no data", snapshot.LiveApp{AvailabilityDaily: full}, statusNone, "", "", false, false, true},
		{"no daily value", snapshot.LiveApp{Availability30d: v(100), AvailabilityDaily: make([]*float64, snapshot.Days)}, statusNone, "", "", false, false, true},
	} {
		c := card(tc.app, ds)
		if c.Status != tc.status || c.Word != tc.word || c.Since != tc.since || c.Exhausted != tc.exhausted || (c.Meter != "") != tc.meter || c.NoData != tc.noData {
			t.Errorf("%s: card = status %q word %q since %q exhausted %v meter %v no data %v, want %q %q %q %v %v %v",
				tc.name, c.Status, c.Word, c.Since, c.Exhausted, c.Meter != "", c.NoData,
				tc.status, tc.word, tc.since, tc.exhausted, tc.meter, tc.noData)
		}
	}
}

// TestSinceCardsAreNeutral renders the page with apps under 30 days of data
// and checks each such card: the figure in the neutral colour with "since
// <date>", no status word, no error budget.
func TestSinceCardsAreNeutral(t *testing.T) {
	body := page(t, fixture(t))
	sinceCards := 0
	for _, c := range strings.Split(body, `<div class="card">`)[1:] {
		c, _, _ = strings.Cut(c, `<div class="bars">`)
		if !strings.Contains(c, `<span class="label">since `) {
			continue
		}
		sinceCards++
		if !strings.Contains(c, `<span class="big none">`) {
			t.Errorf("a since card's figure is not neutral:\n%s", c)
		}
		for _, bad := range []string{`class="status`, `class="meter"`, "error budget", "Exhausted"} {
			if strings.Contains(c, bad) {
				t.Errorf("a since card contains %q:\n%s", bad, c)
			}
		}
	}
	if sinceCards == 0 {
		t.Fatal("the fixture has no app under 30 days of data")
	}
}

func TestFormats(t *testing.T) {
	for s, want := range map[int][]part{
		7:      {{"7", "s"}},
		59:     {{"59", "s"}},
		60:     {{"1", "min"}},
		305:    {{"5", "min"}, {"05", "s"}},
		2280:   {{"38", "min"}},
		7800:   {{"2", "h"}, {"10", "min"}},
		7230:   {{"2", "h"}},
		864000: {{"10", "d"}},
		97200:  {{"1", "d"}, {"3", "h"}},
	} {
		if diff := cmp.Diff(want, durationParts(s)); diff != "" {
			t.Errorf("durationParts(%d) mismatch (-want +got):\n%s", s, diff)
		}
	}
	for n, want := range map[int]string{0: "0", 999: "999", 1000: "1,000", 48127: "48,127", 1234567: "1,234,567", -1000: "-1,000"} {
		if got := thousands(n); got != want {
			t.Errorf("thousands(%d) = %q, want %q", n, got, want)
		}
	}
	for n, want := range map[int64]string{412316860416: "384 GiB", 1099511627776: "1.0 TiB", 1 << 20: "1 MiB"} {
		if got := bytesText(n); got != want {
			t.Errorf("bytesText(%d) = %q, want %q", n, got, want)
		}
	}
}

func TestBarHeight(t *testing.T) {
	for v, want := range map[float64]float64{100: 60, 99.5: 54, 97.5: 30, 95: barMin, 12: barMin} {
		if got := barHeight(v); math.Abs(got-want) > 1e-9 {
			t.Errorf("barHeight(%v) = %v, want %v", v, got, want)
		}
	}
}

var (
	chartClasses = map[string]bool{"ok": true, "warn": true, "bad": true, "none": true, "track": true, "target": true, "today": true, "spark": true}
	chartNumeric = regexp.MustCompile(`^-?[0-9]+(\.[0-9])?$`)
	chartViewBox = regexp.MustCompile(`^0 0 [0-9]+ [0-9]+$`)
	chartLabel   = regexp.MustCompile(`^[A-Za-z0-9 :%,.]+$`)
	chartTitle   = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}( \(today so far\))?: ([0-9]+\.[0-9]{2}%|No data)$`)
	sparkTitle   = regexp.MustCompile(`^[0-9]{1,2} [A-Z][a-z]{2} [0-9]{2}:[0-9]{2} to [0-9]{1,2} [A-Z][a-z]{2} [0-9]{2}:[0-9]{2}: ([0-9,]+|No data)$`)
)

func TestChartMarkup(t *testing.T) {
	v := func(x float64) *float64 { return &x }
	ds := days(t, fixture(t))
	mixed := make([]*float64, snapshot.Days)
	for i := range mixed {
		mixed[i] = v(100 - float64(i)*0.5)
	}
	mixed[3] = nil
	charts := map[string]template.HTML{
		"bars, empty":       dailyBars(ds, make([]*float64, snapshot.Days)),
		"bars, mixed":       dailyBars(ds, mixed),
		"meter -100":        budgetMeter(-100),
		"meter 0":           budgetMeter(0),
		"meter 25":          budgetMeter(25),
		"meter 100":         budgetMeter(100),
		"share 0":           shareBar("Opened by Renovate", 0),
		"share 61":          shareBar("Opened by Renovate", 61),
		"share 100":         shareBar("Opened by Renovate", 100),
		"use 0":             meter("CPU", 0, statusOK),
		"use 80.4":          meter("Memory", 80.4, statusWarn),
		"use 100":           meter("Disk", 100, statusBad),
		"bars, partial day": dailyBars(ds[27:], []*float64{nil, v(12.3456), v(99.95)}),
		"spark, mixed":      sparkBars(fixtureNow, sparkValues(1671, 0, 12345, -1)),
		"spark, zeros":      sparkBars(fixtureNow, sparkValues(0, 0, 0, 0)),
		"spark, no data":    sparkBars(fixtureNow, make([]*int, snapshot.Buckets)),
	}
	allowed := map[string]bool{"svg": true, "g": true, "rect": true, "line": true, "title": true}
	for name, chart := range charts {
		dec := xml.NewDecoder(strings.NewReader(string(chart)))
		var stack []string
		for {
			tok, err := dec.Token()
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				t.Fatalf("%s: not well-formed: %v", name, err)
			}
			switch el := tok.(type) {
			case xml.StartElement:
				stack = append(stack, el.Name.Local)
				if !allowed[el.Name.Local] {
					t.Errorf("%s: element <%s>", name, el.Name.Local)
				}
				for _, a := range el.Attr {
					checkChartAttr(t, name, a)
				}
			case xml.EndElement:
				stack = stack[:len(stack)-1]
			case xml.CharData:
				text := string(el)
				if len(stack) > 0 && stack[len(stack)-1] == "title" {
					if !chartTitle.MatchString(text) && (!strings.HasPrefix(name, "spark") || !sparkTitle.MatchString(text)) {
						t.Errorf("%s: title %q", name, text)
					}
				} else if strings.TrimSpace(text) != "" {
					t.Errorf("%s: text %q outside <title>", name, text)
				}
			}
		}
	}
	if got := string(dailyBars(ds, mixed)); !strings.Contains(got, `aria-label="30 days: 2 met, 5 at risk, 22 missed, 1 without data"`) {
		t.Errorf("dailyBars label: %s", got)
	}
}

// sparkValues repeats the values over the buckets; -1 is a bucket without
// data.
func sparkValues(values ...int) []*int {
	out := make([]*int, snapshot.Buckets)
	for i := range out {
		if v := values[i%len(values)]; v >= 0 {
			out[i] = &v
		}
	}
	return out
}

func TestSparkBars(t *testing.T) {
	got := string(sparkBars(fixtureNow, sparkValues(0, 10, 5, -1)))
	contains(t, got,
		`aria-label="28 counts of six hours, highest 10"`,
		`<rect class="spark" x="1.0" y="38.0" width="8.0" height="2.0"><title>13 Nov 17:00 to 13 Nov 23:00: 0</title></rect>`,
		`<rect class="spark" x="11.0" y="0.0" width="8.0" height="40.0"><title>13 Nov 23:00 to 14 Nov 05:00: 10</title></rect>`,
		`<rect class="spark" x="21.0" y="20.0" width="8.0" height="20.0">`,
		`<rect class="none" x="31.0" y="38.0" width="8.0" height="2.0"><title>14 Nov 11:00 to 14 Nov 17:00: No data</title></rect>`,
		`<title>20 Nov 11:00 to 20 Nov 17:00: No data</title>`,
	)
	if n := strings.Count(string(sparkBars(fixtureNow, sparkValues(0))), `height="2.0"`); n != snapshot.Buckets {
		t.Errorf("all zeros: %d bars at the minimum height, want %d", n, snapshot.Buckets)
	}
}

// Both rules of the security signals on each boundary (Requirement 12.4).
func TestSecurityRules(t *testing.T) {
	n := func(x int) *int { return &x }
	for _, tc := range []struct {
		zero      bool
		day, week *int
		st        status
		word      string
	}{
		{true, n(0), n(0), statusOK, "None"},
		{true, n(0), n(5), statusOK, "None"},
		{true, n(1), n(1), statusWarn, "Seen"},
		{true, nil, nil, statusNone, "No data"},
		// Background: above 20 and above 3 times the mean of the 6 days
		// before, (week - day) / 6.
		{false, n(20), n(20), statusOK, "Usual"},
		{false, n(21), n(21), statusWarn, "Above usual"},
		{false, n(30), n(90), statusOK, "Usual"},         // 3 x 10 = 30: not above
		{false, n(30), n(89), statusWarn, "Above usual"}, // 3 x 9.83
		{false, n(30), n(91), statusOK, "Usual"},         // 3 x 10.17
		{false, n(8044), n(48127), statusOK, "Usual"},    // 3 x 6680
		{false, n(25), nil, statusWarn, "Above usual"},   // no week: a mean of 0
		{false, nil, n(10), statusNone, "No data"},
	} {
		if st, w := signalStatus(tc.zero, tc.day, tc.week); st != tc.st || w != tc.word {
			t.Errorf("signalStatus(%v, %v, %v) = %q %q, want %q %q", tc.zero, tc.day, tc.week, st, w, tc.st, tc.word)
		}
	}
}

func checkChartAttr(t *testing.T, name string, a xml.Attr) {
	t.Helper()
	switch a.Name.Local {
	case "class":
		for _, c := range strings.Fields(a.Value) {
			if !chartClasses[c] {
				t.Errorf("%s: class %q", name, a.Value)
			}
		}
	case "role":
		if a.Value != "img" {
			t.Errorf("%s: role %q", name, a.Value)
		}
	case "focusable":
		if a.Value != "false" {
			t.Errorf("%s: focusable %q", name, a.Value)
		}
	case "preserveAspectRatio":
		if a.Value != "none" {
			t.Errorf("%s: preserveAspectRatio %q", name, a.Value)
		}
	case "aria-label":
		if !chartLabel.MatchString(a.Value) {
			t.Errorf("%s: aria-label %q", name, a.Value)
		}
	case "viewBox":
		if !chartViewBox.MatchString(a.Value) {
			t.Errorf("%s: viewBox %q", name, a.Value)
		}
	default:
		if !chartNumeric.MatchString(a.Value) {
			t.Errorf("%s: %s=%q is not a number", name, a.Name.Local, a.Value)
		}
	}
}

// luminance is the WCAG relative luminance of #rrggbb.
func luminance(t *testing.T, hex string) float64 {
	t.Helper()
	var l float64
	for i, w := range []float64{0.2126, 0.7152, 0.0722} {
		c, err := strconv.ParseUint(hex[1+2*i:3+2*i], 16, 8)
		if err != nil {
			t.Fatalf("colour %q: %v", hex, err)
		}
		s := float64(c) / 255
		if s <= 0.04045 {
			s /= 12.92
		} else {
			s = math.Pow((s+0.055)/1.055, 2.4)
		}
		l += w * s
	}
	return l
}

func TestContrast(t *testing.T) {
	b, err := os.ReadFile("assets/dashboard.css")
	if err != nil {
		t.Fatal(err)
	}
	vars := map[string]string{}
	for _, m := range regexp.MustCompile(`--([a-z-]+):\s*(#[0-9a-f]{6});`).FindAllStringSubmatch(string(b), -1) {
		vars[m[1]] = m[2]
	}
	// Every text and status colour on the card and on the stat tile
	// (Requirement 3.13).
	for _, bgName := range []string{"panel", "tile"} {
		back, ok := vars[bgName]
		if !ok {
			t.Fatalf("no --%s in dashboard.css", bgName)
		}
		bg := luminance(t, back)
		for _, name := range []string{"fg", "muted", "link", "ok", "warn", "bad", "none"} {
			c, ok := vars[name]
			if !ok {
				t.Errorf("no --%s in dashboard.css", name)
				continue
			}
			fg := luminance(t, c)
			ratio := (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
			if ratio < 4.5 {
				t.Errorf("--%s %s on --%s %s: contrast %.2f, want at least 4.5", name, c, bgName, back, ratio)
			}
		}
	}
}
