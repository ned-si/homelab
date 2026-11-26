package site

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

const fixture = "testdata/data"

// copyFixture copies the fixture into a temporary directory.
func copyFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	entries, err := os.ReadDir(fixture)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		b, err := os.ReadFile(filepath.Join(fixture, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, e.Name()), b, 0o600); err != nil { //nolint:gosec // G703: names listed from the fixture directory
			t.Fatal(err)
		}
	}
	return dir
}

// editManifest rewrites charts.json in dir through f.
func editManifest(t *testing.T, dir string, f func(m map[string]any)) {
	t.Helper()
	path := filepath.Join(dir, "charts.json")
	b, err := os.ReadFile(path) //nolint:gosec // G304: the test's own temporary directory
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	f(m)
	if b, err = json.Marshal(m); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
}

func song(m map[string]any, i int) map[string]any {
	return m["songs"].([]any)[i].(map[string]any)
}

func write(name, content string) func(*testing.T, string) {
	return func(t *testing.T, dir string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func manifest(f func(m map[string]any)) func(*testing.T, string) {
	return func(t *testing.T, dir string) {
		t.Helper()
		editManifest(t, dir, f)
	}
}

func TestLoadClean(t *testing.T) {
	d, err := Load(fixture)
	if err != nil {
		t.Fatal(err)
	}
	if d.Release != "charts-2026-11-26-4215d23" || formatDate(d.Date) != "26 November 2026" {
		t.Errorf("release %s of %s", d.Release, formatDate(d.Date))
	}
	if len(d.Songs) != 3 || len(d.Songs[0].Pages) != 1 || len(d.Songs[1].Pages) != 2 || len(d.Legend.Pages) != 1 {
		t.Errorf("songs %+v, legend %d pages", d.Songs, len(d.Legend.Pages))
	}
}

// TestLoadRules breaks one rule of design, Validation, per case on a copy of
// the fixture; each must fail with its `<file>: <rule>` line.
func TestLoadRules(t *testing.T) {
	long := strings.Repeat("x", 101)
	tests := []struct {
		name    string
		breakIt func(*testing.T, string)
		want    string
	}{
		{"no manifest", func(t *testing.T, dir string) { remove(t, dir, "charts.json") }, "charts.json: missing"},
		{"manifest too big", write("charts.json", strings.Repeat(" ", MaxManifest+1)), "charts.json: 1048577 bytes, at most 1048576"},
		{"not UTF-8", write("charts.json", "{\"release\": \"\xff\"}"), "charts.json: not valid UTF-8"},
		{"not JSON", write("charts.json", "["), "charts.json: not a manifest"},
		{"unknown key", manifest(func(m map[string]any) { m["extra"] = 1 }), `charts.json: not a manifest: json: unknown field "extra"`},
		{"unknown song key", manifest(func(m map[string]any) { song(m, 0)["mp3"] = "x.mp3" }), `unknown field "mp3"`},
		{"data after the object", func(t *testing.T, dir string) { appendTo(t, dir, "charts.json", "{}") }, "charts.json: data after the manifest object"},
		{"unknown schema", manifest(func(m map[string]any) { m["schema"] = 2 }), "charts.json: schema must be 1"},
		{"no schema", manifest(func(m map[string]any) { delete(m, "schema") }), "charts.json: schema must be 1"},
		{"schema not an integer", manifest(func(m map[string]any) { m["schema"] = 1.5 }), "charts.json: not a manifest"},
		{"bad release tag", manifest(func(m map[string]any) { m["release"] = "charts-2026-11-26" }), `charts.json: release "charts-2026-11-26" is not`},
		{"release date", manifest(func(m map[string]any) { m["release"] = "charts-2026-02-30-4215d23" }), "has no valid date"},
		{"commit not hex", manifest(func(m map[string]any) { m["commit"] = strings.ToUpper(m["commit"].(string)) }), "is not 40 lower-case hex"},
		{"commit not hex with a bad release tag", manifest(func(m map[string]any) { m["release"] = "charts"; m["commit"] = "4215d23" }), `charts.json: commit "4215d23" is not 40 lower-case hex`},
		{"commit prefix mismatch", manifest(func(m map[string]any) { m["commit"] = "5387aa2358e4fe55993320dccb60947f21bc1028" }), "does not start with the release's 4215d23"},
		{"no legend", manifest(func(m map[string]any) { delete(m, "legend") }), "charts.json: legend.pages must be 1 to 3"},
		{"legend pages 4", manifest(func(m map[string]any) { m["legend"] = map[string]any{"pages": 4} }), "charts.json: legend.pages must be 1 to 3"},
		{"no songs", manifest(func(m map[string]any) { m["songs"] = []any{} }), "charts.json: songs must hold 1 to 200 songs, holds 0"},
		{"bad slug", manifest(func(m map[string]any) { song(m, 0)["slug"] = "Tool_Schism" }), `songs[0]: slug "Tool_Schism" is not lower-case words`},
		{"long slug", manifest(func(m map[string]any) { song(m, 0)["slug"] = strings.Repeat("a", 81) }), "at most 80 characters"},
		{"reserved slug", manifest(func(m map[string]any) { song(m, 0)["slug"] = "pages" }), `songs[0]: slug "pages" is reserved`},
		{"duplicate slug", manifest(func(m map[string]any) { song(m, 1)["slug"] = "soad-toxicity" }), `songs[1]: slug "soad-toxicity" is not unique`},
		{"empty artist", manifest(func(m map[string]any) { song(m, 0)["artist"] = "" }), "songs[0]: artist must be 1 to 100 characters"},
		{"no title", manifest(func(m map[string]any) { delete(song(m, 0), "title") }), "songs[0]: title must be 1 to 100 characters"},
		{"long title", manifest(func(m map[string]any) { song(m, 0)["title"] = long }), "songs[0]: title must be 1 to 100 characters"},
		{"leading space", manifest(func(m map[string]any) { song(m, 0)["artist"] = " Tool" }), "songs[0]: artist has a leading or trailing space"},
		{"control character", manifest(func(m map[string]any) { song(m, 0)["title"] = "Tox\u0085icity" }), "songs[0]: title holds a control or line separator"},
		{"line separator", manifest(func(m map[string]any) { song(m, 0)["title"] = "Tox\u2028icity" }), "songs[0]: title holds a control or line separator"},
		{"lone surrogate", write("charts.json", strings.Replace(readFixture(t, "charts.json"), `"Toxicity"`, `"Tox\ud800icity"`, 1)), "songs[0]: title is not valid UTF-8"},
		{"pages 0", manifest(func(m map[string]any) { song(m, 0)["pages"] = 0 }), "songs[0]: pages must be 1 to 3"},
		{"pages 4", manifest(func(m map[string]any) { song(m, 1)["pages"] = 4 }), "songs[1]: pages must be 1 to 3"},
		{"no pages", manifest(func(m map[string]any) { delete(song(m, 0), "pages") }), "songs[0]: pages must be 1 to 3"},
		{"missing page image", func(t *testing.T, dir string) { remove(t, dir, "sum41-fat-lip-2.svg") }, "sum41-fat-lip-2.svg: missing"},
		{"missing PDF", func(t *testing.T, dir string) { remove(t, dir, "legend.pdf") }, "legend.pdf: missing"},
		{"extra page image", write("soad-toxicity-2.svg", readFixture(t, "soad-toxicity-1.svg")), "soad-toxicity-2.svg: not part of the site data"},
		{"an mp3", write("sum41-fat-lip.mp3", "ID3"), "sum41-fat-lip.mp3: not part of the site data"},
		{"a subdirectory", func(t *testing.T, dir string) { mkdir(t, filepath.Join(dir, "pdf")) }, "pdf: not a regular file"},
		{"a link", func(t *testing.T, dir string) {
			remove(t, dir, "legend.pdf")
			if err := os.Symlink("soad-toxicity.pdf", filepath.Join(dir, "legend.pdf")); err != nil {
				t.Fatal(err)
			}
		}, "legend.pdf: not a regular file"},
		{"not a PDF", write("soad-toxicity.pdf", "<html>"), "soad-toxicity.pdf: does not start with %PDF-"},
		{"PDF too big", write("soad-toxicity.pdf", "%PDF-"+strings.Repeat(" ", MaxFile)), "soad-toxicity.pdf: more than 4194304 bytes"},
		{"page image too big", write("legend-1.svg", strings.Repeat(" ", MaxFile+1)), "legend-1.svg: more than 4194304 bytes"},
		{"page image not allowed", write("sum41-fat-lip-1.svg", strings.Replace(readFixture(t, "sum41-fat-lip-1.svg"), "<defs>", "<script>x</script><defs>", 1)), "sum41-fat-lip-1.svg: element script not allowed"},
		{"all files too big", func(t *testing.T, dir string) {
			// Sparse: the size counts, no disk is used.
			if err := os.Truncate(filepath.Join(dir, "legend.pdf"), MaxTotal); err != nil {
				t.Fatal(err)
			}
		}, ".: the site data holds"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir := copyFixture(t)
			tc.breakIt(t, dir)
			d, err := Load(dir)
			if err == nil {
				t.Fatalf("Load passed, want %q; data %+v", tc.want, d)
			}
			var list Errors
			if !errors.As(err, &list) {
				t.Fatalf("error %v (%T), want Errors", err, err)
			}
			if !slices.IsSorted(list) {
				t.Errorf("lines not sorted: %q", list)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error\n%v\nwant a line with %q", err, tc.want)
			}
		})
	}
}

// TestLoadEveryProblem: one run lists every broken rule, not only the first.
func TestLoadEveryProblem(t *testing.T) {
	dir := copyFixture(t)
	editManifest(t, dir, func(m map[string]any) {
		m["schema"] = 2
		song(m, 0)["artist"] = ""
	})
	write("sum41-fat-lip.mp3", "ID3")(t, dir)
	_, err := Load(dir)
	var list Errors
	if !errors.As(err, &list) || len(list) != 3 {
		t.Fatalf("error %v, want 3 lines", err)
	}
}

func readFixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(fixture, name)) //nolint:gosec // G304: a fixture file
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func remove(t *testing.T, dir, name string) {
	t.Helper()
	if err := os.Remove(filepath.Join(dir, name)); err != nil {
		t.Fatal(err)
	}
}

func mkdir(t *testing.T, dir string) {
	t.Helper()
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
}

func appendTo(t *testing.T, dir, name, s string) {
	t.Helper()
	f, err := os.OpenFile(filepath.Join(dir, name), os.O_APPEND|os.O_WRONLY, 0) //nolint:gosec // G304: the test's own temporary directory
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(s); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
}
