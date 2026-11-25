package snapshot

import (
	"regexp"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"
)

// ShownApp is an app whose availability the public page shows.
type ShownApp struct {
	// ID is the stable key in the snapshot.
	ID string
	// Name is the label on the page.
	Name string
	// SLOApp is the value of the `app` label on the SLO recording rules.
	SLOApp string
	// ProbeApps are the `app` labels of the probes an SLO combines, public
	// or internal; empty for an SLO of the public probes of SLOApp alone.
	ProbeApps []string
}

// ShownCert is a certificate whose validity the public page shows.
type ShownCert struct {
	// ID is the stable key in the snapshot.
	ID string
	// Name is the label on the page.
	Name string
	// Instance matches the probe targets it covers: a regular expression,
	// escaped for a PromQL string.
	Instance string
}

// ShownSignal is a security signal the public page counts.
type ShownSignal struct {
	// ID is the stable key in the snapshot.
	ID string
	// Name is the label on the page: a category, never a rule or a place.
	Name string
	// ExpectedZero marks a signal where one event is worth a look; the
	// others are background noise judged against their usual level.
	ExpectedZero bool
	// Query is one PromQL sum over the whole cluster; Window replaces <w>
	// in it.
	Query string
	// Total is the count the share is of, TotalNoun its word on the page
	// ("requests"); empty for a signal without a share.
	Total, TotalNoun string
	// Part counts the share of Query named by PartNoun in the detail line
	// (the 403s of the refusals); empty for none.
	Part, PartNoun string
	// Note is a plain line under the tile, such as our own traffic the
	// Gateway cannot tell apart.
	Note string
}

// ShownImage is a first-party image whose build the public page shows.
type ShownImage struct {
	// Name is the repository under ghcr.io/ned-si and the label on the page.
	Name string
	// Workflow is the publishing workflow that builds, attests and signs it
	// on main.
	Workflow string
}

// Level is the SLSA v1.0 Build level of the first-party images: provenance
// made and signed by GitHub artefact attestations in the build job on a
// GitHub-hosted runner (design.md, "Which SLSA Build level").
const Level = 2

// Builder is the compiled builder text: the publishing workflows check that
// the provenance names this workflow and a GitHub-hosted runner.
func (i ShownImage) Builder() string {
	return "GitHub-hosted runner, " + i.Workflow + " on main"
}

// ImageSpec matches the image as a Pod spec pins it, for kube-state-metrics'
// image_spec label: escaped for a PromQL string.
func (i ShownImage) ImageSpec() string {
	return `ghcr\\.io/ned-si/` + i.Name + `(:[^@]+)?@sha256:[0-9a-f]{64}`
}

var shownImages = []ShownImage{
	{Name: "homelab-dashboard", Workflow: "dashboard-publish.yaml"},
	{Name: "homelab-site", Workflow: "site-publish.yaml"},
}

// scorecardChecks are the OpenSSF Scorecard checks a result may name
// (design.md, "Scorecard (task 24)"); any other name is dropped.
var scorecardChecks = []string{
	"Binary-Artifacts", "Branch-Protection", "CI-Tests", "CII-Best-Practices", "Code-Review",
	"Contributors", "Dangerous-Workflow", "Dependency-Update-Tool", "Fuzzing", "License",
	"Maintained", "Packaging", "Pinned-Dependencies", "SAST", "SBOM",
	"Security-Policy", "Signed-Releases", "Token-Permissions", "Vulnerabilities", "Webhooks",
}

// MaxReason is the longest Scorecard reason shown, in characters.
const MaxReason = 160

// ScorecardCheckShown reports whether name is a compiled Scorecard check.
func ScorecardCheckShown(name string) bool {
	return slices.Contains(scorecardChecks, name)
}

// PlainReason reports whether s is valid UTF-8 of at most MaxReason
// characters with no control character.
func PlainReason(s string) bool {
	return utf8.ValidString(s) && utf8.RuneCountInString(s) <= MaxReason &&
		!strings.ContainsFunc(s, unicode.IsControl)
}

// UnattributedSignal is the signal whose tile says how many 4xx the Gateway
// answered itself, which no tile counts.
const UnattributedSignal = "gateway_unknown"

// Window is the placeholder of a signal's query for its window.
const Window = "<w>"

// counter is the count of a counter's events in the window, summed over
// every series: a series absent at the window's start counts its whole
// value, which increase() alone would miss, as
// tetragon:policy_events:increase5m does.
func counter(selector string) string {
	return "sum((" + selector + " unless " + selector + " offset " + Window + ") or increase(" + selector + "[" + Window + "]))"
}

// orZero is 0 instead of nothing while source has a series: for a counter
// born with its first event, so a quiet signal reads 0 and a missing
// source "No data".
func orZero(source string) string {
	return " or on() (0 * sum(" + source + "))"
}

// Probes returns the `app` labels of the probes behind a's card.
func (a ShownApp) Probes() []string {
	if len(a.ProbeApps) == 0 {
		return []string{a.SLOApp}
	}
	return slices.Clone(a.ProbeApps)
}

// shown is compiled in, not configuration: adding an app is a reviewed,
// signed release, and the web role refuses a snapshot naming any other app.
var shown = []ShownApp{
	{ID: "immich", Name: "Immich", SLOApp: "media"},
	{ID: "mealie", Name: "Mealie", SLOApp: "cook"},
	{ID: "paperless", Name: "Paperless-ngx", SLOApp: "archive"},
	{ID: "plex", Name: "Plex", SLOApp: "watch"},
	{ID: "syncthing", Name: "Syncthing", SLOApp: "syncthing"},
	{ID: "keycloak", Name: "Keycloak", SLOApp: "auth"},
	{ID: "observability", Name: "Observability", SLOApp: "observability",
		ProbeApps: []string{"grafana", "signoz", "prometheus", "alertmanager"}},
	{ID: "landing", Name: "Landing page", SLOApp: "nedsi"},
	{ID: "blog", Name: "Blog", SLOApp: "blog"},
	{ID: "homelab", Name: "Homelab dashboard", SLOApp: "homelab"},
}

var shownCerts = []ShownCert{
	{ID: "lilalala", Name: "*.lilalala.com", Instance: `https://[^/]+\\.lilalala\\.com/.*`},
	{ID: "nedsi", Name: "nedsi.io", Instance: `https://(blog\\.)?nedsi\\.io/.*`},
	{ID: "homelab", Name: "homelab.nedsi.io", Instance: `https://homelab\\.nedsi\\.io/.*`},
}

// The Gateway's public listeners, its requests and our own traffic on them
// (design.md, "Security card figures").
const (
	listeners    = `envoy_http_conn_manager_prefix=~"listener-secure|listener-insecure"`
	upstream     = `envoy_cluster_upstream_rq{envoy_cluster_name=~"gateway/.+"`
	gatewayScan  = "Includes our own weekly security scan."
	publicReqs   = `envoy_http_downstream_rq_total{` + listeners + `}`
	staticSite   = `envoy_cluster_upstream_rq{envoy_cluster_name=~"gateway/.+/(website|homelab-dashboard)_.+", envoy_response_code="404"}`
	kyvernoDeny  = `apiserver_admission_webhook_rejection_count{name=~"i?vpol\\.validate\\.kyverno\\.svc.*", error_type="no_error"}`
	podSecDeny   = `pod_security_evaluations_total{decision="deny", mode="enforce"}`
	worldDropped = `hubble_drop_total{reason="POLICY_DENIED", source="reserved:world"}`
)

// UnattributedQuery is the Gateway's own 4xx in the window: the downstream
// 4xx less those without a route and those an app answered, at least 0.
var UnattributedQuery = "clamp_min(" +
	counter(`envoy_http_downstream_rq_xx{envoy_response_code_class="4", `+listeners+`}`) +
	" - " + counter(`envoy_http_no_route{`+listeners+`}`) +
	" - (" + counter(upstream+`, envoy_response_code=~"4.."}`) + orZero(publicReqs) + "), 0)"

// shownSignals are the signals of design.md, "Security card figures", in
// page order. Each sums its selectors away in PromQL, so no webhook,
// cluster, route or alert name reaches the snapshot. No brute-force lockout
// count: Keycloak locks existing accounts only, so it would name usernames.
var shownSignals = []ShownSignal{
	{ID: "gateway_unknown", Name: "Unknown host or path",
		Query: counter(`envoy_http_no_route{`+listeners+`}`) + " + (" + counter(staticSite) + orZero(publicReqs) + ")",
		Total: counter(publicReqs), TotalNoun: "requests", Note: gatewayScan},
	{ID: "gateway_refused", Name: "Refused by an app",
		Query: counter(upstream+`, envoy_response_code=~"401|403"}`) + orZero(publicReqs),
		Total: counter(publicReqs), TotalNoun: "requests",
		Part: counter(upstream+`, envoy_response_code="403"}`) + orZero(publicReqs), PartNoun: "403",
		Note: gatewayScan},
	{ID: "gateway_method", Name: "Method not allowed (405)",
		Query: counter(upstream+`, envoy_response_code="405"}`) + orZero(publicReqs),
		Total: counter(publicReqs), TotalNoun: "requests", Note: gatewayScan},
	{ID: "signin_failed", Name: "Failed sign-ins",
		Query: counter(`keycloak_user_events_total{event="login", error!=""}`),
		Total: counter(`keycloak_user_events_total{event="login"}`), TotalNoun: "sign-ins"},
	{ID: "blocked", Name: "Deployments blocked by policy", ExpectedZero: true,
		Query: "(" + counter(kyvernoDeny) + " or vector(0)) + (" + counter(podSecDeny) + " or vector(0))"},
	{ID: "ingress_world", Name: "Ingress packets dropped from the internet",
		Query: counter(worldDropped) + orZero("hubble_drop_total")},
	{ID: "runtime_detections", Name: "Runtime detections", ExpectedZero: true,
		Query: `count(max_over_time(ALERTS{alertname=~"Runtime.+", alertstate="firing"}[` + Window + `])) or vector(0)`},
}

// hidden and the "arr" suffix match the download and indexer tooling, as the
// publisher's pattern does: its uptime says when the downloads run, so it is
// never queried, written or rendered.
var hidden = regexp.MustCompile(`sonarr|radarr|lidarr|readarr|prowlarr|bazarr|recyclarr|lazylibrarian|` +
	`qbittorrent|torrent|jackett|flaresolverr|theater`)

// Shown returns the shown apps, in page order.
func Shown() []ShownApp {
	return slices.Clone(shown)
}

// ShownCerts returns the shown certificates, in page order.
func ShownCerts() []ShownCert {
	return slices.Clone(shownCerts)
}

// ShownSignals returns the security signals, in page order.
func ShownSignals() []ShownSignal {
	return slices.Clone(shownSignals)
}

// ShownImages returns the first-party images, in page order.
func ShownImages() []ShownImage {
	return slices.Clone(shownImages)
}

// Hidden reports whether s names download or indexer tooling.
func Hidden(s string) bool {
	return hidden.MatchString(s) || strings.HasSuffix(s, "arr")
}
