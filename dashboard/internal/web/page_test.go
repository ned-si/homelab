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

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

func apps(doc map[string]any) []map[string]any {
	var out []map[string]any
	for _, a := range doc["daily"].(map[string]any)["apps"].([]any) {
		out = append(out, a.(map[string]any))
	}
	return out
}

// fullDaily has 30 days for every app, so every card has a budget, and one
// day without probes, so the page has every status: Blog ok, Immich warn,
// Paperless bad, a Jellyfin day none.
func fullDaily(t *testing.T) map[string]any {
	t.Helper()
	doc := fixture(t)
	for _, a := range apps(doc) {
		days := a["availability_daily"].([]any)
		for i := range days {
			if days[i] == nil {
				days[i] = 100.0
			}
		}
		if a["id"] == "jellyfin" {
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
		a["error_budget_remaining_30d"] = -100
		a["availability_30d"] = 98.0
		if i == 0 {
			a["error_budget_remaining_30d"] = 0
			a["availability_30d"] = 99.5
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
		{"exhausted", exhausted, fixtureNow},
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

// Acceptance criterion 6: one card per shown app, and every status class
// next to its word.
func TestFullPageCardsAndStatuses(t *testing.T) {
	h := newHarness(t)
	if code := h.pushDoc(t, fullDaily(t)); code != http.StatusNoContent {
		t.Fatalf("push = %d", code)
	}
	body := h.get(t, http.MethodGet, "/").Body.String()
	if got, want := strings.Count(body, `<div class="card">`), len(snapshot.Shown()); got != want {
		t.Errorf("%d cards, want %d (one per shown app)", got, want)
	}
	for _, s := range snapshot.Shown() {
		if !strings.Contains(body, "<h3>"+template.HTMLEscapeString(s.Name)+"</h3>") {
			t.Errorf("no card for %s", s.Name)
		}
	}
	for _, want := range []string{
		`<span class="status ok">Met</span>`,
		`<span class="status warn">At risk</span>`,
		`<span class="status bad">Missed</span>`,
		`class="none"`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("the page lacks %q", want)
		}
	}
	if !regexp.MustCompile(`<rect class="none"[^>]*><title>2026-10-31: No data</title>`).MatchString(body) {
		t.Error("the day without probes has no none bar titled No data")
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
			"Target: 99.5% availability over 30 days per app.",
			`Updated <time datetime="2026-11-20T17:00:00&#43;01:00">20 November 2026, 17:00</time> (Zurich time).`,
			`<span class="label">since 16 November</span>`,
			"11% of the error budget left",
			"<p class=\"meta\">Exhausted</p>",
			`5<span class="unit">min</span> 05<span class="unit">s</span>`,
			`709<span class="unit">PRs</span>`,
			`aria-label="Opened by Renovate: 50%"`,
			`As of <time datetime="2026-11-20T16:52:00&#43;01:00">20 November 2026, 16:52</time>.`,
			"Solar production", "Home automation",
		}, []string{"Live figures from", "daily update is failing", "No figures yet", "/tags/"}},
		{fixtureNow.Add(6 * time.Minute), []string{"Live figures from <time datetime=\"2026-11-20T17:00:00&#43;01:00\">20 November 2026, 17:00</time>"}, nil},
		{fixtureNow.Add(3 * 24 * time.Hour), []string{"Availability figures are from <time datetime=\"2026-11-19\">19 November 2026</time>: the daily update is failing."}, nil},
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

func TestStatusRules(t *testing.T) {
	for _, tc := range []struct {
		left int
		want status
	}{{100, statusOK}, {26, statusOK}, {25, statusWarn}, {1, statusWarn}, {0, statusWarn}, {-1, statusBad}, {-100, statusBad}} {
		if got := monthStatus(tc.left); got != tc.want {
			t.Errorf("monthStatus(%d) = %q, want %q", tc.left, got, tc.want)
		}
	}
	v := func(x float64) *float64 { return &x }
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
}

func TestCard(t *testing.T) {
	covers := time.Date(2026, 11, 19, 0, 0, 0, 0, snapshot.Zurich)
	v := func(x float64) *float64 { return &x }
	full := make([]*float64, snapshot.Days)
	for i := range full {
		full[i] = v(100)
	}
	since := make([]*float64, snapshot.Days)
	since[27], since[28], since[29] = v(99), v(100), v(100)
	oneDay := make([]*float64, snapshot.Days)
	oneDay[29] = v(100)
	for _, tc := range []struct {
		name      string
		app       snapshot.App
		status    status
		word      string
		since     string
		exhausted bool
		meter     bool
		noData    bool
	}{
		{"met", snapshot.App{Availability30d: 99.9, ErrorBudgetRemaining30d: 80, AvailabilityDaily: full}, statusOK, "Met", "", false, true, false},
		{"budget at 0", snapshot.App{Availability30d: 99.5, ErrorBudgetRemaining30d: 0, AvailabilityDaily: full}, statusWarn, "At risk", "", true, true, false},
		{"missed", snapshot.App{Availability30d: 99.1, ErrorBudgetRemaining30d: -62, AvailabilityDaily: full}, statusBad, "Missed", "", true, true, false},
		// Under 30 days: neutral whatever the figure and the budget.
		{"since, above the target", snapshot.App{Availability30d: 99.6, ErrorBudgetRemaining30d: 20, AvailabilityDaily: since}, statusNone, "", "17 November", false, false, false},
		{"since, below the target", snapshot.App{Availability30d: 99.4, ErrorBudgetRemaining30d: -90, AvailabilityDaily: since}, statusNone, "", "17 November", false, false, false},
		{"since, one day", snapshot.App{Availability30d: 100, ErrorBudgetRemaining30d: 100, AvailabilityDaily: oneDay}, statusNone, "", "19 November", false, false, false},
		{"no data", snapshot.App{Availability30d: 100, AvailabilityDaily: make([]*float64, snapshot.Days)}, statusNone, "", "", false, false, true},
	} {
		c := card(tc.app, covers)
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
	h := newHarness(t)
	if code := h.pushDoc(t, fixture(t)); code != http.StatusNoContent {
		t.Fatalf("push = %d", code)
	}
	body := h.get(t, http.MethodGet, "/").Body.String()
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

func TestMedian(t *testing.T) {
	for s, want := range map[int]ciMedian{59: {0, "59"}, 60: {1, "00"}, 305: {5, "05"}, 7: {0, "7"}} {
		if got := median(s); got != want {
			t.Errorf("median(%d) = %+v, want %+v", s, got, want)
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
	chartClasses = map[string]bool{"ok": true, "warn": true, "bad": true, "none": true, "track": true, "target": true}
	chartNumeric = regexp.MustCompile(`^-?[0-9]+(\.[0-9])?$`)
	chartViewBox = regexp.MustCompile(`^0 0 [0-9]+ [0-9]+$`)
	chartLabel   = regexp.MustCompile(`^[A-Za-z0-9 :%,.]+$`)
	chartTitle   = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}: ([0-9]+\.[0-9]%|No data)$`)
)

func TestChartMarkup(t *testing.T) {
	v := func(x float64) *float64 { return &x }
	covers := time.Date(2026, 11, 19, 0, 0, 0, 0, snapshot.Zurich)
	mixed := make([]*float64, snapshot.Days)
	for i := range mixed {
		mixed[i] = v(100 - float64(i)*0.5)
	}
	mixed[3] = nil
	charts := map[string]template.HTML{
		"bars, empty":       dailyBars(covers, make([]*float64, snapshot.Days)),
		"bars, mixed":       dailyBars(covers, mixed),
		"meter -100":        budgetMeter(-100),
		"meter 0":           budgetMeter(0),
		"meter 25":          budgetMeter(25),
		"meter 100":         budgetMeter(100),
		"share 0":           shareBar("Opened by Renovate", 0),
		"share 61":          shareBar("Opened by Renovate", 61),
		"share 100":         shareBar("Opened by Renovate", 100),
		"bars, partial day": dailyBars(covers, []*float64{nil, v(12.3456), v(99.95)}),
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
					if !chartTitle.MatchString(text) {
						t.Errorf("%s: title %q", name, text)
					}
				} else if strings.TrimSpace(text) != "" {
					t.Errorf("%s: text %q outside <title>", name, text)
				}
			}
		}
	}
	if got := string(dailyBars(covers, mixed)); !strings.Contains(got, `aria-label="30 days: 2 met, 5 at risk, 22 missed, 1 without data"`) {
		t.Errorf("dailyBars label: %s", got)
	}
}

func checkChartAttr(t *testing.T, name string, a xml.Attr) {
	t.Helper()
	switch a.Name.Local {
	case "class":
		if !chartClasses[a.Value] {
			t.Errorf("%s: class %q", name, a.Value)
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
	panel, ok := vars["panel"]
	if !ok {
		t.Fatal("no --panel in dashboard.css")
	}
	bg := luminance(t, panel)
	for _, name := range []string{"fg", "muted", "link", "ok", "warn", "bad", "none"} {
		c, ok := vars[name]
		if !ok {
			t.Errorf("no --%s in dashboard.css", name)
			continue
		}
		fg := luminance(t, c)
		ratio := (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
		if ratio < 4.5 {
			t.Errorf("--%s %s on --panel %s: contrast %.2f, want at least 4.5", name, c, panel, ratio)
		}
	}
}
