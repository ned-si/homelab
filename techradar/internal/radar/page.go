package radar

import (
	"bytes"
	"embed"
	"html/template"
	"io/fs"
)

//go:embed assets
var assets embed.FS

var page = template.Must(template.ParseFS(assets, "assets/page.html"))

// Files are the rendered page's files by name, as served from the root of
// techradar.nedsi.io.
type Files map[string][]byte

type pageData struct {
	Lang       Lang
	T          map[string]string
	URL        string // this page, absolute
	EN, FR     string // both language versions, absolute
	Other      string // the other language's version
	Updated    string
	UpdatedISO string
	Count      int
	Chart      template.HTML
	Quadrants  []quadrantView
}

type quadrantView struct {
	ID, Name string
	Rings    []ringView
}

type ringView struct {
	ID, Name string
	Entries  []entryView
}

type entryView struct {
	Number                  int
	Slug, Name, URL, Reason string
	Moved                   string
}

// Site is the radar's public origin.
const Site = "https://techradar.nedsi.io"

// Render places the blips once and renders index.html (English) and
// index-fr.html (French) from that placement, with the stylesheets: its own,
// the shared layout and the two palettes nginx picks /theme.css from.
func Render(r *Radar, root fs.StatFS) (Files, error) {
	blips, err := Place(r.Entries)
	if err != nil {
		return nil, err
	}
	files := Files{}
	for i, l := range Langs {
		b, err := render(r, root, blips, l, Langs[1-i])
		if err != nil {
			return nil, err
		}
		files[l.File] = b
	}
	for _, name := range []string{"techradar.css", "layout.css", "theme-dark.css", "theme-light.css"} {
		b, err := assets.ReadFile("assets/" + name)
		if err != nil {
			return nil, err
		}
		files[name] = b
	}
	return files, nil
}

func render(r *Radar, root fs.StatFS, blips []Blip, l, other Lang) ([]byte, error) {
	data := pageData{
		Lang:       l,
		T:          catalogue[l.Code],
		URL:        Site + l.Path,
		EN:         Site + Langs[0].Path,
		FR:         Site + Langs[1].Path,
		Other:      Site + other.Path,
		Updated:    l.Date(r.Updated),
		UpdatedISO: r.Updated.Format("2006-01-02"),
		Count:      len(blips),
		// The SVG builder escapes every text it writes (svg.go).
		Chart: template.HTML(SVG(blips, l)), //nolint:gosec // G203: built from escaped text and numbers only
	}
	for _, q := range Quadrants {
		qv := quadrantView{ID: q.ID, Name: l.T("quadrant." + q.ID)}
		for _, rg := range Rings {
			rv := ringView{ID: rg.ID, Name: l.T("ring." + rg.ID)}
			for _, b := range blips {
				if b.Entry.Quadrant == q.ID && b.Entry.Ring == rg.ID {
					moved := ""
					if b.Entry.Moved != "" {
						moved = l.T("moved." + b.Entry.Moved)
					}
					rv.Entries = append(rv.Entries, entryView{
						Number: b.Number,
						Slug:   Slug(b.Entry.Name),
						Name:   b.Entry.Name,
						URL:    URL(b.Entry.Link, root),
						Reason: b.Entry.reason(l),
						Moved:  moved,
					})
				}
			}
			qv.Rings = append(qv.Rings, rv)
		}
		data.Quadrants = append(data.Quadrants, qv)
	}
	var buf bytes.Buffer
	if err := page.Execute(&buf, data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
