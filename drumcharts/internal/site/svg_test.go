package site

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestCheckSVG: acceptance criterion 5, each forbidden construct in an
// otherwise allowed page image fails.
func TestCheckSVG(t *testing.T) {
	clean := readFixture(t, "sum41-fat-lip-1.svg")
	tests := []struct {
		name, old, new, want string
	}{
		{"script", "<defs>", "<script>alert(1)</script><defs>", "element script not allowed"},
		{"onload", "<svg ", `<svg onload="alert(1)" `, "attribute onload not allowed"},
		{"foreignObject", "<defs>", "<foreignObject></foreignObject><defs>", "element foreignObject not allowed"},
		{"image", "<defs>", `<image href="#a"/><defs>`, "element image not allowed"},
		{"style attribute", "<path ", `<path style="fill:red" `, "attribute style not allowed"},
		{"style element", "<defs>", "<style>path{}</style><defs>", "element style not allowed"},
		{"external href", `xlink:href="#glyph-0-0"`, `xlink:href="https://example.com/a.svg#x"`, "is not a reference inside the image"},
		{"href data", `xlink:href="#glyph-0-0"`, `href="data:image/png;base64,AA"`, "is not a reference inside the image"},
		{"doctype", "<svg ", "<!DOCTYPE svg [<!ENTITY x SYSTEM \"file:///etc/passwd\">]>\n<svg ", "directive not allowed"},
		{"entity", `y="100"`, `y="&x;"`, "not well-formed XML"},
		{"processing instruction", "<svg ", "<?xml-stylesheet href=\"a.css\"?>\n<svg ", "processing instruction <?xml-stylesheet not allowed"},
		{"text", "<defs>", "hello<defs>", "character data not allowed"},
		{"other namespace", "<defs>", `<h:p xmlns:h="http://www.w3.org/1999/xhtml"/><defs>`, "element http://www.w3.org/1999/xhtml:p not allowed"},
		{"no namespace", `xmlns="http://www.w3.org/2000/svg" `, "", "element svg not allowed"},
		{"external url", `clip-path="url(#clip-0)"`, `clip-path="url(https://example.com/#a)"`, "not allowed"},
		{"URL upper case", `clip-path="url(#clip-0)"`, `fill="URL(https://example.com/#a)"`, "not allowed"},
		{"backslash", `fill="rgb(0%, 0%, 0%)"`, `fill="u\72l(x)"`, "not allowed"},
		{"no viewBox", `viewBox="0 0 595 842"`, "", "needs a viewBox"},
		{"viewBox origin", `viewBox="0 0 595 842"`, `viewBox="10 0 595 842"`, "needs a viewBox"},
		{"viewBox zero", `viewBox="0 0 595 842"`, `viewBox="0 0 0 842"`, "needs a viewBox"},
		{"viewBox too big", `viewBox="0 0 595 842"`, `viewBox="0 0 10000.5 842"`, "needs a viewBox"},
		{"root not svg", "</svg>\n", "</svg>\n<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"/>\n", "the root must be one <svg>"},
		{"not XML", "</svg>", "", "not well-formed XML"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if !strings.Contains(clean, tc.old) {
				t.Fatalf("fixture has no %q", tc.old)
			}
			_, _, err := CheckSVG([]byte(strings.Replace(clean, tc.old, tc.new, 1)))
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Errorf("CheckSVG: %v, want %q", err, tc.want)
			}
		})
	}
}

// TestCheckSVGSize: the <img> gets the viewBox rounded to integers.
func TestCheckSVGSize(t *testing.T) {
	for name, want := range map[string][2]int{"soad-toxicity-1.svg": {595, 842}, "sum41-fat-lip-1.svg": {595, 842}} {
		w, h, err := CheckSVG([]byte(readFixture(t, name)))
		if err != nil || w != want[0] || h != want[1] {
			t.Errorf("%s: %dx%d, %v; want %dx%d", name, w, h, err, want[0], want[1])
		}
	}
	w, h, err := CheckSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 0.5 10000"/>`))
	if err != nil || w != 1 || h != 10000 {
		t.Errorf("0.5 x 10000: %dx%d, %v; want 1x10000", w, h, err)
	}
}

// TestRealPages: every page image of the pinned data passes, read from
// $DRUMCHARTS_DATA (set by scripts/ci/drumcharts-check.sh).
func TestRealPages(t *testing.T) {
	dir := os.Getenv("DRUMCHARTS_DATA")
	if dir == "" {
		t.Skip("DRUMCHARTS_DATA is not set")
	}
	pages, err := filepath.Glob(filepath.Join(dir, "*.svg"))
	if err != nil || len(pages) == 0 {
		t.Fatalf("no page images in %s: %v", dir, err)
	}
	for _, p := range pages {
		b, err := os.ReadFile(p) //nolint:gosec // G304: the extracted site data
		if err != nil {
			t.Fatal(err)
		}
		if _, _, err := CheckSVG(b); err != nil {
			t.Errorf("%s: %v", filepath.Base(p), err)
		}
	}
	if _, err := Load(dir); err != nil {
		t.Errorf("Load(%s): %v", dir, err)
	}
	t.Logf("%d page images", len(pages))
}
