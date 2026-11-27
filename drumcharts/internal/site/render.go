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

// layout is what every page shares: head, header and footer. Path is the
// page's own path, for the canonical link and the theme links.
type layout struct {
	Title, Description, Path string
	Nav                      []navLink
	Prefs                    prefs
	Privacy                  string
}

type homeView struct {
	layout
	Heading, Lead                        string
	Intro, Updated, Credits              template.HTML
	Songs                                string
	ColSong, ColArtist, ColPages, ColPDF string
	PDF                                  string
	Rows                                 []row
}

type row struct {
	Slug, Title, Artist, PDFLabel string
	Pages                         int
}

type songView struct {
	layout
	Slug, Heading, Lead       string
	Download, All, LegendLink string
	Images                    []image
}

type image struct {
	Name, Alt     string
	Width, Height int
}

// Render renders the pages of d and copies its PDFs and page images, each
// image also gzipped for nginx's gzip_static.
func Render(d *Data) (Files, error) {
	m := messages(catalogue["en"])
	songs := slices.Clone(d.Songs)
	slices.SortStableFunc(songs, func(a, b Chart) int {
		return cmp.Or(
			strings.Compare(strings.ToLower(a.Artist), strings.ToLower(b.Artist)),
			strings.Compare(strings.ToLower(a.Title), strings.ToLower(b.Title)),
			strings.Compare(a.Slug, b.Slug),
		)
	})
	files := Files{}
	home := homeView{
		layout:    newLayout(m, m.text("home.title", nil), m.text("home.description", nil), "/"),
		Heading:   m.text("home.heading", nil),
		Lead:      m.text("home.lead", nil),
		Intro:     m.html("home.intro", map[string]template.HTML{"legend": link("/legend/", m.text("home.legend_link", nil))}),
		Songs:     m.text("home.songs", nil),
		ColSong:   m.text("home.col_song", nil),
		ColArtist: m.text("home.col_artist", nil),
		ColPages:  m.text("home.col_pages", nil),
		ColPDF:    m.text("home.col_pdf", nil),
		PDF:       m.text("home.pdf", nil),
		Updated: m.html(pluralKey("home.updated", len(songs)), map[string]template.HTML{
			"count":   escape(strconv.Itoa(len(songs))),
			"release": link("https://github.com/ned-si/drum-charts/releases/tag/"+d.Release, d.Release),
			"date":    template.HTML(`<time datetime="` + d.Date.Format("2006-01-02") + `">` + formatDate(d.Date) + `</time>`), //nolint:gosec // G203: digits and an English month name
		}),
		Credits: m.html("home.credits", map[string]template.HTML{"github": link("https://github.com/ned-si/drum-charts", m.text("home.github_link", nil))}),
	}
	for _, s := range songs {
		home.Rows = append(home.Rows, row{
			Slug:     s.Slug,
			Title:    s.Title,
			Artist:   s.Artist,
			PDFLabel: m.text("home.pdf_label", args{"title": s.Title}),
			Pages:    len(s.Pages),
		})
		song := args{"title": s.Title, "artist": s.Artist}
		v := songView{
			layout:     newLayout(m, m.text("song.title", song), m.text("song.description", song), "/"+s.Slug+"/"),
			Slug:       s.Slug,
			Heading:    s.Title,
			Lead:       m.text("song.lead", args{"artist": s.Artist, "pages": m.pages(len(s.Pages))}),
			Download:   m.text("song.download", nil),
			All:        m.text("song.all", nil),
			LegendLink: m.text("song.legend", nil),
		}
		v.Images = images(s, func(n int) string {
			return m.text("song.page_alt", args{"title": s.Title, "artist": s.Artist, "n": strconv.Itoa(n), "total": strconv.Itoa(len(s.Pages))})
		})
		if err := execute(files, s.Slug+"/index.html", "song.html", v); err != nil {
			return nil, err
		}
		addCopies(files, s)
	}
	legend := songView{
		layout:   newLayout(m, m.text("legend.title", nil), m.text("legend.description", nil), "/legend/"),
		Slug:     "legend",
		Heading:  m.text("legend.heading", nil),
		Lead:     m.text("legend.lead", nil),
		Download: m.text("song.download", nil),
		All:      m.text("song.all", nil),
	}
	legend.Images = images(d.Legend, func(n int) string {
		return m.text("legend.page_alt", args{"n": strconv.Itoa(n), "total": strconv.Itoa(len(d.Legend.Pages))})
	})
	if err := execute(files, "legend/index.html", "song.html", legend); err != nil {
		return nil, err
	}
	addCopies(files, d.Legend)
	if err := execute(files, "index.html", "home.html", home); err != nil {
		return nil, err
	}
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

func newLayout(m messages, title, description, p string) layout {
	return layout{
		Title:       title,
		Description: description,
		Path:        p,
		Nav: []navLink{
			{m.text("nav.home", nil), "https://nedsi.io/", false},
			{m.text("nav.blog", nil), "https://blog.nedsi.io/", false},
			{m.text("nav.homelab", nil), "https://homelab.nedsi.io/", false},
			{m.text("nav.techradar", nil), "https://techradar.nedsi.io/", false},
			{m.text("nav.charts", nil), "/", true},
			{m.text("nav.about", nil), "https://blog.nedsi.io/about/", false},
		},
		Prefs: prefs{
			Light:      m.text("prefs.light", nil),
			LightTitle: m.text("prefs.light_title", nil),
			Dark:       m.text("prefs.dark", nil),
			DarkTitle:  m.text("prefs.dark_title", nil),
		},
		Privacy: m.text("footer.privacy", nil),
	}
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
