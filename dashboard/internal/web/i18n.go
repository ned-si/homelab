package web

import (
	"fmt"
	"html"
	"html/template"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ned-si/homelab/dashboard/internal/snapshot"
)

// emphasis is *text*: an English expression in the French text, set in
// italics (the operator's rule, 2026-11-26). A mark inside a word or
// before a dot, as in *.lilalala.com, is not one.
var emphasis = regexp.MustCompile(`(^|[^\pL\pN*])\*([^\s*.][^*]*[^\s*]|[^\s*.])\*`)

// em escapes s, then sets each *text* in <em>; the templates print the
// catalogue's running text through it.
func em(s string) template.HTML {
	return template.HTML(emphasis.ReplaceAllString(html.EscapeString(s), "${1}<em>${2}</em>")) //nolint:gosec // G203: escaped first, only <em> is added.
}

// site is the page's origin, for the canonical and hreflang links.
const site = "https://homelab.nedsi.io"

// catalogue holds every string of the page in one language, keyed by name
// (.kiro/specs/site-theme-language/design.md#dashboard).
type catalogue map[string]string

// locale is one language of the page: English at /, French at /fr/.
type locale struct {
	Code string // the catalogue and hreflang: "en", "fr"
	Tag  string // <html lang>: "en-GB", "fr-CH"
	Path string // the page: "/", "/fr/"
	T    catalogue

	decimal string // the decimal mark
	group   string // between groups of three digits
	// tight goes before % and before a unit in its own span, which has no
	// margin in French (dashboard.css); spaced before a unit in running text.
	tight, spaced string
	// The month names, empty in English, which uses time.Format.
	months, shortMonths [12]string
}

var (
	english = &locale{Code: "en", Tag: "en-GB", Path: "/", T: catalogues["en"],
		decimal: ".", group: ",", spaced: " "}
	french = &locale{Code: "fr", Tag: "fr-CH", Path: "/fr/", T: catalogues["fr"],
		decimal: ",", group: "\u202f", tight: "\u202f", spaced: "\u202f",
		months: [12]string{"janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août",
			"septembre", "octobre", "novembre", "décembre"},
		shortMonths: [12]string{"janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août",
			"sept.", "oct.", "nov.", "déc."}}
)

// t is the string of key; a missing key fails TestCatalogue, so it returns
// the key rather than panic.
func (l *locale) t(key string) string {
	if s, ok := l.T[key]; ok {
		return s
	}
	return key
}

// f is the string of key with its %s filled in.
func (l *locale) f(key string, args ...any) string {
	return fmt.Sprintf(l.t(key), args...)
}

func (l *locale) fixed(v float64, decimals int) string {
	return strings.Replace(strconv.FormatFloat(v, 'f', decimals, 64), ".", l.decimal, 1)
}

// pct formats a percentage with two decimals, rounded once, half to even on
// an exact binary tie (homelab-dashboard design.md, "Rounding"); the status
// rules read the raw value.
func (l *locale) pct(v float64) string {
	return l.fixed(v, 2)
}

// percent is pct with the sign, for text, titles and aria-labels.
func (l *locale) percent(v float64) string {
	return l.pct(v) + l.tight + "%"
}

// thousands formats n with the group separator between groups of three
// digits.
func (l *locale) thousands(n int) string {
	s := strconv.Itoa(n)
	neg := n < 0
	if neg {
		s = s[1:]
	}
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + l.group + s[i:]
	}
	if neg {
		s = "-" + s
	}
	return s
}

// day is the day of the month as dates write it: "1er" in French.
func (l *locale) day(t time.Time) string {
	if l.Code == "fr" && t.Day() == 1 {
		return "1er"
	}
	return strconv.Itoa(t.Day())
}

// dayMonth is "17 November", "17 novembre".
func (l *locale) dayMonth(t time.Time) string {
	if l.Code == "en" {
		return t.Format("2 January")
	}
	return l.day(t) + " " + l.months[t.Month()-1]
}

// timeText is a time in Zurich: "20 November 2026, 17:00".
func (l *locale) timeText(t time.Time) string {
	t = t.In(snapshot.Zurich)
	if l.Code == "en" {
		return t.Format("2 January 2006, 15:04")
	}
	return l.dayMonth(t) + " " + strconv.Itoa(t.Year()) + ", " + t.Format("15:04")
}

// shortTime is a time in Zurich without the year: "20 Nov 16:40".
func (l *locale) shortTime(t time.Time) string {
	t = t.In(snapshot.Zurich)
	if l.Code == "en" {
		return t.Format("2 Jan 15:04")
	}
	return strconv.Itoa(t.Day()) + " " + l.shortMonths[t.Month()-1] + " " + t.Format("15:04")
}

// unit is a figure's unit as its span holds it.
func (l *locale) unit(key string) string {
	return l.tight + l.t(key)
}

// plural is the unit key one or many for n: French counts 0 and 1 as one.
func (l *locale) plural(n int, one, many string) string {
	if n == 1 || n == -1 || (l.Code == "fr" && n == 0) {
		return one
	}
	return many
}

// page is the URL of the page in l's language.
func (l *locale) page() string {
	return site + l.Path
}

// catalogues are the page's strings. English is the reference text; French
// follows design.md, "Translation": U+00A0 before a colon, U+202F before
// ; ! ? and %, and no em dash. %s are filled in by locale.f, in the same
// order in both languages.
var catalogues = map[string]catalogue{
	"en": {
		"title":            "Homelab",
		"title.notfound":   "Page not found",
		"meta.description": "The homelab in numbers: live availability, certificates, cluster, security and project figures.",

		"url.home":      "https://nedsi.io/",
		"url.blog":      "https://blog.nedsi.io/",
		"url.techradar": "https://techradar.nedsi.io/",
		"url.about":     "https://blog.nedsi.io/about/",
		"url.privacy":   "https://blog.nedsi.io/privacy/",
		"url.feed":      "https://blog.nedsi.io/index.xml",

		"nav.home":      "Home",
		"nav.blog":      "Blog",
		"nav.homelab":   "Homelab",
		"nav.techradar": "Tech radar",
		"nav.about":     "About",

		"theme.light":       "Light theme",
		"theme.light.title": "Light theme, remembered with a cookie",
		"theme.dark":        "Dark theme",
		"theme.dark.title":  "Dark theme",

		"footer.by":      "Articles by nedsi.",
		"footer.rss":     "RSS",
		"footer.privacy": "Privacy",

		"notfound.heading":   "Page not found",
		"notfound.before":    "This page does not exist. The ",
		"notfound.dashboard": "dashboard",
		"notfound.middle":    " has the figures, and the ",
		"notfound.blog":      "blog",
		"notfound.after":     " lists every article.",

		"intro":              "An over-engineered homelab, in numbers.",
		"intro.sla":          "SLA: 99.50% availability over a rolling 30 days per app.",
		"updated.before":     "Updated ",
		"updated.after":      " (Zurich time).",
		"livestale.before":   "Live figures from ",
		"livestale.after":    " (Zurich time): the collector has stopped pushing.",
		"nofigures":          "No figures yet: the collector has not pushed any.",
		"asof.before":        "As of ",
		"asof.after":         ".",
		"asof.stale.before":  "Figures from ",
		"asof.stale.after":   " (Zurich time): this card is not updating.",
		"availability":       "Availability",
		"availability.intro": "The rolling 30 days to now, measured by probes. The last bar is today so far.",
		"card.since":         "since",
		"card.budget":        "%s of the error budget left",
		"card.exhausted":     "Exhausted",

		"cluster":         "Cluster",
		"cluster.use":     "Nodes and NAS: utilisation, saturation, errors",
		"cluster.gateway": "Gateway, rolling 5 minutes: rate, errors, duration",
		"cluster.state":   "State",

		"project":               "Project, rolling 30 days",
		"project.intro":         "Every pull request merged into main is a deploy.",
		"dora":                  "DORA metrics",
		"dora.what.link":        "DORA",
		"dora.what.after":       ", short for DevOps Research and Assessment, is the research programme behind the State of DevOps reports. It sums up software delivery in four metrics: how often changes reach production (deployment frequency), how long a change takes to get there (lead time for changes), how often a change breaks something (change failure rate) and how quickly things are back to normal when it does (time to restore).",
		"dora.bands.before":     "Each metric falls in one of four bands, Elite, High, Medium or Low, taken from the performance clusters of ",
		"dora.bands.link":       "DORA's 2023 report",
		"dora.bands.after":      ". Of course, the metrics were made for teams, not for one person and a few agents, but they make a fair yardstick all the same.",
		"dora.overall":          "The overall level is the lowest of the four bands, so one weak metric is never averaged away.",
		"dora.rework.before":    "Rework rate counts the unplanned deploys: rollbacks, fix forwards, and ",
		"dora.rework.after":     " merges made during an incident or in the 24 hours after it, over all deploys. Rework rate, DORA's fifth metric since 2024, has no band here: the 2023 clusters these bands come from predate it.",
		"delivery":              "Renovate and CI",
		"runs":                  "Last CI runs on main",
		"supply":                "Supply chain",
		"slsa":                  "SLSA provenance",
		"slsa.before":           "The two images I build here, this dashboard and the site, are built on runners GitHub hosts, and GitHub signs a provenance for each: that makes ",
		"slsa.link":             "SLSA Build level 2",
		"slsa.after":            ". Kyverno checks both on every Pod that runs them. Level 3 needs the build moved into a reusable workflow, which is for later.",
		"scorecard":             "OpenSSF Scorecard",
		"scorecard.link":        "OpenSSF Scorecard",
		"scorecard.middle":      " grades the repository against a list of security practices, each check out of 10, every time something is merged into main. Here are the overall score and every check in alphabetical order, with Scorecard's own reason; a check that does not apply to the repository says so. A check is green from 7 out of 10, yellow from 4 and red below; a note under a check says why where Scorecard's reason is not enough. The details are in the ",
		"scorecard.report":      "full report",
		"scorecard.after":       ".",
		"security":              "Security",
		"security.intro":        "What the defences turned away, counted over the whole cluster: the rolling 24 h, the rolling 7 days, and the same 7 days in six-hour bars. The Gateway figures leave out our own probes and checks. The alerts page whoever has to act; this card only counts.",
		"certificates":          "Certificates",
		"certificates.intro":    "Days until the certificate on the public names expires. cert-manager renews it 30 days before.",
		"later":                 "Coming later",
		"later.solar":           "Solar production",
		"later.solar.text":      "What the solar panels produce over the day. Production only: what the house consumes stays private, as it says far too much about when we are home.",
		"later.home":            "Home automation",
		"later.home.text":       "A few figures from Home Assistant, once I have worked out which ones are both interesting and safe to share. Nothing that tells you whether anybody is in.",
		"unit.percent":          "%",
		"unit.day":              "day",
		"unit.days":             "days",
		"unit.d":                "d",
		"unit.h":                "h",
		"unit.min":              "min",
		"unit.s":                "s",
		"unit.per-second":       "per second",
		"unit.per-s":            "/s",
		"unit.ms":               "ms",
		"unit.apps":             "apps",
		"unit.pvcs":             "PVCs",
		"unit.nodes":            "nodes",
		"unit.deploys":          "deploys",
		"unit.out-of-10":        "/ 10",
		"unit.mib":              "MiB",
		"unit.gib":              "GiB",
		"unit.tib":              "TiB",
		"status.nodata":         "No data",
		"status.met":            "Met",
		"status.at-risk":        "At risk",
		"status.missed":         "Missed",
		"status.up":             "Up",
		"status.down":           "Down",
		"status.ready":          "Ready",
		"status.not-ready":      "Not ready",
		"status.valid":          "Valid",
		"status.renewal-late":   "Renewal late",
		"status.expiring":       "Expiring",
		"status.ok":             "OK",
		"status.warning":        "Warning",
		"status.critical":       "Critical",
		"status.success":        "Success",
		"status.failure":        "Failure",
		"status.cancelled":      "Cancelled",
		"status.other":          "Other",
		"status.none":           "None",
		"status.seen":           "Seen",
		"status.above-usual":    "Above usual",
		"status.usual":          "Usual",
		"status.verified":       "Verified",
		"status.not-verified":   "Not verified",
		"status.not-applicable": "Not applicable",
		"status.no-incident":    "No incident",
		"band.elite":            "Elite",
		"band.high":             "High",
		"band.medium":           "Medium",
		"band.low":              "Low",

		"databases":                     "Databases and backups",
		"databases.intro":               "Each PostgreSQL database is its own CloudNativePG cluster. Every change is archived to S3 within 5 minutes and every night adds a base backup, so a database can be restored to any moment of its recovery window. Every week each one is restored into a new cluster and its tables and rows are compared with the source.",
		"databases.engines":             "The apps that keep their database in SQLite, a file in the app's volume, are copied to S3 every night with restic. Most copies are taken while the app runs, and the weekly restore test checks the database files it covers. Valkey, Redis and ClickHouse hold queues, caches and telemetry that are rebuilt or expire, so they are not backed up.",
		"db.postgresql":                 "PostgreSQL",
		"db.wal":                        "WAL archiving",
		"db.base":                       "Base backups",
		"db.recovery":                   "Point-in-time recovery",
		"db.restore":                    "Restore tests",
		"db.fresh":                      "Backup freshness",
		"db.sqlite":                     "SQLite",
		"db.sqlite-backups":             "SQLite backups",
		"db.valkey":                     "Valkey and Redis",
		"db.clickhouse":                 "ClickHouse",
		"db.seen":                       "Seen in the rolling 24 h",
		"db.up":                         "%s up",
		"db.up.data":                    "%s up, %s of data",
		"db.wal.detail":                 "%s files archived, rolling 24 h",
		"db.base.detail":                "Nightly, each in the rolling 26 h",
		"db.base.oldest":                "Oldest %s ago",
		"db.recovery.detail":            "The shortest window of all databases",
		"db.restore.detail":             "Weekly, rolling 8 days",
		"db.restore.rows":               "%s rows compared",
		"db.restore.median":             "Median %s to a restored copy",
		"db.fresh.detail":               "Worst database, rolling 30 days, target %s",
		"db.sqlite-backups.detail":      "Nightly to S3, each in the rolling 26 h",
		"db.sqlite-backups.restore":     "%s passed the weekly restore test, rolling 8 days",
		"db.sqlite-backups.restore.one": "%s passed the weekly restore test, rolling 8 days",
		"db.valkey.note":                "In memory, not backed up",
		"db.clickhouse.note":            "Logs and traces expire, not backed up",
		"unit.app":                      "app",
		"unit.database":                 "database",
		"unit.databases":                "databases",
		"unit.instance":                 "instance",
		"unit.instances":                "instances",
		"unit.of":                       "of %s",
		"status.archiving":              "Archiving",
		"status.behind":                 "Behind",
		"status.failing":                "Failing",
		"status.fresh":                  "Fresh",
		"status.stale":                  "Stale",
		"status.failed":                 "Failed",
		"status.passed":                 "Passed",
		"status.overdue":                "Overdue",
		"check.note.branch-protection":  "On purpose: main takes only pull requests with signed commits and a green CI, and needs no approval, so Renovate and the agents merge without waiting for a person.",
		"check.note.code-review":        "On purpose: I run this alone and agents open the pull requests, so nobody else approves them. Green CI is the only gate.",
		"check.note.contributors":       "On purpose: one operator and a few agents, with no company or organisation behind the repository.",
		"check.note.signed-releases":    "The images are signed with cosign and carry SLSA Build L2 provenance. No GitHub releases on purpose: these are personal apps, not meant for others to download.",
		"use.cpu":                       "CPU",
		"use.memory":                    "Memory",
		"use.disk":                      "Disk",
		"use.cpu-pressure":              "CPU pressure",
		"use.memory-pressure":           "Memory pressure",
		"use.io-pressure":               "I/O pressure",
		"use.net-errors":                "Network errors",
		"use.nas":                       "NAS",
		"use.pool":                      "Pool",
		"use.unhealthy":                 "Unhealthy",
		"use.load":                      "Load per core",
		"use.device-errors":             "Device errors",
		"use.scrub-errors":              "Scrub errors",
		"red.requests":                  "Requests",
		"red.5xx":                       "5xx answers",
		"red.p95":                       "p95 duration",
		"state.argo":                    "Argo CD",
		"state.argo.detail":             "%s Synced, %s Healthy",
		"state.restarts":                "Restarts",
		"state.volumes":                 "Volumes",
		"state.volumes.detail":          "%s of %s, fullest %s",
		"state.nodes":                   "Nodes",
		"state.talos":                   "Talos",
		"state.kubernetes":              "Kubernetes",
		"rolling.24h":                   "Rolling 24 h",

		"dora.deploys":        "Deployment frequency",
		"dora.deploys.detail": "%s a day",
		"dora.lead":           "Lead time for changes",
		"dora.lead.median":    "Median",
		"dora.lead.detail":    "Median of %s changes",
		"dora.failure":        "Change failure rate",
		"dora.failure.detail": "%s failed changes",
		"dora.restore":        "Time to restore",
		"dora.restore.none":   "None",
		"dora.restore.detail": "Median of %s incidents",
		"dora.level":          "Overall level",
		"dora.rework":         "Rework rate",
		"dora.rework.detail":  "%s of %s deploys",
		"delivery.ci":         "Median CI run",
		"delivery.renovate":   "Opened by Renovate",

		"signal.share":        "%s, %s of %s %s",
		"signal.part":         "Of these, %s are %ss",
		"signal.week":         "Rolling 7 days: %s",
		"signal.week.share":   "%s (%s)",
		"signal.unattributed": "Another %s answered by the Gateway itself cannot be attributed.",
		"noun.requests":       "requests",
		"noun.sign-ins":       "sign-ins",

		"image.level":     "Build L%s",
		"image.builder":   "GitHub-hosted runner, %s on main",
		"scorecard.score": "Score",
		"scorecard.run":   "Scorecard run of %s",

		"chart.value":     "%s: %s",
		"chart.exhausted": "Error budget exhausted",
		"chart.budget":    "Error budget left",
		"chart.today":     "%s (today so far)",
		"chart.days":      "%s days: %s",
		"chart.met":       "%s met",
		"chart.at-risk":   "%s at risk",
		"chart.missed":    "%s missed",
		"chart.nodata":    "%s without data",
		"chart.span":      "%s to %s",
		"chart.spark":     "%s counts of six hours, highest %s",

		"app.immich":        "Immich",
		"app.mealie":        "Mealie",
		"app.paperless":     "Paperless-ngx",
		"app.plex":          "Plex",
		"app.syncthing":     "Syncthing",
		"app.keycloak":      "Keycloak",
		"app.observability": "Observability",
		"app.landing":       "Landing page",
		"app.blog":          "Blog",
		"app.homelab":       "Homelab dashboard",

		"signal.gateway_unknown":      "Unknown host or path",
		"signal.gateway_unknown.note": "Includes our own weekly security scan.",
		"signal.gateway_refused":      "Refused by an app",
		"signal.gateway_refused.note": "Includes our own weekly security scan.",
		"signal.gateway_method":       "Method not allowed (405)",
		"signal.gateway_method.note":  "Includes our own weekly security scan.",
		"signal.signin_failed":        "Failed sign-ins",
		"signal.blocked":              "Deployments blocked by policy",
		"signal.ingress_world":        "Ingress packets dropped from the internet",
		"signal.runtime_detections":   "Runtime detections",
	},
	"fr": {
		"title":            "Homelab",
		"title.notfound":   "Page introuvable",
		"meta.description": "Le homelab en chiffres\u00a0: disponibilité en direct, certificats, cluster, sécurité et chiffres du projet.",

		"url.home":      "https://nedsi.io/fr/",
		"url.blog":      "https://blog.nedsi.io/fr/",
		"url.techradar": "https://techradar.nedsi.io/fr/",
		"url.about":     "https://blog.nedsi.io/fr/about/",
		"url.privacy":   "https://blog.nedsi.io/fr/privacy/",
		"url.feed":      "https://blog.nedsi.io/fr/index.xml",

		"nav.home":      "Accueil",
		"nav.blog":      "Blog",
		"nav.homelab":   "Homelab",
		"nav.techradar": "Tech radar",
		"nav.about":     "À propos",

		"theme.light":       "Thème clair",
		"theme.light.title": "Thème clair, mémorisé dans un cookie",
		"theme.dark":        "Thème sombre",
		"theme.dark.title":  "Thème sombre",

		"footer.by":      "Articles de nedsi.",
		"footer.rss":     "RSS",
		"footer.privacy": "Confidentialité",

		"notfound.heading":   "Page introuvable",
		"notfound.before":    "Cette page n’existe pas. Le ",
		"notfound.dashboard": "tableau de bord",
		"notfound.middle":    " a les chiffres, et le ",
		"notfound.blog":      "blog",
		"notfound.after":     " liste tous les articles.",

		"intro":              "Un homelab surconçu, en chiffres.",
		"intro.sla":          "SLA\u00a0: 99,50\u202f% de disponibilité sur 30 jours glissants, par app.",
		"updated.before":     "Mis à jour le ",
		"updated.after":      " (heure de Zurich).",
		"livestale.before":   "Chiffres en direct du ",
		"livestale.after":    " (heure de Zurich)\u00a0: le collecteur n’envoie plus rien.",
		"nofigures":          "Pas encore de chiffres\u00a0: le collecteur n’en a envoyé aucun.",
		"asof.before":        "État au ",
		"asof.after":         ".",
		"asof.stale.before":  "Chiffres du ",
		"asof.stale.after":   " (heure de Zurich)\u00a0: cette carte n’est plus mise à jour.",
		"availability":       "Disponibilité",
		"availability.intro": "Les 30 derniers jours jusqu’à maintenant, mesurés par des sondes. La dernière barre est la journée en cours.",
		"card.since":         "depuis le",
		"card.budget":        "%s du budget d’erreur restant",
		"card.exhausted":     "Épuisé",

		"cluster":         "Cluster",
		"cluster.use":     "Nœuds et NAS\u00a0: utilisation, saturation, erreurs",
		"cluster.gateway": "Gateway, 5 minutes glissantes\u00a0: débit, erreurs, durée",
		"cluster.state":   "État",

		"project":               "Projet, 30 jours glissants",
		"project.intro":         "Chaque *pull request* mergée dans main est un déploiement.",
		"dora":                  "Métriques DORA",
		"dora.what.link":        "DORA",
		"dora.what.after":       ", pour DevOps Research and Assessment, est le programme de recherche derrière les rapports State of DevOps. Il résume la livraison logicielle en quatre métriques\u00a0: à quelle fréquence les changements arrivent en production (fréquence de déploiement), combien de temps un changement met pour y arriver (délai de livraison des changements), à quelle fréquence un changement casse quelque chose (taux d’échec des changements) et à quelle vitesse tout revient à la normale quand ça arrive (temps de rétablissement).",
		"dora.bands.before":     "Chaque métrique tombe dans l’une de quatre catégories, Élite, Élevé, Moyen ou Faible, tirées des groupes de performance du ",
		"dora.bands.link":       "rapport DORA 2023",
		"dora.bands.after":      ". Bien sûr, ces métriques ont été pensées pour des équipes, pas pour une personne et quelques agents, mais elles font quand même un bon étalon.",
		"dora.overall":          "Le niveau global est la plus basse des quatre catégories, pour qu’une métrique faible ne soit jamais noyée dans une moyenne.",
		"dora.rework.before":    "Le taux de reprise compte les déploiements imprévus\u00a0: *rollbacks*, *fix forwards* et *merges* ",
		"dora.rework.after":     " faits pendant un incident ou dans les 24 heures qui suivent, sur l’ensemble des déploiements. Le taux de reprise, cinquième métrique de DORA depuis 2024, n’a pas de catégorie ici\u00a0: les groupes de 2023 dont viennent ces catégories sont plus anciens.",
		"delivery":              "Renovate et CI",
		"runs":                  "Derniers *runs* de CI sur main",
		"supply":                "Chaîne d’approvisionnement",
		"slsa":                  "Provenance SLSA",
		"slsa.before":           "Les deux images que je construis ici, ce tableau de bord et le site, sont construites sur des *runners* hébergés par GitHub, et GitHub signe une provenance pour chacune\u00a0: cela donne le ",
		"slsa.link":             "SLSA Build level 2",
		"slsa.after":            ". Kyverno vérifie les deux sur chaque Pod qui les fait tourner. Le niveau 3 demande de déplacer le *build* dans un *workflow* réutilisable, ce sera pour plus tard.",
		"scorecard":             "OpenSSF Scorecard",
		"scorecard.link":        "OpenSSF Scorecard",
		"scorecard.middle":      " note le dépôt selon une liste de bonnes pratiques de sécurité, chaque contrôle sur 10, à chaque *merge* dans main. Voici le score global et chaque contrôle par ordre alphabétique, avec la raison donnée par Scorecard (en anglais)\u202f; un contrôle qui ne s’applique pas au dépôt le dit. Un contrôle est vert à partir de 7 sur 10, jaune à partir de 4 et rouge en dessous\u202f; une note sous un contrôle explique pourquoi quand la raison de Scorecard ne suffit pas. Les détails sont dans le ",
		"scorecard.report":      "rapport complet",
		"scorecard.after":       ".",
		"security":              "Sécurité",
		"security.intro":        "Ce que les défenses ont refoulé, compté sur tout le cluster\u00a0: les 24 dernières heures, les 7 derniers jours, et ces mêmes 7 jours en barres de six heures. Les chiffres de la Gateway excluent nos propres sondes et contrôles. Les alertes préviennent qui doit agir\u202f; cette carte se contente de compter.",
		"certificates":          "Certificats",
		"certificates.intro":    "Jours restants avant l’expiration du certificat des noms publics. cert-manager le renouvelle 30 jours avant.",
		"later":                 "Plus tard",
		"later.solar":           "Production solaire",
		"later.solar.text":      "Ce que les panneaux solaires produisent au fil de la journée. La production seulement\u00a0: ce que la maison consomme reste privé, car cela en dit beaucoup trop sur quand nous sommes à la maison.",
		"later.home":            "Domotique",
		"later.home.text":       "Quelques chiffres de Home Assistant, quand j’aurai trouvé lesquels sont à la fois intéressants et sans risque à partager. Rien qui dise si quelqu’un est là.",
		"unit.percent":          "%",
		"unit.day":              "jour",
		"unit.days":             "jours",
		"unit.d":                "j",
		"unit.h":                "h",
		"unit.min":              "min",
		"unit.s":                "s",
		"unit.per-second":       "par seconde",
		"unit.per-s":            "/s",
		"unit.ms":               "ms",
		"unit.apps":             "apps",
		"unit.pvcs":             "PVC",
		"unit.nodes":            "nœuds",
		"unit.deploys":          "déploiements",
		"unit.out-of-10":        "/ 10",
		"unit.mib":              "Mio",
		"unit.gib":              "Gio",
		"unit.tib":              "Tio",
		"status.nodata":         "Pas de données",
		"status.met":            "Atteint",
		"status.at-risk":        "À risque",
		"status.missed":         "Manqué",
		"status.up":             "En service",
		"status.down":           "En panne",
		"status.ready":          "Prêt",
		"status.not-ready":      "Pas prêt",
		"status.valid":          "Valide",
		"status.renewal-late":   "Renouvellement en retard",
		"status.expiring":       "Expire bientôt",
		"status.ok":             "OK",
		"status.warning":        "Attention",
		"status.critical":       "Critique",
		"status.success":        "Réussi",
		"status.failure":        "Échec",
		"status.cancelled":      "Annulé",
		"status.other":          "Autre",
		"status.none":           "Aucun",
		"status.seen":           "Vu",
		"status.above-usual":    "Plus que d’habitude",
		"status.usual":          "Habituel",
		"status.verified":       "Vérifiée",
		"status.not-verified":   "Non vérifiée",
		"status.not-applicable": "Non applicable",
		"status.no-incident":    "Aucun incident",
		"band.elite":            "Élite",
		"band.high":             "Élevé",
		"band.medium":           "Moyen",
		"band.low":              "Faible",

		"databases":                     "Bases de données et sauvegardes",
		"databases.intro":               "Chaque base PostgreSQL est son propre cluster CloudNativePG. Chaque changement est archivé sur S3 en moins de 5 minutes et chaque nuit ajoute une sauvegarde de base, si bien qu’une base peut être restaurée à n’importe quel moment de sa fenêtre de restauration. Chaque semaine, chacune est restaurée dans un nouveau cluster, et ses tables et ses lignes sont comparées à la source.",
		"databases.engines":             "Les apps qui gardent leur base dans SQLite, un fichier dans le volume de l’app, sont copiées vers S3 chaque nuit avec restic. La plupart des copies sont faites pendant que l’app tourne, et le test de restauration hebdomadaire vérifie les fichiers de base qu’il couvre. Valkey, Redis et ClickHouse contiennent des files d’attente, des caches et de la télémétrie qui se reconstruisent ou expirent, ils ne sont donc pas sauvegardés.",
		"db.postgresql":                 "PostgreSQL",
		"db.wal":                        "Archivage des WAL",
		"db.base":                       "Sauvegardes de base",
		"db.recovery":                   "Restauration à un instant donné",
		"db.restore":                    "Tests de restauration",
		"db.fresh":                      "Fraîcheur des sauvegardes",
		"db.sqlite":                     "SQLite",
		"db.sqlite-backups":             "Sauvegardes SQLite",
		"db.valkey":                     "Valkey et Redis",
		"db.clickhouse":                 "ClickHouse",
		"db.seen":                       "Vues sur les 24 h glissantes",
		"db.up":                         "%s en service",
		"db.up.data":                    "%s en service, %s de données",
		"db.wal.detail":                 "%s fichiers archivés, 24 h glissantes",
		"db.base.detail":                "Chaque nuit, chacune dans les 26 h glissantes",
		"db.base.oldest":                "La plus ancienne il y a %s",
		"db.recovery.detail":            "La fenêtre la plus courte de toutes les bases",
		"db.restore.detail":             "Chaque semaine, 8 jours glissants",
		"db.restore.rows":               "%s lignes comparées",
		"db.restore.median":             "Médiane de %s jusqu’à une copie restaurée",
		"db.fresh.detail":               "La moins bonne base, 30 jours glissants, objectif %s",
		"db.sqlite-backups.detail":      "Chaque nuit vers S3, chacune dans les 26 h glissantes",
		"db.sqlite-backups.restore":     "%s ont réussi le test de restauration hebdomadaire, 8 jours glissants",
		"db.sqlite-backups.restore.one": "%s a réussi le test de restauration hebdomadaire, 8 jours glissants",
		"db.valkey.note":                "En mémoire, sans sauvegarde",
		"db.clickhouse.note":            "Les logs et les traces expirent, sans sauvegarde",
		"unit.app":                      "app",
		"unit.database":                 "base",
		"unit.databases":                "bases",
		"unit.instance":                 "instance",
		"unit.instances":                "instances",
		"unit.of":                       "sur %s",
		"status.archiving":              "Archivage",
		"status.behind":                 "En retard",
		"status.failing":                "En échec",
		"status.fresh":                  "À jour",
		"status.stale":                  "Pas à jour",
		"status.failed":                 "Échec",
		"status.passed":                 "Réussi",
		"status.overdue":                "Hors délai",
		"check.note.branch-protection":  "Voulu\u00a0: main n’accepte que des pull requests aux commits signés et au CI vert, sans approbation, pour que Renovate et les agents fassent leurs merges sans attendre personne.",
		"check.note.code-review":        "Voulu\u00a0: je gère ça seul et des agents ouvrent les pull requests, donc personne d’autre ne les approuve. Le CI au vert est le seul contrôle.",
		"check.note.contributors":       "Voulu\u00a0: un opérateur et quelques agents, sans entreprise ni organisation derrière le dépôt.",
		"check.note.signed-releases":    "Les images sont signées avec cosign et ont une provenance SLSA Build L2. Pas de releases GitHub, c’est voulu\u00a0: ce sont des apps personnelles, pas faites pour être téléchargées par d’autres.",
		"use.cpu":                       "CPU",
		"use.memory":                    "Mémoire",
		"use.disk":                      "Disque",
		"use.cpu-pressure":              "Pression CPU",
		"use.memory-pressure":           "Pression mémoire",
		"use.io-pressure":               "Pression E/S",
		"use.net-errors":                "Erreurs réseau",
		"use.nas":                       "NAS",
		"use.pool":                      "Pool",
		"use.unhealthy":                 "Dégradé",
		"use.load":                      "Charge par cœur",
		"use.device-errors":             "Erreurs de disque",
		"use.scrub-errors":              "Erreurs de *scrub*",
		"red.requests":                  "Requêtes",
		"red.5xx":                       "Réponses 5xx",
		"red.p95":                       "Durée p95",
		"state.argo":                    "Argo CD",
		"state.argo.detail":             "%s Synced, %s Healthy",
		"state.restarts":                "Redémarrages",
		"state.volumes":                 "Volumes",
		"state.volumes.detail":          "%s sur %s, le plus plein à %s",
		"state.nodes":                   "Nœuds",
		"state.talos":                   "Talos",
		"state.kubernetes":              "Kubernetes",
		"rolling.24h":                   "24 h glissantes",

		"dora.deploys":        "Fréquence de déploiement",
		"dora.deploys.detail": "%s par jour",
		"dora.lead":           "Délai de livraison des changements",
		"dora.lead.median":    "Médiane",
		"dora.lead.detail":    "Médiane de %s changements",
		"dora.failure":        "Taux d’échec des changements",
		"dora.failure.detail": "%s changements en échec",
		"dora.restore":        "Temps de rétablissement",
		"dora.restore.none":   "Aucun",
		"dora.restore.detail": "Médiane de %s incidents",
		"dora.level":          "Niveau global",
		"dora.rework":         "Taux de reprise",
		"dora.rework.detail":  "%s sur %s déploiements",
		"delivery.ci":         "*Run* de CI médian",
		"delivery.renovate":   "Ouvertes par Renovate",

		"signal.share":        "%s, %s de %s %s",
		"signal.part":         "Dont %s réponses %s",
		"signal.week":         "7 jours glissants\u00a0: %s",
		"signal.week.share":   "%s (%s)",
		"signal.unattributed": "%s autres, auxquelles la Gateway a répondu elle-même, ne peuvent pas être attribuées.",
		"noun.requests":       "requêtes",
		"noun.sign-ins":       "connexions",

		"image.level":     "Build L%s",
		"image.builder":   "*Runner* hébergé par GitHub, %s sur main",
		"scorecard.score": "Score",
		"scorecard.run":   "Analyse Scorecard du %s",

		"chart.value":     "%s\u00a0: %s",
		"chart.exhausted": "Budget d’erreur épuisé",
		"chart.budget":    "Budget d’erreur restant",
		"chart.today":     "%s (journée en cours)",
		"chart.days":      "%s jours\u00a0: %s",
		"chart.met":       "%s atteints",
		"chart.at-risk":   "%s à risque",
		"chart.missed":    "%s manqués",
		"chart.nodata":    "%s sans données",
		"chart.span":      "Du %s au %s",
		"chart.spark":     "%s comptages de six heures, maximum %s",

		"app.immich":        "Immich",
		"app.mealie":        "Mealie",
		"app.paperless":     "Paperless-ngx",
		"app.plex":          "Plex",
		"app.syncthing":     "Syncthing",
		"app.keycloak":      "Keycloak",
		"app.observability": "Observabilité",
		"app.landing":       "Page d’accueil",
		"app.blog":          "Blog",
		"app.homelab":       "Tableau de bord du homelab",

		"signal.gateway_unknown":      "Hôte ou chemin inconnu",
		"signal.gateway_unknown.note": "Y compris notre propre *scan* de sécurité hebdomadaire.",
		"signal.gateway_refused":      "Refusées par une app",
		"signal.gateway_refused.note": "Y compris notre propre *scan* de sécurité hebdomadaire.",
		"signal.gateway_method":       "Méthode non autorisée (405)",
		"signal.gateway_method.note":  "Y compris notre propre *scan* de sécurité hebdomadaire.",
		"signal.signin_failed":        "Connexions échouées",
		"signal.blocked":              "Déploiements bloqués par une règle",
		"signal.ingress_world":        "Paquets entrants d’internet rejetés",
		"signal.runtime_detections":   "Détections à l’exécution",
	},
}
