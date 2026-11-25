package radar

import (
	"bytes"
	"embed"
	"html/template"
	"io/fs"
	"strconv"
)

//go:embed assets
var assets embed.FS

var page = template.Must(template.ParseFS(assets, "assets/page.html"))

// Files are the rendered page's files by name, as served from the root of
// techradar.nedsi.io.
type Files map[string][]byte

type pageData struct {
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

var movedText = map[string]string{"up": "moved in", "down": "moved out", "new": "new"}

// Render places the blips and renders index.html with its stylesheets.
func Render(r *Radar, root fs.StatFS) (Files, error) {
	blips, err := Place(r.Entries)
	if err != nil {
		return nil, err
	}
	data := pageData{
		Updated:    strconv.Itoa(r.Updated.Day()) + " " + r.Updated.Format("January 2006"),
		UpdatedISO: r.Updated.Format("2006-01-02"),
		Count:      len(blips),
		// The SVG builder escapes every text it writes (svg.go).
		Chart: template.HTML(SVG(blips)), //nolint:gosec // G203: built from escaped text and numbers only
	}
	for _, q := range Quadrants {
		qv := quadrantView{ID: q.ID, Name: q.Name}
		for _, rg := range Rings {
			rv := ringView{ID: rg.ID, Name: rg.Name}
			for _, b := range blips {
				if b.Entry.Quadrant == q.ID && b.Entry.Ring == rg.ID {
					rv.Entries = append(rv.Entries, entryView{
						Number: b.Number,
						Slug:   Slug(b.Entry.Name),
						Name:   b.Entry.Name,
						URL:    URL(b.Entry.Link, root),
						Reason: b.Entry.Reason,
						Moved:  movedText[b.Entry.Moved],
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
	files := Files{"index.html": buf.Bytes()}
	for _, name := range []string{"techradar.css", "layout.css"} {
		b, err := assets.ReadFile("assets/" + name)
		if err != nil {
			return nil, err
		}
		files[name] = b
	}
	return files, nil
}
