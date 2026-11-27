package site

import (
	"html/template"
	"maps"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

// catalogue holds every string the pages show, by language and key (design,
// Strings). {name} is a placeholder filled by fill. French follows
// docs/website.md, Translation conventions: U+00A0 before a colon, U+202F
// before a semicolon, *text* for an English expression.
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
		"home.updated.one":   "1 song, last updated {date}.",
		"home.updated.other": "{count} songs, last updated {date}.",
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
		"song.version":       "Version of {date}, release {release}.",
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
	"fr": { //nolint:gosec // G101: home.credits is the credits line, not a credential
		"home.title":         "Partitions de batterie · nedsi",
		"home.description":   "Les partitions de batterie de nedsi, à lire dans le navigateur ou à télécharger en PDF.",
		"home.heading":       "Partitions de batterie",
		"home.lead":          "Les morceaux que je joue, découpés par section.",
		"home.intro":         "Chaque partition suit la structure du morceau plutôt que chaque note\u00a0: une portée par section, le nombre de répétitions au-dessus, et une ligne de texte quand une partie revient. Une partition tient sur deux pages A4, côte à côte sur un pupitre\u202f; un long morceau en prend trois. Les têtes de notes sont expliquées dans la {legend}.",
		"home.legend_link":   "légende",
		"home.songs":         "Morceaux",
		"home.card_alt":      "Première page de {title} par {artist}",
		"home.pdf":           "PDF",
		"home.pdf_label":     "Télécharger le PDF de {title}",
		"home.updated.one":   "1 morceau, mis à jour le {date}.",
		"home.updated.other": "{count} morceaux, mis à jour le {date}.",
		"home.credits":       "Les partitions sont mes transcriptions des parties de batterie\u202f; les morceaux appartiennent à leurs auteurs. Le code source est sur {github}.",
		"home.github_link":   "GitHub",
		"song.title":         "{title}, {artist} · Partitions de batterie · nedsi",
		"song.description":   "Partition de batterie de {title} par {artist}, à lire dans le navigateur ou à télécharger en PDF.",
		"song.lead":          "{artist} · {pages}",
		"pages.one":          "1 page",
		"pages.other":        "{n} pages",
		"song.download":      "Télécharger le PDF",
		"song.all":           "Toutes les partitions",
		"song.legend":        "Légende",
		"song.page_alt":      "{title} par {artist}, page {n} sur {total}",
		"song.version":       "Version du {date}, *release* {release}.",
		"legend.title":       "Légende · Partitions de batterie · nedsi",
		"legend.description": "Ce que signifie chaque tête de note sur les partitions de batterie.",
		"legend.heading":     "Légende",
		"legend.lead":        "Ce que signifie chaque tête de note sur les partitions.",
		"legend.page_alt":    "La légende des partitions de batterie, page {n} sur {total}",
		"nav.home":           "Accueil",
		"nav.blog":           "Blog",
		"nav.homelab":        "Homelab",
		"nav.techradar":      "Tech radar",
		"nav.charts":         "Partitions",
		"nav.about":          "À propos",
		"prefs.light":        "Thème clair",
		"prefs.light_title":  "Thème clair, mémorisé dans un cookie",
		"prefs.dark":         "Thème sombre",
		"prefs.dark_title":   "Thème sombre",
		"footer.privacy":     "Confidentialité",
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

// emphasis is *text*, an English expression in the French text, as in the
// dashboard's catalogue (dashboard/internal/web/i18n.go).
var emphasis = regexp.MustCompile(`(^|[^\pL\pN*])\*([^\s*.][^*]*[^\s*]|[^\s*.])\*`)

// html escapes the message of key, sets each *text* in <em> and fills its
// placeholders with markup: each value is escaped text or built from
// escaped parts by the caller.
func (m messages) html(key string, a map[string]template.HTML) template.HTML {
	s := make(args, len(a))
	for k, v := range a {
		s[k] = string(v)
	}
	msg := emphasis.ReplaceAllString(template.HTMLEscapeString(m[key]), "${1}<em>${2}</em>")
	return template.HTML(fill(msg, s)) //nolint:gosec // G203: the message is escaped, only <em> is added, the values are markup the caller built
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

var frMonths = [12]string{"janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"}

// formatDate writes d as en-GB or fr-CH does: 26 November 2026, 26 novembre
// 2026; the 1st is "1er" in French, as on the dashboard.
func formatDate(code string, d time.Time) string {
	if code == "fr" {
		day := strconv.Itoa(d.Day())
		if d.Day() == 1 {
			day = "1er"
		}
		return day + " " + frMonths[d.Month()-1] + " " + strconv.Itoa(d.Year())
	}
	return strconv.Itoa(d.Day()) + " " + d.Format("January 2006")
}
