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
    moved: up
  - name: Tetragon
    quadrant: platform
    ring: trial
    reason: Runtime detection that pages on critical events.
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
	const golden = "testdata/index.golden.html"
	if *update {
		if err := os.WriteFile(golden, files["index.html"], 0o600); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatal(err)
	}
	if diff := cmp.Diff(string(want), string(files["index.html"])); diff != "" {
		t.Errorf("index.html differs from %s (-want +got); go test -update rewrites it:\n%s", golden, diff)
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
	items := regexp.MustCompile(`<li value="(\d+)">(?:<a href="[^"]*">)?([^<]*)`).FindAllStringSubmatch(page, -1)
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
	elements := map[string]bool{"svg": true, "g": true, "circle": true, "path": true, "line": true, "text": true, "title": true}
	classes := map[string]bool{"ring-adopt": true, "ring-trial": true, "ring-assess": true, "ring-hold": true, "axis": true, "ring-line": true, "ring-name": true, "blip": true, "blip-number": true}
	numeric := regexp.MustCompile(`^-?[0-9]+(\.[0-9]+)?$`)
	pathData := regexp.MustCompile(`^M[0-9. L]+ Z$`)
	dec := xml.NewDecoder(strings.NewReader(SVG(blips)))
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
				if v != "img" {
					t.Errorf("role=%q", v)
				}
			case "focusable":
				if v != "false" {
					t.Errorf("focusable=%q", v)
				}
			case "aria-label":
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

// TestContrast checks every colour against the page background in the light
// and the dark palette: text 4.5:1, ring lines 3:1 (WCAG 2.2 1.4.3 and
// 1.4.11). The blip numbers are the background colour on the ring colours,
// the same pairs as the ring colours as text.
func TestContrast(t *testing.T) {
	b, err := os.ReadFile("assets/techradar.css")
	if err != nil {
		t.Fatal(err)
	}
	css := string(b)
	light, dark, ok := strings.Cut(css, "@media (prefers-")
	if !ok {
		t.Fatal("no dark palette in techradar.css")
	}
	minimum := map[string]float64{"fg": 4.5, "muted": 4.5, "link": 4.5, "adopt": 4.5, "trial": 4.5, "assess": 4.5, "hold": 4.5, "line": 3}
	vars := regexp.MustCompile(`--([a-z-]+):\s*(#[0-9a-f]{6});`)
	for palette, block := range map[string]string{"light": light, "dark": dark} {
		colours := map[string]string{}
		for _, m := range vars.FindAllStringSubmatch(block, -1) {
			colours[m[1]] = m[2]
		}
		bgHex, ok := colours["bg"]
		if !ok {
			t.Fatalf("%s: no --bg", palette)
		}
		bg := luminance(t, bgHex)
		for name, want := range minimum {
			c, ok := colours[name]
			if !ok {
				t.Errorf("%s: no --%s", palette, name)
				continue
			}
			fg := luminance(t, c)
			if ratio := (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05); ratio < want {
				t.Errorf("%s: --%s %s on --bg %s: contrast %.2f, want at least %.1f", palette, name, c, bgHex, ratio, want)
			}
		}
	}
}
