// Package radar validates the tech radar's entries, places their blips and
// renders the page (.kiro/specs/tech-radar/design.md).
package radar

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"go.yaml.in/yaml/v3"
)

// MaxReason is the longest reason, in characters.
const MaxReason = 140

// Category is a quadrant or a ring: its key in entries.yaml and its name on
// the page.
type Category struct {
	ID   string
	Name string
}

// Quadrants in legend order: top left, top right, bottom left, bottom right.
var Quadrants = []Category{
	{"techniques", "Techniques"},
	{"tools", "Tools and languages"},
	{"platform", "Platform"},
	{"infrastructure", "Infrastructure"},
}

// Rings from the centre out.
var Rings = []Category{
	{"adopt", "Adopt"},
	{"trial", "Trial"},
	{"assess", "Assess"},
	{"hold", "Hold"},
}

var moves = map[string]bool{"up": true, "down": true, "new": true}

// denied are terms the public pages never name: the download stack and
// security devices (public-website Requirement 4.1).
var denied = regexp.MustCompile(`(?i)\b(sonarr|radarr|lidarr|prowlarr|bazarr|recyclarr|qbittorrent|torrent|indexer|camera|nvr|frigate|scrypted|doorbell|alarm|lock)s?\b`)

var issueLink = regexp.MustCompile(`^#[0-9]+$`)

var nonSlug = regexp.MustCompile(`[^a-z0-9]+`)

// Entry is one item of entries.yaml.
type Entry struct {
	Name     string `yaml:"name"`
	Quadrant string `yaml:"quadrant"`
	Ring     string `yaml:"ring"`
	Reason   string `yaml:"reason"`
	ReasonFR string `yaml:"reason_fr"`
	Link     string `yaml:"link,omitempty"`
	Moved    string `yaml:"moved,omitempty"`
}

type file struct {
	Updated string  `yaml:"updated"`
	Entries []Entry `yaml:"entries"`
}

// Radar is a validated entries file, the entries in legend order.
type Radar struct {
	Updated time.Time
	Entries []Entry
}

// Parse decodes and validates entries.yaml. Links to repository paths are
// resolved against root. Every problem is reported, joined in one error.
func Parse(data []byte, root fs.StatFS) (*Radar, error) {
	dec := yaml.NewDecoder(bytes.NewReader(data))
	dec.KnownFields(true)
	var f file
	if err := dec.Decode(&f); err != nil {
		return nil, fmt.Errorf("entries: %w", err)
	}
	var errs []error
	updated, err := time.Parse(time.DateOnly, f.Updated)
	if err != nil {
		errs = append(errs, fmt.Errorf("updated %q: want YYYY-MM-DD", f.Updated))
	}
	if len(f.Entries) == 0 {
		errs = append(errs, errors.New("no entries"))
	}
	seen := map[string]bool{}
	for _, e := range f.Entries {
		// The legend anchor comes from the name, so it must be unique too.
		key := Slug(e.Name)
		if seen[key] && key != "" {
			errs = append(errs, fmt.Errorf("%q: duplicate name or anchor #entry-%s", e.Name, key))
		}
		seen[key] = true
		for _, err := range check(e, root) {
			errs = append(errs, fmt.Errorf("%q: %w", e.Name, err))
		}
	}
	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}
	entries := sortEntries(f.Entries)
	return &Radar{Updated: updated, Entries: entries}, nil
}

func check(e Entry, root fs.StatFS) []error {
	var errs []error
	if Slug(e.Name) == "" {
		errs = append(errs, errors.New("name without a letter or digit"))
	}
	if index(Quadrants, e.Quadrant) < 0 {
		errs = append(errs, fmt.Errorf("unknown quadrant %q", e.Quadrant))
	}
	if index(Rings, e.Ring) < 0 {
		errs = append(errs, fmt.Errorf("unknown ring %q", e.Ring))
	}
	if e.Moved != "" && !moves[e.Moved] {
		errs = append(errs, fmt.Errorf("unknown moved %q, want up, down or new", e.Moved))
	}
	errs = append(errs, checkReason("reason", e.Reason)...)
	errs = append(errs, checkReason("reason_fr", e.ReasonFR)...)
	if strings.ContainsRune(e.Reason, '\u2014') || strings.ContainsRune(e.ReasonFR, '\u2014') || strings.ContainsRune(e.Name, '\u2014') {
		errs = append(errs, errors.New("em dash"))
	}
	if m := denied.FindString(e.Name + " " + e.Reason + " " + e.ReasonFR); m != "" {
		errs = append(errs, fmt.Errorf("names %q, which the public pages never name", m))
	}
	if err := checkLink(e.Link, root); err != nil {
		errs = append(errs, err)
	}
	return errs
}

// checkReason holds reason and reason_fr to one line of at most MaxReason
// characters.
func checkReason(field, reason string) []error {
	switch {
	case strings.TrimSpace(reason) == "":
		return []error{errors.New("empty " + field)}
	case strings.ContainsAny(reason, "\r\n"):
		return []error{errors.New(field + " on more than one line")}
	case utf8.RuneCountInString(reason) > MaxReason:
		return []error{fmt.Errorf("%s of %d characters, want at most %d", field, utf8.RuneCountInString(reason), MaxReason)}
	}
	return nil
}

func checkLink(link string, root fs.StatFS) error {
	switch {
	case link == "":
		return nil
	case strings.HasPrefix(link, "#"):
		if !issueLink.MatchString(link) {
			return fmt.Errorf("link %q: an issue is #<number>", link)
		}
		return nil
	}
	p, _, _ := strings.Cut(link, "#")
	clean := strings.TrimSuffix(p, "/")
	if !fs.ValidPath(clean) || clean == "." {
		return fmt.Errorf("link %q: not a repository path", link)
	}
	if _, err := root.Stat(clean); err != nil {
		return fmt.Errorf("link %q: no such path in the repository", link)
	}
	return nil
}

// URL is where an entry's link points on GitHub, or "" without a link.
func URL(link string, root fs.StatFS) string {
	const repo = "https://github.com/ned-si/homelab/"
	if link == "" {
		return ""
	}
	if n, ok := strings.CutPrefix(link, "#"); ok {
		return repo + "issues/" + n
	}
	p, anchor, hasAnchor := strings.Cut(link, "#")
	clean := strings.TrimSuffix(p, "/")
	kind := "blob/main/"
	if info, err := root.Stat(clean); err == nil && info.IsDir() {
		kind = "tree/main/"
	}
	u := repo + kind + path.Clean(clean)
	if hasAnchor {
		u += "#" + anchor
	}
	return u
}

func index(cs []Category, id string) int {
	for i, c := range cs {
		if c.ID == id {
			return i
		}
	}
	return -1
}

func name(cs []Category, id string) string {
	if i := index(cs, id); i >= 0 {
		return cs[i].Name
	}
	return id
}

// sortEntries orders entries as the legend: quadrant, ring, then name.
func sortEntries(in []Entry) []Entry {
	out := append([]Entry(nil), in...)
	less := func(a, b Entry) int {
		if d := index(Quadrants, a.Quadrant) - index(Quadrants, b.Quadrant); d != 0 {
			return d
		}
		if d := index(Rings, a.Ring) - index(Rings, b.Ring); d != 0 {
			return d
		}
		return strings.Compare(strings.ToLower(a.Name), strings.ToLower(b.Name))
	}
	slices.SortStableFunc(out, less)
	return out
}

// RepoFS is the repository at root as a StatFS for Parse and URL.
func RepoFS(root string) (fs.StatFS, error) {
	r, err := os.OpenRoot(root)
	if err != nil {
		return nil, err
	}
	statFS, ok := r.FS().(fs.StatFS)
	if !ok {
		return nil, errors.New("repository root: no Stat")
	}
	return statFS, nil
}

// Slug is the entry's anchor in the legend, #entry-<slug>: "Gateway API"
// is "gateway-api".
func Slug(name string) string {
	return strings.Trim(nonSlug.ReplaceAllString(strings.ToLower(name), "-"), "-")
}

// label is the native tooltip of a blip: "12. Cilium (Platform, Adopt):
// <reason>", in l's language.
func label(n int, e Entry, l Lang) string {
	colon := ": "
	if l.Code == "fr" {
		colon = "\u00a0: "
	}
	return strconv.Itoa(n) + ". " + e.Name + " (" + l.T("quadrant."+e.Quadrant) + ", " + l.T("ring."+e.Ring) + ")" + colon + plain(e.reason(l))
}

// reason is the entry's reason in l's language.
func (e Entry) reason(l Lang) string {
	if l.Code == "fr" {
		return e.ReasonFR
	}
	return e.Reason
}
