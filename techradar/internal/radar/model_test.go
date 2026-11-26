package radar

import (
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/google/go-cmp/cmp"
)

var repo = fstest.MapFS{
	"docs/decisions.md":        {Data: []byte("# Decisions\n")},
	"docs/talos.md":            {Data: []byte("# Talos\n")},
	".kiro/specs/tech-radar/x": {Data: []byte("x")},
}

const clean = `updated: 2026-11-25
entries:
  - name: Talos Linux
    quadrant: infrastructure
    ring: adopt
    reason: Immutable, API-only nodes with the machine config in git.
    reason_fr: Des nodes immuables, pilotés par API.
    link: docs/talos.md
  - name: Service mesh
    quadrant: platform
    ring: hold
    reason: Cilium already gives the policies and the flows.
    reason_fr: Cilium fournit déjà les policies et les flux.
    link: "docs/decisions.md#no-service-mesh"
  - name: Wide events
    quadrant: techniques
    ring: assess
    reason: One rich event per request.
    reason_fr: Un événement riche par requête.
    link: "#734"
  - name: Go
    quadrant: tools
    ring: adopt
    reason: One static binary.
    reason_fr: Un binaire statique.
    link: .kiro/specs/tech-radar/
    moved: new
`

func TestParseClean(t *testing.T) {
	r, err := Parse([]byte(clean), repo)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if want := time.Date(2026, 11, 25, 0, 0, 0, 0, time.UTC); !r.Updated.Equal(want) {
		t.Errorf("Updated = %v, want %v", r.Updated, want)
	}
	var got []string
	for _, e := range r.Entries {
		got = append(got, e.Name)
	}
	want := []string{"Wide events", "Go", "Service mesh", "Talos Linux"}
	if diff := cmp.Diff(want, got); diff != "" {
		t.Errorf("legend order (-want +got):\n%s", diff)
	}
}

// entry is clean's first entry with one line replaced or added.
func entry(field, value string) string {
	lines := strings.Split(clean, "\n")
	head := lines[:8]
	out := []string{}
	replaced := false
	for _, l := range head {
		if strings.HasPrefix(strings.TrimLeft(l, " -"), field+":") {
			prefix := l[:strings.Index(l, field)]
			out = append(out, prefix+field+": "+value)
			replaced = true
			continue
		}
		out = append(out, l)
	}
	if !replaced {
		out = append(out, "    "+field+": "+value)
	}
	return strings.Join(out, "\n") + "\n"
}

func TestParseErrors(t *testing.T) {
	tests := []struct {
		name, yaml, want string
	}{
		{"unknown ring", entry("ring", "maybe"), `unknown ring "maybe"`},
		{"unknown quadrant", entry("quadrant", "languages"), `unknown quadrant "languages"`},
		{"unknown moved", entry("moved", "sideways"), `unknown moved "sideways"`},
		{"unknown key", entry("owner", "me"), "field owner not found"},
		{"duplicate name", clean + "  - name: talos linux\n    quadrant: infrastructure\n    ring: hold\n    reason: Again.\n", `"talos linux": duplicate name`},
		{"duplicate anchor", clean + "  - name: Talos-Linux\n    quadrant: infrastructure\n    ring: hold\n    reason: Again.\n", "duplicate name or anchor #entry-talos-linux"},
		{"name without an anchor", entry("name", `"++"`), "name without a letter or digit"},
		{"empty reason", entry("reason", `""`), "empty reason"},
		{"two-line reason", entry("reason", `"One line.\nTwo lines."`), "more than one line"},
		{"long reason", entry("reason", strings.Repeat("a", MaxReason+1)), "reason of 141 characters"},
		{"em dash", entry("reason", "Immutable \u2014 and API-only."), "em dash"},
		{"empty reason_fr", entry("reason_fr", `""`), "empty reason_fr"},
		{"long reason_fr", entry("reason_fr", strings.Repeat("a", MaxReason+1)), "reason_fr of 141 characters"},
		{"em dash in reason_fr", entry("reason_fr", "Immuable \u2014 et par API."), "em dash"},
		{"denied term in reason_fr", entry("reason_fr", "Pour les cameras."), `names "cameras"`},
		{"missing link path", entry("link", "docs/nope.md"), `link "docs/nope.md": no such path`},
		{"escaping link path", entry("link", "../etc/passwd"), "not a repository path"},
		{"issue not a number", entry("link", `"#12a"`), "an issue is #<number>"},
		{"download stack", entry("name", "Sonarr"), `names "Sonarr"`},
		{"security device", entry("reason", "Records the cameras."), `names "cameras"`},
		{"bad date", strings.Replace(clean, "2026-11-25", "25.11.2026", 1), `updated "25.11.2026"`},
		{"no entries", "updated: 2026-11-25\nentries: []\n", "no entries"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Parse([]byte(tt.yaml), repo)
			if err == nil {
				t.Fatalf("Parse succeeded, want an error containing %q", tt.want)
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Errorf("Parse error = %q, want it to contain %q", err, tt.want)
			}
		})
	}
}

func TestSlug(t *testing.T) {
	for name, want := range map[string]string{
		"Cilium":                 "cilium",
		"Gateway API":            "gateway-api",
		"C++ / Go (1.25)":        "c-go-1-25",
		" Trailing punctuation.": "trailing-punctuation",
	} {
		if got := Slug(name); got != want {
			t.Errorf("Slug(%q) = %q, want %q", name, got, want)
		}
	}
}

func TestURL(t *testing.T) {
	tests := []struct{ link, want string }{
		{"", ""},
		{"#734", "https://github.com/ned-si/homelab/issues/734"},
		{"docs/talos.md", "https://github.com/ned-si/homelab/blob/main/docs/talos.md"},
		{"docs/decisions.md#no-service-mesh", "https://github.com/ned-si/homelab/blob/main/docs/decisions.md#no-service-mesh"},
		{".kiro/specs/tech-radar/", "https://github.com/ned-si/homelab/tree/main/.kiro/specs/tech-radar"},
	}
	for _, tt := range tests {
		if got := URL(tt.link, repo); got != tt.want {
			t.Errorf("URL(%q) = %q, want %q", tt.link, got, tt.want)
		}
	}
}
