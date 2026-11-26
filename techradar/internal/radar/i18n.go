package radar

import (
	"strconv"
	"time"
)

// Lang is one language of the page: English at /, French at /fr/
// (.kiro/specs/site-theme-language/design.md#tech-radar).
type Lang struct {
	Code   string // the catalogue key and hreflang: "en", "fr"
	Locale string // <html lang>: "en-GB", "fr-CH"
	File   string // the rendered file: "index.html", "index-fr.html"
	Path   string // where nginx serves it: "/", "/fr/"
}

// Langs are the page's languages, English first.
var Langs = []Lang{
	{Code: "en", Locale: "en-GB", File: "index.html", Path: "/"},
	{Code: "fr", Locale: "fr-CH", File: "index-fr.html", Path: "/fr/"},
}

// T is the string of key in l's language; a missing key is a test failure
// (TestCatalogue), so it returns the key itself rather than panic.
func (l Lang) T(key string) string {
	if s, ok := catalogue[l.Code][key]; ok {
		return s
	}
	return key
}

// Date is d as the page prints it: "25 November 2026", "25 novembre 2026".
func (l Lang) Date(d time.Time) string {
	if l.Code == "fr" {
		return strconv.Itoa(d.Day()) + " " + frMonths[d.Month()-1] + " " + strconv.Itoa(d.Year())
	}
	return strconv.Itoa(d.Day()) + " " + d.Format("January 2006")
}

var frMonths = [12]string{"janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"}

// catalogue holds every string of the page per language. French follows
// the conventions of the design's Translation section: U+00A0 before a
// colon, U+202F before ; ! ? and %.
var catalogue = map[string]map[string]string{
	"en": {
		"title":                   "Tech radar · nedsi",
		"description":             "What the nedsi homelab uses, tries, assesses and holds, and why.",
		"url.home":                "https://nedsi.io/",
		"url.blog":                "https://blog.nedsi.io/",
		"url.homelab":             "https://homelab.nedsi.io/",
		"url.about":               "https://blog.nedsi.io/about/",
		"url.privacy":             "https://blog.nedsi.io/privacy/",
		"url.feed":                "https://blog.nedsi.io/index.xml",
		"nav.home":                "Home",
		"nav.blog":                "Blog",
		"nav.homelab":             "Homelab",
		"nav.techradar":           "Tech radar",
		"nav.about":               "About",
		"theme.light":             "Light theme",
		"theme.light.title":       "Light theme, remembered with a cookie",
		"theme.dark":              "Dark theme",
		"heading":                 "Tech radar",
		"lead":                    "What the homelab is built with, and why.",
		"intro.before":            "Every technology and technique the homelab uses, tries, keeps an eye on or decided against, each with a one-line reason and a link to where the decision is written down. Those reasons used to be spread over docs, specs and issues. Now they are on one page, in the spirit of ",
		"intro.link":              "Zalando's tech radar",
		"intro.after":             " (minus the JavaScript).",
		"ring.adopt":              "Adopt",
		"ring.trial":              "Trial",
		"ring.assess":             "Assess",
		"ring.hold":               "Hold",
		"ring.adopt.desc":         ": in use, and I would choose it again.",
		"ring.trial.desc":         ": in use on trial, or with a known limit I am working on.",
		"ring.assess.desc":        ": researched or planned, not in use yet.",
		"ring.hold.desc":          ": decided against, removed or replaced; the reason says why.",
		"quadrant.techniques":     "Techniques",
		"quadrant.tools":          "Tools and languages",
		"quadrant.platform":       "Platform",
		"quadrant.infrastructure": "Infrastructure",
		"updated":                 " entries, updated on ",
		"chart.hint":              ". The numbers on the chart match the legend below it; point at one for its name and ring, or follow it to its reason.",
		"chart.label":             "Tech radar: %d entries in four quadrants and four rings, listed in the legend below.",
		"none":                    "Nothing here right now.",
		"moved.up":                "moved in",
		"moved.down":              "moved out",
		"moved.new":               "new",
		"privacy":                 "Privacy",
	},
	"fr": {
		"title":                   "Radar techno · nedsi",
		"description":             "Ce que le homelab nedsi utilise, essaie, évalue et met de côté, et pourquoi.",
		"url.home":                "https://nedsi.io/fr/",
		"url.blog":                "https://blog.nedsi.io/fr/",
		"url.homelab":             "https://homelab.nedsi.io/",
		"url.about":               "https://blog.nedsi.io/fr/about/",
		"url.privacy":             "https://blog.nedsi.io/fr/privacy/",
		"url.feed":                "https://blog.nedsi.io/fr/index.xml",
		"nav.home":                "Accueil",
		"nav.blog":                "Blog",
		"nav.homelab":             "Homelab",
		"nav.techradar":           "Radar techno",
		"nav.about":               "À propos",
		"theme.light":             "Thème clair",
		"theme.light.title":       "Thème clair, mémorisé dans un cookie",
		"theme.dark":              "Thème sombre",
		"heading":                 "Radar techno",
		"lead":                    "Avec quoi le homelab est construit, et pourquoi.",
		"intro.before":            "Chaque technologie et chaque technique que le homelab utilise, essaie, surveille ou a écartée, chacune avec une raison en une ligne et un lien vers l'endroit où la décision est écrite. Ces raisons étaient éparpillées entre docs, specs et issues. Maintenant elles sont sur une seule page, dans l'esprit du ",
		"intro.link":              "tech radar de Zalando",
		"intro.after":             " (sans le JavaScript).",
		"ring.adopt":              "Adopter",
		"ring.trial":              "Essayer",
		"ring.assess":             "Évaluer",
		"ring.hold":               "Suspendre",
		"ring.adopt.desc":         "\u00a0: utilisé, et je le choisirais à nouveau.",
		"ring.trial.desc":         "\u00a0: utilisé à l'essai, ou avec une limite connue sur laquelle je travaille.",
		"ring.assess.desc":        "\u00a0: étudié ou prévu, pas encore utilisé.",
		"ring.hold.desc":          "\u00a0: écarté, retiré ou remplacé\u202f; la raison dit pourquoi.",
		"quadrant.techniques":     "Techniques",
		"quadrant.tools":          "Outils et langages",
		"quadrant.platform":       "Plateforme",
		"quadrant.infrastructure": "Infrastructure",
		"updated":                 " entrées, mises à jour le ",
		"chart.hint":              ". Les numéros du graphique correspondent à la légende en dessous\u202f; pointez-en un pour son nom et son anneau, ou suivez-le jusqu'à sa raison.",
		"chart.label":             "Radar techno\u00a0: %d entrées dans quatre quadrants et quatre anneaux, listées dans la légende en dessous.",
		"none":                    "Rien ici pour l'instant.",
		"moved.up":                "rapproché du centre",
		"moved.down":              "éloigné du centre",
		"moved.new":               "nouveau",
		"privacy":                 "Confidentialité",
	},
}
