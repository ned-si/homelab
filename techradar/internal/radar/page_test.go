package radar

import (
	"encoding/xml"
	"errors"
	"flag"
	"io"
	"math"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"
)

var update = flag.Bool("update", false, "rewrite the golden files")

const fixture = clean + `  - name: Kyverno
    quadrant: platform
    ring: adopt
    reason: Baseline policies in Deny.
    reason_fr: Les policies de base en Deny.
    moved: up
  - name: Tetragon
    quadrant: platform
    ring: trial
    reason: Runtime detection that pages on critical events.
    reason_fr: Détection à l'exécution qui alerte sur les événements critiques.
    moved: down
`

func TestPageGolden(t *testing.T) {
	r, err := Parse([]byte(fixture), repo)
	if err != nil {
		t.Fatal(err)
	}
	files, err := Render(r, repo)
	if err != nil {
		t.Fatal(err)
	}
	for file, golden := range map[string]string{"index.html": "testdata/index.golden.html", "index-fr.html": "testdata/index-fr.golden.html"} {
		if *update {
			if err := os.WriteFile(golden, files[file], 0o600); err != nil {
				t.Fatal(err)
			}
		}
		want, err := os.ReadFile(golden) //nolint:gosec // G304: a golden file under testdata/.
		if err != nil {
			t.Fatal(err)
		}
		if diff := cmp.Diff(string(want), string(files[file])); diff != "" {
			t.Errorf("%s differs from %s (-want +got); go test -update rewrites it:\n%s", file, golden, diff)
		}
	}
	again, err := Render(r, repo)
	if err != nil {
		t.Fatal(err)
	}
	if diff := cmp.Diff(files, again); diff != "" {
		t.Errorf("two renders differ:\n%s", diff)
	}
}

func TestLegendMatchesEntries(t *testing.T) {
	root, err := RepoFS("../../..")
	if err != nil {
		t.Fatal(err)
	}
	r := &Radar{Entries: realEntries(t)}
	files, err := Render(r, root)
	if err != nil {
		t.Fatal(err)
	}
	page := string(files["index.html"])
	items := regexp.MustCompile(`<li value="(\d+)" id="entry-[a-z0-9-]+">(?:<a href="[^"]*">)?([^<]*)`).FindAllStringSubmatch(page, -1)
	if len(items) != len(r.Entries) {
		t.Fatalf("legend has %d items, entries.yaml %d", len(items), len(r.Entries))
	}
	titles := regexp.MustCompile(`<title>(\d+)\. ([^<]*) \(`).FindAllStringSubmatch(page, -1)
	if len(titles) != len(r.Entries) {
		t.Fatalf("chart has %d blips, entries.yaml %d", len(titles), len(r.Entries))
	}
	for i, e := range r.Entries {
		n := strconv.Itoa(i + 1)
		name := htmlText(e.Name)
		if items[i][1] != n || items[i][2] != name {
			t.Errorf("legend item %d is %s. %s, want %s. %s", i+1, items[i][1], items[i][2], n, name)
		}
		if titles[i][1] != n || titles[i][2] != name {
			t.Errorf("blip %d is %s. %s, want %s. %s", i+1, titles[i][1], titles[i][2], n, name)
		}
	}
}

// TestBlipLinks holds every point of the chart, on the golden fixture and on
// entries.yaml, to a native tooltip with the name, quadrant, ring and reason,
// and a link to an anchor of the legend, one point per legend item.
func TestBlipLinks(t *testing.T) {
	root, err := RepoFS("../../..")
	if err != nil {
		t.Fatal(err)
	}
	fixed, err := Parse([]byte(fixture), repo)
	if err != nil {
		t.Fatal(err)
	}
	blip := regexp.MustCompile(`<a class="blip ring-[a-z]+" href="#(entry-[a-z0-9-]+)"><title>([^<]*)</title>`)
	for src, r := range map[string]*Radar{"fixture": fixed, "entries.yaml": {Entries: realEntries(t)}} {
		files, err := Render(r, root)
		if err != nil {
			t.Fatal(err)
		}
		page := string(files["index.html"])
		ids := map[string]int{}
		for _, m := range regexp.MustCompile(`<li value="\d+" id="([^"]+)"`).FindAllStringSubmatch(page, -1) {
			ids[m[1]]++
		}
		blips := blip.FindAllStringSubmatch(page, -1)
		if len(blips) != len(r.Entries) || strings.Count(page, `<a class="blip `) != len(r.Entries) {
			t.Fatalf("%s: %d linked blips with a <title>, entries %d", src, len(blips), len(r.Entries))
		}
		for i, e := range r.Entries {
			id, title := blips[i][1], blips[i][2]
			if ids[id] != 1 {
				t.Errorf("%s: blip %d links #%s, %d legend items with that id", src, i+1, id, ids[id])
			}
			want := htmlText(strconv.Itoa(i+1) + ". " + e.Name + " (" + name(Quadrants, e.Quadrant) + ", " + name(Rings, e.Ring) + "): " + e.Reason)
			if title != want {
				t.Errorf("%s: blip %d title %q, want %q", src, i+1, title, want)
			}
		}
	}
}

func htmlText(s string) string {
	return strings.NewReplacer("&", "&amp;", "'", "&#39;", "<", "&lt;", ">", "&gt;", `"`, "&#34;").Replace(s)
}

// TestSVGMarkup holds the chart to the elements, attributes and classes of
// the design, so it needs no inline style and no script.
func TestSVGMarkup(t *testing.T) {
	r, err := Parse([]byte(fixture), repo)
	if err != nil {
		t.Fatal(err)
	}
	blips, err := Place(append(r.Entries, realEntries(t)...))
	if err != nil {
		t.Fatal(err)
	}
	elements := map[string]bool{"svg": true, "a": true, "g": true, "circle": true, "path": true, "line": true, "text": true, "title": true}
	classes := map[string]bool{"ring-adopt": true, "ring-trial": true, "ring-assess": true, "ring-hold": true, "axis": true, "ring-line": true, "ring-name": true, "blip": true, "blip-number": true, "blip-label": true, "blip-label-start": true, "blip-label-end": true}
	numeric := regexp.MustCompile(`^-?[0-9]+(\.[0-9]+)?$`)
	pathData := regexp.MustCompile(`^M[0-9. L]+ Z$`)
	dec := xml.NewDecoder(strings.NewReader(SVG(blips, Langs[1])))
	for {
		tok, err := dec.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		el, ok := tok.(xml.StartElement)
		if !ok {
			continue
		}
		if !elements[el.Name.Local] {
			t.Errorf("element <%s>", el.Name.Local)
		}
		for _, a := range el.Attr {
			v := a.Value
			switch a.Name.Local {
			case "class":
				for c := range strings.FieldsSeq(v) {
					if !classes[c] {
						t.Errorf("class %q on <%s>", c, el.Name.Local)
					}
				}
			case "role":
				if v != "group" {
					t.Errorf("role=%q", v)
				}
			case "focusable":
				if v != "false" {
					t.Errorf("focusable=%q", v)
				}
			case "aria-label":
			case "aria-hidden":
				if v != "true" {
					t.Errorf("aria-hidden=%q", v)
				}
			case "href":
				if !regexp.MustCompile(`^#entry-[a-z0-9-]+$`).MatchString(v) {
					t.Errorf("href=%q", v)
				}
			case "viewBox":
				if v != "0 0 800 800" {
					t.Errorf("viewBox=%q", v)
				}
			case "d":
				if !pathData.MatchString(v) {
					t.Errorf("d=%q", v)
				}
			case "cx", "cy", "r", "x", "y", "x1", "y1", "x2", "y2":
				if !numeric.MatchString(v) {
					t.Errorf("%s=%q", a.Name.Local, v)
				}
			default:
				t.Errorf("attribute %s on <%s>", a.Name.Local, el.Name.Local)
			}
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

// TestContrast checks the radar's colours in both palettes, byte copies of
// site/assets/css/theme-*.css: text and the ring colours 4.5:1 on --bg, the
// ring lines 3:1, the blip numbers 4.5:1 on each ring colour (WCAG 2.2 1.4.3
// and 1.4.11). techradar.css holds no colour.
func TestContrast(t *testing.T) {
	rings := []string{"ring-adopt", "ring-trial", "ring-assess", "ring-hold"}
	vars := regexp.MustCompile(`--([a-z-]+):\s*(#[0-9a-f]{6});`)
	for _, theme := range []string{"dark", "light"} {
		b, err := os.ReadFile("assets/theme-" + theme + ".css") //nolint:gosec // G304: a palette under assets/.
		if err != nil {
			t.Fatal(err)
		}
		colours := map[string]string{}
		for _, m := range vars.FindAllStringSubmatch(string(b), -1) {
			colours[m[1]] = m[2]
		}
		check := func(fg, bg string, want float64) {
			f, okF := colours[fg]
			g, okG := colours[bg]
			if !okF || !okG {
				t.Errorf("%s: no --%s or --%s", theme, fg, bg)
				return
			}
			lf, lg := luminance(t, f), luminance(t, g)
			if ratio := (max(lf, lg) + 0.05) / (min(lf, lg) + 0.05); ratio < want {
				t.Errorf("%s: --%s %s on --%s %s: contrast %.2f, want at least %.1f", theme, fg, f, bg, g, ratio, want)
			}
		}
		for _, name := range append([]string{"fg", "muted", "link"}, rings...) {
			check(name, "bg", 4.5)
		}
		check("radar-line", "bg", 3)
		for _, ring := range rings {
			check("blip-text", ring, 4.5)
		}
	}
	css, err := os.ReadFile("assets/techradar.css")
	if err != nil {
		t.Fatal(err)
	}
	if m := regexp.MustCompile(`#[0-9a-fA-F]{3,8}\b`).Find(css); m != nil {
		t.Errorf("techradar.css holds the colour %s; colours live in the palette", m)
	}
}

// TestCatalogue holds both languages to the same keys, no empty string, no
// em dash and no "bot" (site-theme-language Requirement 4.9).
func TestCatalogue(t *testing.T) {
	bot := regexp.MustCompile(`(?i)\bro?bots?\b`)
	for key := range catalogue["en"] {
		if _, ok := catalogue["fr"][key]; !ok {
			t.Errorf("fr: no %q", key)
		}
	}
	for code, strs := range catalogue {
		for key, s := range strs {
			if _, ok := catalogue["en"][key]; !ok {
				t.Errorf("en: no %q (in %s)", key, code)
			}
			switch {
			case strings.TrimSpace(s) == "":
				t.Errorf("%s %q: empty", code, key)
			case strings.ContainsRune(s, '\u2014'):
				t.Errorf("%s %q: em dash", code, key)
			case bot.MatchString(s):
				t.Errorf("%s %q: says bot, want agent", code, key)
			}
		}
	}
	for _, q := range Quadrants {
		for _, l := range Langs {
			if l.T("quadrant."+q.ID) == "quadrant."+q.ID {
				t.Errorf("%s: no name for quadrant %s", l.Code, q.ID)
			}
		}
	}
	for _, r := range Rings {
		if Langs[0].T("ring."+r.ID) != r.Name {
			t.Errorf("en: ring %s is %q, want %q", r.ID, Langs[0].T("ring."+r.ID), r.Name)
		}
	}
}

// TestFrenchPage renders every reason_fr of entries.yaml in index-fr.html,
// from the same placement as index.html.
func TestFrenchPage(t *testing.T) {
	root, err := RepoFS("../../..")
	if err != nil {
		t.Fatal(err)
	}
	r := &Radar{Entries: realEntries(t)}
	files, err := Render(r, root)
	if err != nil {
		t.Fatal(err)
	}
	fr := string(files["index-fr.html"])
	for _, e := range r.Entries {
		if !strings.Contains(fr, htmlText(e.ReasonFR)) {
			t.Errorf("index-fr.html has no reason_fr of %s", e.Name)
		}
	}
	pos := regexp.MustCompile(`<a class="blip [^"]+" href="[^"]+"><title>\d+\. `)
	if !strings.Contains(fr, `<html lang="fr-CH">`) || len(pos.FindAllString(fr, -1)) != len(r.Entries) {
		t.Errorf("index-fr.html: want lang fr-CH and %d blips", len(r.Entries))
	}
	strip := regexp.MustCompile(`<title>[^<]*</title>|<text class="(ring-name|blip-label-start|blip-label-end)"[^>]*>[^<]*</text>|aria-label="[^"]*"`)
	en, frChart := files["index.html"], files["index-fr.html"]
	chart := func(b []byte) string {
		s := string(b)
		return strip.ReplaceAllString(s[strings.Index(s, "<svg"):strings.Index(s, "</svg>")], "")
	}
	if chart(en) != chart(frChart) {
		t.Error("the blips sit in different places in the two languages")
	}
}
