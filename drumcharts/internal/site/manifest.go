// Package site validates the site data of charts.nedsi.io, built by
// ned-si/drum-charts, and renders its pages
// (.kiro/specs/drum-charts-site/design.md).
package site

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// Limits of the site data, in bytes (design, Validation).
const (
	MaxManifest = 1 << 20
	MaxFile     = 4 << 20
	MaxTotal    = 64 << 20
)

// Schema is the version of the charts.json contract shared with drum-charts.
const Schema = 2

const (
	maxSongs = 200
	maxPages = 3
	maxSlug  = 80
	maxText  = 100
)

var (
	// versionRe is a release tag after its "<slug>-".
	versionRe = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2})-([0-9a-f]{7})$`)
	commitRe  = regexp.MustCompile(`^[0-9a-f]{40}$`)
	slugRe    = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
)

// reserved are the paths of the site a song must not shadow.
var reserved = []string{"fr", "pdf", "pages", "legend", "set-theme"}

// Manifest is charts.json. Pointers tell a missing number from a zero.
type Manifest struct {
	Schema *int    `json:"schema"`
	Legend *Legend `json:"legend"`
	Songs  []Song  `json:"songs"`
}

// Legend is the manifest's entry for legend.pdf; Release is its song
// release, Commit the version commit the tag names.
type Legend struct {
	Pages   *int   `json:"pages"`
	Release string `json:"release"`
	Commit  string `json:"commit"`
}

// Song is one chart: Artist is the header's title, Title its subtitle.
type Song struct {
	Slug    string `json:"slug"`
	Artist  string `json:"artist"`
	Title   string `json:"title"`
	Pages   *int   `json:"pages"`
	Release string `json:"release"`
	Commit  string `json:"commit"`
}

// Page is one validated page image.
type Page struct {
	Name          string
	Width, Height int
	SVG           []byte
}

// Chart is a song or the legend with its PDF and page images; Date is the
// date of its release tag.
type Chart struct {
	Slug, Artist, Title, Release string
	Date                         time.Time
	PDF                          []byte
	Pages                        []Page
}

// Data is validated site data; Updated is the newest Date of its charts.
type Data struct {
	Updated time.Time
	Legend  Chart
	Songs   []Chart
}

// Errors are the broken rules, one `<file>: <rule>` line each.
type Errors []string

func (e Errors) Error() string { return strings.Join(e, "\n") }

type problems struct{ list Errors }

func (p *problems) add(file, format string, args ...any) {
	p.list = append(p.list, file+": "+fmt.Sprintf(format, args...))
}

func (p *problems) err() error {
	if len(p.list) == 0 {
		return nil
	}
	slices.Sort(p.list)
	return p.list
}

// Load reads and validates the site data in dir. On failure the error is an
// Errors with every broken rule, sorted.
func Load(dir string) (*Data, error) {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, err
	}
	defer func() { _ = root.Close() }() // read only
	var p problems
	sizes := listFiles(root, &p)
	m := readManifest(root, sizes, &p)
	if m == nil {
		return nil, p.err()
	}
	want := checkManifest(m, &p)
	for name := range sizes {
		if _, ok := want[name]; !ok && name != "charts.json" {
			p.add(name, "not part of the site data")
		}
	}
	for name := range want {
		if _, ok := sizes[name]; !ok {
			p.add(name, "missing")
		}
	}
	if len(p.list) > 0 {
		return nil, p.err()
	}
	d := &Data{}
	d.Legend = readChart(root, Chart{Slug: "legend", Release: m.Legend.Release, Date: versionDate("legend", m.Legend.Release)}, *m.Legend.Pages, &p)
	d.Updated = d.Legend.Date
	for _, s := range m.Songs {
		c := readChart(root, Chart{Slug: s.Slug, Artist: s.Artist, Title: s.Title, Release: s.Release, Date: versionDate(s.Slug, s.Release)}, *s.Pages, &p)
		if c.Date.After(d.Updated) {
			d.Updated = c.Date
		}
		d.Songs = append(d.Songs, c)
	}
	if err := p.err(); err != nil {
		return nil, err
	}
	return d, nil
}

// listFiles returns the size of every regular file in root; anything else,
// and a total above MaxTotal, is a problem.
func listFiles(root *os.Root, p *problems) map[string]int64 {
	entries, err := fs.ReadDir(root.FS(), ".")
	if err != nil {
		p.add(".", "%v", err)
		return nil
	}
	sizes := map[string]int64{}
	var total int64
	for _, e := range entries {
		if !e.Type().IsRegular() {
			p.add(e.Name(), "not a regular file")
			continue
		}
		info, err := e.Info()
		if err != nil {
			p.add(e.Name(), "%v", err)
			continue
		}
		sizes[e.Name()] = info.Size()
		total += info.Size()
	}
	if total > MaxTotal {
		p.add(".", "the site data holds %d bytes, at most %d", total, MaxTotal)
	}
	return sizes
}

func readManifest(root *os.Root, sizes map[string]int64, p *problems) *Manifest {
	const name = "charts.json"
	size, ok := sizes[name]
	if !ok {
		p.add(name, "missing")
		return nil
	}
	if size > MaxManifest {
		p.add(name, "%d bytes, at most %d", size, MaxManifest)
		return nil
	}
	b, err := readFile(root, name, MaxManifest)
	if err != nil {
		p.add(name, "%v", err)
		return nil
	}
	if !utf8.Valid(b) {
		p.add(name, "not valid UTF-8")
		return nil
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	var m Manifest
	if err := dec.Decode(&m); err != nil {
		p.add(name, "not a manifest: %v", err)
		return nil
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		p.add(name, "data after the manifest object")
		return nil
	}
	return &m
}

// checkManifest applies the manifest's rules and returns the file set it
// describes.
func checkManifest(m *Manifest, p *problems) map[string]bool {
	const name = "charts.json"
	if m.Schema == nil || *m.Schema != Schema {
		p.add(name, "schema must be %d", Schema)
	}
	want := map[string]bool{}
	if m.Legend == nil {
		m.Legend = &Legend{}
	}
	if !pagesOK(m.Legend.Pages) {
		p.add(name, "legend.pages must be 1 to %d", maxPages)
		m.Legend.Pages = new(int)
	}
	checkVersion(p, "legend.", "legend", m.Legend.Release, m.Legend.Commit)
	addFiles(want, "legend", *m.Legend.Pages)
	if len(m.Songs) < 1 || len(m.Songs) > maxSongs {
		p.add(name, "songs must hold 1 to %d songs, holds %d", maxSongs, len(m.Songs))
	}
	seen := map[string]bool{}
	for i := range m.Songs {
		s := &m.Songs[i]
		at := "songs[" + strconv.Itoa(i) + "]"
		switch {
		case !slugRe.MatchString(s.Slug) || len(s.Slug) > maxSlug:
			p.add(name, "%s: slug %q is not lower-case words joined by -, at most %d characters", at, s.Slug, maxSlug)
		case slices.Contains(reserved, s.Slug):
			p.add(name, "%s: slug %q is reserved (%s)", at, s.Slug, strings.Join(reserved, ", "))
		case seen[s.Slug]:
			p.add(name, "%s: slug %q is not unique", at, s.Slug)
		}
		seen[s.Slug] = true
		if msg := textRule(s.Artist); msg != "" {
			p.add(name, "%s: artist %s", at, msg)
		}
		if msg := textRule(s.Title); msg != "" {
			p.add(name, "%s: title %s", at, msg)
		}
		if !pagesOK(s.Pages) {
			p.add(name, "%s: pages must be 1 to %d", at, maxPages)
			s.Pages = new(int)
		}
		checkVersion(p, at+": ", s.Slug, s.Release, s.Commit)
		addFiles(want, s.Slug, *s.Pages)
	}
	return want
}

// checkVersion applies the rules of a chart's release tag,
// <slug>-<yyyy-mm-dd>-<7 hex>, and of its version commit; at prefixes each
// line.
func checkVersion(p *problems, at, slug, release, commit string) {
	const name = "charts.json"
	commitOK := commitRe.MatchString(commit)
	if !commitOK {
		p.add(name, "%scommit %q is not 40 lower-case hex", at, commit)
	}
	rest, ok := strings.CutPrefix(release, slug+"-")
	r := versionRe.FindStringSubmatch(rest)
	if !ok || r == nil {
		p.add(name, "%srelease %q is not %s-<yyyy-mm-dd>-<7 hex>", at, release, slug)
		return
	}
	if _, err := time.Parse(time.DateOnly, r[1]); err != nil {
		p.add(name, "%srelease %q has no valid date", at, release)
	}
	if commitOK && commit[:7] != r[2] {
		p.add(name, "%scommit %s does not start with the release's %s", at, commit, r[2])
	}
}

// versionDate is the date of a release tag checkVersion passed.
func versionDate(slug, release string) time.Time {
	d, _ := time.Parse(time.DateOnly, versionRe.FindStringSubmatch(strings.TrimPrefix(release, slug+"-"))[1]) // checked by checkVersion
	return d
}

func pagesOK(n *int) bool { return n != nil && *n >= 1 && *n <= maxPages }

func addFiles(want map[string]bool, slug string, pages int) {
	want[slug+".pdf"] = true
	for n := 1; n <= pages; n++ {
		want[pageName(slug, n)] = true
	}
}

func pageName(slug string, n int) string { return slug + "-" + strconv.Itoa(n) + ".svg" }

// textRule returns what is wrong with an artist or title, or "". U+FFFD is
// what the JSON decoder makes of invalid UTF-8 and lone surrogates.
func textRule(s string) string {
	n := utf8.RuneCountInString(s)
	switch {
	case n < 1 || n > maxText:
		return fmt.Sprintf("must be 1 to %d characters", maxText)
	case strings.TrimSpace(s) != s:
		return "has a leading or trailing space"
	case strings.ContainsFunc(s, func(r rune) bool {
		return unicode.Is(unicode.Cc, r) || r == '\u2028' || r == '\u2029'
	}):
		return "holds a control or line separator character"
	case strings.ContainsRune(s, utf8.RuneError):
		return "is not valid UTF-8"
	}
	return ""
}

func readChart(root *os.Root, c Chart, pages int, p *problems) Chart {
	pdf := c.Slug + ".pdf"
	b, err := readFile(root, pdf, MaxFile)
	switch {
	case err != nil:
		p.add(pdf, "%v", err)
	case !bytes.HasPrefix(b, []byte("%PDF-")):
		p.add(pdf, "does not start with %%PDF-")
	}
	c.PDF = b
	for n := 1; n <= pages; n++ {
		name := pageName(c.Slug, n)
		b, err := readFile(root, name, MaxFile)
		if err != nil {
			p.add(name, "%v", err)
			continue
		}
		w, h, err := CheckSVG(b)
		if err != nil {
			p.add(name, "%v", err)
			continue
		}
		c.Pages = append(c.Pages, Page{Name: name, Width: w, Height: h, SVG: b})
	}
	return c
}

// readFile reads name, failing above limit bytes.
func readFile(root *os.Root, name string, limit int64) ([]byte, error) {
	f, err := root.Open(name)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }() // read only
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, fmt.Errorf("more than %d bytes", limit)
	}
	return b, nil
}
