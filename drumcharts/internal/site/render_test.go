package site

import (
	"bytes"
	"compress/gzip"
	"flag"
	"io"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"syscall"
	"testing"
)

var update = flag.Bool("update", false, "rewrite testdata/golden")

const golden = "testdata/golden"

func render(t *testing.T, d *Data) Files {
	t.Helper()
	files, err := Render(d)
	if err != nil {
		t.Fatal(err)
	}
	return files
}

func load(t *testing.T) *Data {
	t.Helper()
	d, err := Load(fixture)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// readTree reads every file under dir by slash-separated path.
func readTree(t *testing.T, dir string) Files {
	t.Helper()
	files := Files{}
	err := filepath.WalkDir(dir, func(p string, e fs.DirEntry, err error) error {
		if err != nil || e.IsDir() {
			return err
		}
		b, err := os.ReadFile(p) //nolint:gosec // G304: under the test's own directories
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(dir, p)
		files[filepath.ToSlash(rel)] = b
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return files
}

// TestGolden: acceptance criterion 6, the render of the fixture equals
// testdata/golden file by file; go test -update rewrites it.
func TestGolden(t *testing.T) {
	files := render(t, load(t))
	if *update {
		if err := os.RemoveAll(golden); err != nil {
			t.Fatal(err)
		}
		if err := Write(files, golden); err != nil {
			t.Fatal(err)
		}
	}
	want := readTree(t, golden)
	for _, name := range slices.Sorted(maps.Keys(files)) {
		w, ok := want[name]
		switch {
		case !ok:
			t.Errorf("%s: rendered, not in %s", name, golden)
		case !bytes.Equal(w, files[name]):
			t.Errorf("%s differs from %s; go test -update rewrites it", name, golden)
		}
	}
	for name := range want {
		if _, ok := files[name]; !ok {
			t.Errorf("%s/%s: not rendered", golden, name)
		}
	}
	wantNames := []string{
		"charts.css", "index.html", "layout.css", "legend/index.html",
		"pages/legend-1.svg", "pages/legend-1.svg.gz",
		"pages/soad-toxicity-1.svg", "pages/soad-toxicity-1.svg.gz",
		"pages/sum41-fat-lip-1.svg", "pages/sum41-fat-lip-1.svg.gz",
		"pages/sum41-fat-lip-2.svg", "pages/sum41-fat-lip-2.svg.gz",
		"pages/underschool-element-petit-tom-1.svg", "pages/underschool-element-petit-tom-1.svg.gz",
		"pdf/legend.pdf", "pdf/soad-toxicity.pdf", "pdf/sum41-fat-lip.pdf",
		"pdf/underschool-element-petit-tom.pdf",
		"soad-toxicity/index.html", "sum41-fat-lip/index.html",
		"theme-dark.css", "theme-light.css",
		"underschool-element-petit-tom/index.html",
	}
	if got := slices.Sorted(maps.Keys(files)); !slices.Equal(got, wantNames) {
		t.Errorf("files %q, want %q", got, wantNames)
	}
	if again := render(t, load(t)); !maps.EqualFunc(files, again, bytes.Equal) {
		t.Error("two renders differ")
	}
}

func TestGzipped(t *testing.T) {
	files := render(t, load(t))
	for name, b := range files {
		if !strings.HasSuffix(name, ".svg") {
			continue
		}
		zr, err := gzip.NewReader(bytes.NewReader(files[name+".gz"]))
		if err != nil {
			t.Fatalf("%s.gz: %v", name, err)
		}
		got, err := io.ReadAll(zr)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, b) {
			t.Errorf("%s.gz does not decompress to %s", name, name)
		}
		if zr.Name != "" || !zr.ModTime.IsZero() {
			t.Errorf("%s.gz header: name %q, time %v", name, zr.Name, zr.ModTime)
		}
	}
}

// TestWriteModes: directories 0755 and files 0644 under a 0077 umask, the
// files as rendered, nothing left next to the output.
func TestWriteModes(t *testing.T) {
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)
	files := render(t, load(t))
	parent := t.TempDir()
	out := filepath.Join(parent, "out")
	if err := Write(files, out); err != nil {
		t.Fatal(err)
	}
	err := filepath.WalkDir(out, func(p string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := e.Info()
		if err != nil {
			return err
		}
		want := fs.FileMode(0o644)
		if e.IsDir() {
			want = fs.ModeDir | 0o755
		}
		if info.Mode() != want {
			t.Errorf("%s: mode %v, want %v", p, info.Mode(), want)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := readTree(t, out); !maps.EqualFunc(got, files, bytes.Equal) {
		t.Error("written files differ from the render")
	}
	if entries, _ := os.ReadDir(parent); len(entries) != 1 {
		t.Errorf("%d entries next to the output, want 1", len(entries))
	}
}

func TestWriteFails(t *testing.T) {
	parent := t.TempDir()
	out := filepath.Join(parent, "out")
	mkdir(t, out)
	if err := Write(Files{"index.html": nil}, out); err == nil {
		t.Error("Write over an existing directory passed")
	}
	if err := os.Remove(out); err != nil {
		t.Fatal(err)
	}
	// "a" is a file, so "a/b" cannot be written.
	if err := Write(Files{"a": nil, "a/b": nil}, out); err == nil {
		t.Error("Write of a file under a file passed")
	}
	if entries, _ := os.ReadDir(parent); len(entries) != 0 {
		t.Errorf("a failed Write left %d entries", len(entries))
	}
}

var rowRe = regexp.MustCompile(`<tr><td><a href="/([a-z0-9-]+)/">`)

func chart(slug, artist, title string, pages int) Chart {
	c := Chart{Slug: slug, Artist: artist, Title: title, PDF: []byte("%PDF-")}
	for range pages {
		c.Pages = append(c.Pages, Page{Name: slug + ".svg", Width: 595, Height: 842})
	}
	return c
}

// TestOrder: by artist, then title, in lower case, then slug; never by
// slug first (soad- sorts before sum41-, System Of A Down after Sum 41).
func TestOrder(t *testing.T) {
	d := load(t)
	d.Songs = []Chart{
		chart("soad-toxicity", "System Of A Down", "Toxicity", 1),
		chart("korn-b", "korn", "Here to Stay", 1),
		chart("sum41-fat-lip", "Sum 41", "Fat Lip", 1),
		chart("korn-a", "Korn", "here to stay", 1),
		chart("korn-c", "Korn", "Did My Time", 1),
	}
	var got []string
	for _, m := range rowRe.FindAllStringSubmatch(string(render(t, d)["index.html"]), -1) {
		got = append(got, m[1])
	}
	want := []string{"korn-c", "korn-a", "korn-b", "sum41-fat-lip", "soad-toxicity"}
	if !slices.Equal(got, want) {
		t.Errorf("order %q, want %q", got, want)
	}
}

func TestPlural(t *testing.T) {
	d := load(t)
	d.Songs = []Chart{chart("tool-schism", "Tool", "Schism", 1)}
	files := render(t, d)
	for name, want := range map[string]string{
		"index.html":             "<p class=\"updated\">1 song, from the release ",
		"tool-schism/index.html": `<p class="lead">Tool · 1 page</p>`,
	} {
		if !strings.Contains(string(files[name]), want) {
			t.Errorf("%s has no %q", name, want)
		}
	}
	files = render(t, load(t))
	for name, want := range map[string]string{
		"index.html":               "<p class=\"updated\">3 songs, from the release ",
		"sum41-fat-lip/index.html": `<p class="lead">Sum 41 · 2 pages</p>`,
	} {
		if !strings.Contains(string(files[name]), want) {
			t.Errorf("%s has no %q", name, want)
		}
	}
}

var imgRe = regexp.MustCompile(`<img [^>]*>`)

// TestImages: every <img> has integer width and height and an alt; the
// decimal viewBox 595.28 x 841.89 gives 595 x 842.
func TestImages(t *testing.T) {
	files := render(t, load(t))
	attrs := regexp.MustCompile(`^<img src="/pages/[a-z0-9-]+-[0-9]\.svg" width="[0-9]+" height="[0-9]+" alt="[^"]+"( loading="lazy")?>$`)
	want := map[string]string{
		"soad-toxicity/index.html": `<img src="/pages/soad-toxicity-1.svg" width="595" height="842" alt="Toxicity by System Of A Down, page 1 of 1">`,
		"sum41-fat-lip/index.html": `<img src="/pages/sum41-fat-lip-2.svg" width="595" height="842" alt="Fat Lip by Sum 41, page 2 of 2" loading="lazy">`,
		"legend/index.html":        `<img src="/pages/legend-1.svg" width="595" height="842" alt="The legend of the drum charts, page 1 of 1">`,
	}
	for name, img := range want {
		page := string(files[name])
		if !strings.Contains(page, img) {
			t.Errorf("%s has no %s", name, img)
		}
		for _, tag := range imgRe.FindAllString(page, -1) {
			if !attrs.MatchString(tag) {
				t.Errorf("%s: %s", name, tag)
			}
		}
	}
}
