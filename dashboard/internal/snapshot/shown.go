package snapshot

import (
	"regexp"
	"slices"
	"strings"
)

// ShownApp is an app whose availability the public page shows.
type ShownApp struct {
	// ID is the stable key in the snapshot.
	ID string
	// Name is the label on the page.
	Name string
	// SLOApp is the value of the `app` label on the SLO recording rules.
	SLOApp string
}

// shown is compiled in, not configuration: adding an app is a reviewed,
// signed release, and the web role refuses a snapshot naming any other app.
var shown = []ShownApp{
	{ID: "immich", Name: "Immich", SLOApp: "media"},
	{ID: "mealie", Name: "Mealie", SLOApp: "cook"},
	{ID: "paperless", Name: "Paperless-ngx", SLOApp: "archive"},
	{ID: "jellyfin", Name: "Jellyfin", SLOApp: "cinema"},
	{ID: "syncthing", Name: "Syncthing", SLOApp: "syncthing"},
	{ID: "keycloak", Name: "Keycloak", SLOApp: "auth"},
	{ID: "landing", Name: "Landing page", SLOApp: "nedsi"},
	{ID: "blog", Name: "Blog", SLOApp: "blog"},
	{ID: "sonarr", Name: "Sonarr", SLOApp: "sonarr"},
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

// Hidden reports whether s names download or indexer tooling.
func Hidden(s string) bool {
	return hidden.MatchString(s) || strings.HasSuffix(s, "arr")
}
