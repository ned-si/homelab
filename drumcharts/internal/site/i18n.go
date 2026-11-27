package site

import (
	"html/template"
	"maps"
	"slices"
	"strconv"
	"strings"
	"time"
)

// catalogue holds every string the pages show, by language and key (design,
// Strings). {name} is a placeholder filled by format.
var catalogue = map[string]map[string]string{
	"en": {
		"home.title":         "Drum charts · nedsi",
		"home.description":   "nedsi's drum charts, to read in the browser or download as PDF.",
		"home.heading":       "Drum charts",
		"home.lead":          "The songs I play, charted by section.",
		"home.intro":         "Each chart follows the structure of the song rather than every note: one staff per section, repeat counts above, and a line of text where a part comes back. A chart fits on two A4 pages, side by side on a music stand; a long song takes three. The note heads are explained in the {legend}.",
		"home.legend_link":   "legend",
		"home.songs":         "Songs",
		"home.card_alt":      "First page of {title} by {artist}",
		"home.pdf":           "PDF",
		"home.pdf_label":     "Download the PDF of {title}",
		"home.updated.one":   "1 song, from the release {release} of {date}.",
		"home.updated.other": "{count} songs, from the release {release} of {date}.",
		"home.credits":       "The charts are my transcriptions of the drum parts; the songs belong to their authors. The source is on {github}.",
		"home.github_link":   "GitHub",
		"song.title":         "{title}, {artist} · Drum charts · nedsi",
		"song.description":   "Drum chart of {title} by {artist}, to read in the browser or download as PDF.",
		"song.lead":          "{artist} · {pages}",
		"pages.one":          "1 page",
		"pages.other":        "{n} pages",
		"song.download":      "Download the PDF",
		"song.all":           "All charts",
		"song.legend":        "Legend",
		"song.page_alt":      "{title} by {artist}, page {n} of {total}",
		"legend.title":       "Legend · Drum charts · nedsi",
		"legend.description": "What each note head on the drum charts means.",
		"legend.heading":     "Legend",
		"legend.lead":        "What each note head on the charts means.",
		"legend.page_alt":    "The legend of the drum charts, page {n} of {total}",
		// The shared nav, preferences and footer, as on the other nedsi.io
		// sites (scripts/ci/site_markup.py).
		"nav.home":          "Home",
		"nav.blog":          "Blog",
		"nav.homelab":       "Homelab",
		"nav.techradar":     "Tech radar",
		"nav.charts":        "Charts",
		"nav.about":         "About",
		"prefs.light":       "Light theme",
		"prefs.light_title": "Light theme, remembered with a cookie",
		"prefs.dark":        "Dark theme",
		"prefs.dark_title":  "Dark theme",
		"footer.privacy":    "Privacy",
	},
}

// messages are one language of the catalogue.
type messages map[string]string

// args are the placeholder values of a message, by name.
type args map[string]string

// text fills the placeholders of key, for titles and attributes;
// html/template escapes the result.
func (m messages) text(key string, a args) string {
	return fill(m[key], a)
}

// html escapes the message of key and fills its placeholders with markup:
// each value is escaped text or built from escaped parts by the caller.
func (m messages) html(key string, a map[string]template.HTML) template.HTML {
	s := make(args, len(a))
	for k, v := range a {
		s[k] = string(v)
	}
	return template.HTML(fill(template.HTMLEscapeString(m[key]), s)) //nolint:gosec // G203: the message is escaped, the values are markup the caller built
}

// pages is "1 page" or "<n> pages".
func (m messages) pages(n int) string {
	return m.text(pluralKey("pages", n), args{"n": strconv.Itoa(n)})
}

func pluralKey(key string, n int) string {
	if n == 1 {
		return key + ".one"
	}
	return key + ".other"
}

func fill(msg string, a args) string {
	pairs := make([]string, 0, 2*len(a))
	for _, k := range slices.Sorted(maps.Keys(a)) {
		pairs = append(pairs, "{"+k+"}", a[k])
	}
	return strings.NewReplacer(pairs...).Replace(msg)
}

// formatDate writes d as en-GB does: 26 November 2026.
func formatDate(d time.Time) string {
	return strconv.Itoa(d.Day()) + " " + d.Format("January 2006")
}
