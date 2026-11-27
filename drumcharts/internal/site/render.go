package site

import (
	"bytes"
	"cmp"
	"compress/gzip"
	"embed"
	"errors"
	"fmt"
	"html/template"
	"io/fs"
	"maps"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

//go:embed assets
var assets embed.FS

var pages = template.Must(template.ParseFS(assets, "assets/*.html"))

// Stylesheets are copied as they are; nginx serves one palette as /theme.css.
var stylesheets = []string{"charts.css", "layout.css", "theme-dark.css", "theme-light.css"}

// Files are the rendered site's files by slash-separated path, as served
// from the root of charts.nedsi.io.
type Files map[string][]byte

// Current marks this site's own link with aria-current.
type navLink struct {
	Label, Href string
	Current     bool
}

type prefs struct{ Light, LightTitle, Dark, DarkTitle string }

// lang is one language of the site; Root is its home, the prefix of its
// pages (design, Language).
type lang struct{ Code, Locale, Root string }

var langs = []lang{{"en", "en-GB", "/"}, {"fr", "fr-CH", "/fr/"}}

const origin = "https://charts.nedsi.io"

// layout is what every page shares: head, header and footer. Path is the
// page's own path, for the canonical link and the theme links; EN and FR
// are the page in each language, for hreflang and the language switch.
type layout struct {
	lang
	Title, Description, Path string
	EN, FR                   string
	Nav                      []navLink
	Prefs                    prefs
	Privacy, PrivacyURL      string
}

type homeView struct {
	layout
	Heading, Lead           string
	Intro, Updated, Credits template.HTML
	Songs                   string
	PDF                     string
	Cards                   []card
}

// card is one song on the home page: its first page as the thumbnail.
type card struct {
	Slug, Title, Artist, PDFLabel, Pages string
	Thumb                                image
}

type songView struct {
	layout
	Slug, Heading, Lead       string
	Download, All, LegendLink string
	Version                   template.HTML
	Images                    []image
}

type image struct {
	Name, Alt     string
	Width, Height int
}

// Render renders the pages of d in each language and copies its PDFs and
// page images once, each image also gzipped for nginx's gzip_static.
func Render(d *Data) (Files, error) {
	songs := slices.Clone(d.Songs)
	slices.SortStableFunc(songs, func(a, b Chart) int {
		return cmp.Or(
			strings.Compare(strings.ToLower(a.Artist), strings.ToLower(b.Artist)),
			strings.Compare(strings.ToLower(a.Title), strings.ToLower(b.Title)),
			strings.Compare(a.Slug, b.Slug),
		)
	})
	files := Files{}
	for _, l := range langs {
		if err := renderLang(files, d, songs, l); err != nil {
			return nil, err
		}
	}
	for _, s := range songs {
		addCopies(files, s)
	}
	addCopies(files, d.Legend)
	for _, name := range stylesheets {
		b, err := assets.ReadFile("assets/" + name)
		if err != nil {
			return nil, err
		}
		files[name] = b
	}
	for _, name := range slices.Collect(maps.Keys(files)) {
		if strings.HasPrefix(name, "pages/") {
			z, err := gzipped(files[name])
			if err != nil {
				return nil, err
			}
			files[name+".gz"] = z
		}
	}
	return files, nil
}

// renderLang renders the pages of one language under its Root, songs in
// their order.
func renderLang(files Files, d *Data, songs []Chart, l lang) error {
	m := messages(catalogue[l.Code])
	dir := strings.TrimPrefix(l.Root, "/")
	home := homeView{
		layout:  newLayout(m, l, m.text("home.title", nil), m.text("home.description", nil), ""),
		Heading: m.text("home.heading", nil),
		Lead:    m.text("home.lead", nil),
		Intro:   m.html("home.intro", map[string]template.HTML{"legend": link(l.Root+"legend/", m.text("home.legend_link", nil))}),
		Songs:   m.text("home.songs", nil),
		PDF:     m.text("home.pdf", nil),
		Updated: m.html(pluralKey("home.updated", len(songs)), map[string]template.HTML{
			"count": escape(strconv.Itoa(len(songs))),
			"date":  dateHTML(l.Code, d.Updated),
		}),
		Credits: m.html("home.credits", map[string]template.HTML{"github": link("https://github.com/ned-si/drum-charts", m.text("home.github_link", nil))}),
	}
	for _, s := range songs {
		song := args{"title": s.Title, "artist": s.Artist}
		first := s.Pages[0]
		home.Cards = append(home.Cards, card{
			Slug:     s.Slug,
			Title:    s.Title,
			Artist:   s.Artist,
			PDFLabel: m.text("home.pdf_label", args{"title": s.Title}),
			Pages:    m.pages(len(s.Pages)),
			Thumb:    image{Name: first.Name, Alt: m.text("home.card_alt", song), Width: first.Width, Height: first.Height},
		})
		v := songView{
			layout:     newLayout(m, l, m.text("song.title", song), m.text("song.description", song), s.Slug+"/"),
			Slug:       s.Slug,
			Heading:    s.Title,
			Lead:       m.text("song.lead", args{"artist": s.Artist, "pages": m.pages(len(s.Pages))}),
			Download:   m.text("song.download", nil),
			All:        m.text("song.all", nil),
			LegendLink: m.text("song.legend", nil),
			Version:    version(m, l, s),
		}
		v.Images = images(s, func(n int) string {
			return m.text("song.page_alt", args{"title": s.Title, "artist": s.Artist, "n": strconv.Itoa(n), "total": strconv.Itoa(len(s.Pages))})
		})
		if err := execute(files, dir+s.Slug+"/index.html", "song.html", v); err != nil {
			return err
		}
	}
	legend := songView{
		layout:   newLayout(m, l, m.text("legend.title", nil), m.text("legend.description", nil), "legend/"),
		Slug:     "legend",
		Heading:  m.text("legend.heading", nil),
		Lead:     m.text("legend.lead", nil),
		Download: m.text("song.download", nil),
		All:      m.text("song.all", nil),
		Version:  version(m, l, d.Legend),
	}
	legend.Images = images(d.Legend, func(n int) string {
		return m.text("legend.page_alt", args{"n": strconv.Itoa(n), "total": strconv.Itoa(len(d.Legend.Pages))})
	})
	if err := execute(files, dir+"legend/index.html", "song.html", legend); err != nil {
		return err
	}
	return execute(files, dir+"index.html", "home.html", home)
}

// newLayout is the layout of the page at rel, its path below the language's
// Root. The nav links each site in the same language, as NAV in
// scripts/ci/site_markup.py.
func newLayout(m messages, l lang, title, description, rel string) layout {
	return layout{
		lang:        l,
		Title:       title,
		Description: description,
		Path:        l.Root + rel,
		EN:          origin + "/" + rel,
		FR:          origin + "/fr/" + rel,
		Nav: []navLink{
			{Label: m.text("nav.home", nil), Href: "https://nedsi.io" + l.Root},
			{Label: m.text("nav.blog", nil), Href: "https://blog.nedsi.io" + l.Root},
			{Label: m.text("nav.homelab", nil), Href: "https://homelab.nedsi.io" + l.Root},
			{Label: m.text("nav.techradar", nil), Href: "https://techradar.nedsi.io" + l.Root},
			{Label: m.text("nav.charts", nil), Href: l.Root, Current: true},
			{Label: m.text("nav.about", nil), Href: "https://blog.nedsi.io" + l.Root + "about/"},
		},
		Prefs: prefs{
			Light:      m.text("prefs.light", nil),
			LightTitle: m.text("prefs.light_title", nil),
			Dark:       m.text("prefs.dark", nil),
			DarkTitle:  m.text("prefs.dark_title", nil),
		},
		Privacy:    m.text("footer.privacy", nil),
		PrivacyURL: "https://blog.nedsi.io" + l.Root + "privacy/",
	}
}

// version names the chart's version date and links its song release.
func version(m messages, l lang, c Chart) template.HTML {
	return m.html("song.version", map[string]template.HTML{
		"date":    dateHTML(l.Code, c.Date),
		"release": link("https://github.com/ned-si/drum-charts/releases/tag/"+c.Release, c.Release),
	})
}

func dateHTML(code string, d time.Time) template.HTML {
	return template.HTML(`<time datetime="` + d.Format(time.DateOnly) + `">` + formatDate(code, d) + `</time>`) //nolint:gosec // G203: digits and a month name of formatDate
}

func images(c Chart, alt func(n int) string) []image {
	out := make([]image, 0, len(c.Pages))
	for i, p := range c.Pages {
		out = append(out, image{Name: p.Name, Alt: alt(i + 1), Width: p.Width, Height: p.Height})
	}
	return out
}

func addCopies(files Files, c Chart) {
	files["pdf/"+c.Slug+".pdf"] = c.PDF
	for _, p := range c.Pages {
		files["pages/"+p.Name] = p.SVG
	}
}

func execute(files Files, name, tmpl string, data any) error {
	var buf bytes.Buffer
	if err := pages.ExecuteTemplate(&buf, tmpl, data); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	files[name] = buf.Bytes()
	return nil
}

func escape(s string) template.HTML {
	return template.HTML(template.HTMLEscapeString(s)) //nolint:gosec // G203: escaped on this line
}

func link(href, text string) template.HTML {
	return template.HTML(`<a href="` + template.HTMLEscapeString(href) + `">` + template.HTMLEscapeString(text) + `</a>`) //nolint:gosec // G203: both parts escaped on this line
}

// gzipped compresses b at level 9 with no name and no time in the header,
// so the bytes depend on b alone.
func gzipped(b []byte) ([]byte, error) {
	var buf bytes.Buffer
	zw, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	if _, err := zw.Write(b); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// Write writes files to out, which must not exist: into a temporary
// directory next to it, renamed to out once everything is written, so a
// failure leaves nothing. Directories are 0755 and files 0644 whatever the
// umask, since nginx reads them as another user.
func Write(files Files, out string) (err error) {
	if _, err := os.Lstat(out); err == nil {
		return fmt.Errorf("%s exists", out)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	tmp, err := os.MkdirTemp(filepath.Dir(out), "."+filepath.Base(out)+"-")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = os.RemoveAll(tmp) // best effort; the error says what failed
		}
	}()
	root, err := os.OpenRoot(tmp)
	if err != nil {
		return err
	}
	defer func() { _ = root.Close() }() // every write is checked below
	for _, name := range slices.Sorted(maps.Keys(files)) {
		if dir := path.Dir(name); dir != "." {
			if err := root.MkdirAll(dir, 0o755); err != nil {
				return err
			}
		}
		if err := root.WriteFile(name, files[name], 0o644); err != nil {
			return err
		}
	}
	err = fs.WalkDir(root.FS(), ".", func(name string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		mode := fs.FileMode(0o644)
		if e.IsDir() {
			mode = 0o755
		}
		return root.Chmod(name, mode)
	})
	if err != nil {
		return err
	}
	return os.Rename(tmp, out)
}
