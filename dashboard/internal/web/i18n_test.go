package web

import (
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// noData is the English word of a figure without data.
var noData = english.t("status.nodata")

// TestCatalogue: both languages have the same keys, no value is empty, the
// %s of a key match, French holds no em dash and no "bot", and every shown
// app and signal has its name (Requirement 4.9).
func TestCatalogue(t *testing.T) {
	en, fr := catalogues["en"], catalogues["fr"]
	if len(catalogues) != 2 {
		t.Errorf("%d catalogues, want en and fr", len(catalogues))
	}
	bot := regexp.MustCompile(`(?i)\bbots?\b`)
	for _, pair := range [][2]catalogue{{en, fr}, {fr, en}} {
		for k := range pair[0] {
			if _, ok := pair[1][k]; !ok {
				t.Errorf("key %q is in one language only", k)
			}
		}
	}
	for code, c := range catalogues {
		for k, v := range c {
			switch {
			case strings.TrimSpace(v) == "":
				t.Errorf("%s %q is empty", code, k)
			case strings.ContainsRune(v, '\u2014'):
				t.Errorf("%s %q holds an em dash", code, k)
			case bot.MatchString(v):
				t.Errorf("%s %q says bot: %q", code, k, v)
			case strings.Count(v, "%s") != strings.Count(en[k], "%s"):
				t.Errorf("%s %q has %d %%s, English %d", code, k, strings.Count(v, "%s"), strings.Count(en[k], "%s"))
			}
		}
	}
	for _, a := range snapshot.Shown() {
		if got := en["app."+a.ID]; got != a.Name {
			t.Errorf("app.%s = %q, want the compiled name %q", a.ID, got, a.Name)
		}
	}
	for _, s := range snapshot.ShownSignals() {
		if got := en["signal."+s.ID]; got != s.Name {
			t.Errorf("signal.%s = %q, want the compiled name %q", s.ID, got, s.Name)
		}
		if got := en["signal."+s.ID+".note"]; got != s.Note {
			t.Errorf("signal.%s.note = %q, want the compiled note %q", s.ID, got, s.Note)
		}
		if _, ok := en["noun."+s.TotalNoun]; s.TotalNoun != "" && !ok {
			t.Errorf("no noun.%s for signal %s", s.TotalNoun, s.ID)
		}
	}
	// Every key the code and the templates name, and the ones they build.
	used := []string{"title.notfound", "unit.d", "unit.h", "unit.min", "unit.s"}
	for _, b := range []band{bandElite, bandHigh, bandMedium, bandLow} {
		used = append(used, "band."+strings.ToLower(string(b)))
	}
	files, err := filepath.Glob("templates/*.html")
	if err != nil {
		t.Fatal(err)
	}
	key := regexp.MustCompile(`"([a-z0-9]+(?:\.[a-z0-9_-]+)+)"`)
	for _, f := range append(files, "render.go", "status.go", "chart.go") {
		b, err := os.ReadFile(f) //nolint:gosec // G304: a source file of this package.
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range key.FindAllStringSubmatch(string(b), -1) {
			used = append(used, m[1])
		}
	}
	for _, k := range used {
		if _, ok := en[k]; !ok {
			t.Errorf("key %q is used but not in the catalogue", k)
		}
	}
	for _, img := range snapshot.ShownImages() {
		if got := english.f("image.builder", img.Workflow); got != img.Builder() {
			t.Errorf("image.builder for %s = %q, want %q", img.Name, got, img.Builder())
		}
	}
}

// French numbers and dates follow fr-CH: a decimal comma, U+202F between
// digit groups and before % and units (Requirement 4.9).
func TestFrenchFormats(t *testing.T) {
	for v, want := range map[float64]string{99.957: "99,96\u202f%", 0.125: "0,12\u202f%", 100: "100,00\u202f%"} {
		if got := french.percent(v); got != want {
			t.Errorf("percent(%v) = %q, want %q", v, got, want)
		}
	}
	for n, want := range map[int]string{999: "999", 48127: "48\u202f127", 1234567: "1\u202f234\u202f567", -1000: "-1\u202f000"} {
		if got := french.thousands(n); got != want {
			t.Errorf("thousands(%d) = %q, want %q", n, got, want)
		}
	}
	for n, want := range map[int64]string{412316860416: "384\u202fGio", 1099511627776: "1,0\u202fTio"} {
		if got := french.bytesText(n); got != want {
			t.Errorf("bytesText(%d) = %q, want %q", n, got, want)
		}
	}
	at := time.Date(2026, 11, 25, 14, 5, 0, 0, snapshot.Zurich)
	first := time.Date(2026, 12, 1, 9, 0, 0, 0, snapshot.Zurich)
	for got, want := range map[string]string{
		french.timeText(at):    "25 novembre 2026, 14:05",
		french.timeText(first): "1er décembre 2026, 09:00",
		french.shortTime(at):   "25 nov. 14:05",
		french.dayMonth(at):    "25 novembre",
		english.timeText(at):   "25 November 2026, 14:05",
	} {
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	}
	if diff := cmp.Diff([]part{{"1", "\u202fj"}, {"3", "\u202fh"}}, french.durationParts(97200)); diff != "" {
		t.Errorf("durationParts mismatch (-want +got):\n%s", diff)
	}
	for n, want := range map[int]string{0: "unit.day", 1: "unit.day", -1: "unit.day", 2: "unit.days"} {
		if got := french.plural(n, "unit.day", "unit.days"); got != want {
			t.Errorf("plural(%d) = %q, want %q", n, got, want)
		}
	}
}

// /fr/ is the page in French, / in English, each with the toggle to the
// other, the three hreflang links and a canonical to itself
// (Requirements 4.1-4.5, acceptance criterion 7).
func TestLanguages(t *testing.T) {
	h := newHarness(t)
	if code := h.pushDoc(t, fullDaily(t)); code != http.StatusNoContent {
		t.Fatalf("push = %d", code)
	}
	hreflang := `<link rel="alternate" hreflang="en" href="https://homelab.nedsi.io/">
<link rel="alternate" hreflang="fr" href="https://homelab.nedsi.io/fr/">
<link rel="alternate" hreflang="x-default" href="https://homelab.nedsi.io/">`
	for _, tc := range []struct {
		path string
		want []string
		not  []string
	}{
		{"/", []string{
			`<html lang="en-GB">`, hreflang,
			`<link rel="canonical" href="https://homelab.nedsi.io/">`,
			`<a class="lang" href="https://homelab.nedsi.io/fr/" hreflang="fr" lang="fr-CH" aria-label="Français">FR</a>`,
			`<a href="/" aria-current="page">Homelab</a>`,
			`href="/set-theme/light/"`,
			`<h2 id="availability">Availability</h2>`,
		}, []string{"\u202f", "lang=\"en-GB\">Found"}},
		{"/fr/", []string{
			`<html lang="fr-CH">`, hreflang,
			`<link rel="canonical" href="https://homelab.nedsi.io/fr/">`,
			`<a class="lang" href="https://homelab.nedsi.io/" hreflang="en" lang="en-GB" aria-label="English">EN</a>`,
			`<a href="https://nedsi.io/fr/">Accueil</a>`,
			`<a href="/fr/" aria-current="page">Homelab</a>`,
			`<a href="https://blog.nedsi.io/fr/about/">À propos</a>`,
			`href="/set-theme/light/fr/"`, `title="Thème clair, mémorisé dans un cookie"`,
			`<link rel="alternate" type="application/rss+xml" href="https://blog.nedsi.io/fr/index.xml" title="nedsi">`,
			`<h2 id="availability">Disponibilité</h2>`,
			`<h2 id="supply-chain">Chaîne d’approvisionnement</h2>`,
			`<span class="big ok">99,96<span class="unit">` + "\u202f" + `%</span></span> <span class="status ok">Atteint</span>`,
			`<p class="tile-value ok">709<span class="unit">` + "\u202f" + `déploiements</span> <span class="status ok">Élite</span></p>`,
			`<p class="tile-detail" lang="en-GB">Found 0/28 approved changesets -- score normalized to 0</p>`,
			`<p class="tile-detail">24 h glissantes, 7,01` + "\u202f" + `% de 62` + "\u202f" + `940 requêtes</p>`,
			`Mis à jour le <time datetime="2026-11-20T17:00:00&#43;01:00">20 novembre 2026, 17:00</time> (heure de Zurich).`,
			`<a href="https://blog.nedsi.io/fr/privacy/">Confidentialité</a>`,
		}, []string{"Availability", "No data", "Met<", "&#39;"}},
	} {
		body := h.get(t, http.MethodGet, tc.path).Body.String()
		for _, w := range tc.want {
			if !strings.Contains(body, w) {
				t.Errorf("%s lacks %q", tc.path, w)
			}
		}
		for _, n := range tc.not {
			if strings.Contains(body, n) {
				t.Errorf("%s contains %q", tc.path, n)
			}
		}
	}
	rec := h.get(t, http.MethodGet, "/fr")
	if rec.Code != http.StatusMovedPermanently || rec.Header().Get("Location") != "/fr/" {
		t.Errorf("GET /fr = %d to %q, want 301 to /fr/", rec.Code, rec.Header().Get("Location"))
	}
	for path, want := range map[string]string{"/fr/nope": `<html lang="fr-CH">`, "/nope": `<html lang="en-GB">`, "/fr/snapshot.json": "Page introuvable"} {
		rec := h.get(t, http.MethodGet, path)
		body := rec.Body.String()
		if rec.Code != http.StatusNotFound || !strings.Contains(body, want) || strings.Contains(body, "hreflang=\"x-default\"") {
			t.Errorf("GET %s = %d, want 404 with %q and no hreflang links", path, rec.Code, want)
		}
	}
	if h.get(t, http.MethodGet, "/fr/").Header().Get("Cache-Control") != "no-cache" {
		t.Error("/fr/ is not no-cache like /")
	}
}

// The French charts keep to the chart builders' safe text: no markup
// character in a label or title.
func TestFrenchChartText(t *testing.T) {
	v := func(x float64) *float64 { return &x }
	ds := days(t, fixture(t))
	text := regexp.MustCompile(`(?:aria-label="|<title>)([^"<]*)`)
	for _, chart := range []string{
		string(dailyBars(french, ds, []*float64{nil, v(99.95)})),
		string(budgetMeter(french, 25)), string(budgetMeter(french, 0)),
		string(meter(french, "Mémoire", 80.4, statusWarn)),
		string(sparkBars(french, fixtureNow, sparkValues(1671, -1))),
	} {
		ms := text.FindAllStringSubmatch(chart, -1)
		if len(ms) == 0 {
			t.Errorf("no label in %s", chart)
		}
		for _, m := range ms {
			if strings.ContainsAny(m[1], `<>&"`) {
				t.Errorf("chart text %q holds a markup character", m[1])
			}
		}
	}
	contains(t, string(dailyBars(french, ds[28:], []*float64{nil, v(99.95)})),
		`aria-label="2 jours`+"\u00a0"+`: 1 atteints, 1 sans données"`,
		`<title>2026-11-20 (journée en cours)`+"\u00a0"+`: 99,95`+"\u202f"+`%</title>`)
	if got := string(sparkBars(french, fixtureNow, sparkValues(0))); !strings.Contains(got, `<title>Du 13 nov. 17:00 au 13 nov. 23:00`+"\u00a0"+`: 0</title>`) {
		t.Errorf("sparkBars title: %s", got)
	}
}
