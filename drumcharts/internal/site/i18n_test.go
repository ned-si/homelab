package site

import (
	"maps"
	"regexp"
	"slices"
	"strings"
	"testing"
)

var placeholder = regexp.MustCompile(`\{[a-z]+\}`)

// TestCatalogue: both languages have the same keys and placeholders, none
// empty, no em dash and no "bot" (design, Language).
func TestCatalogue(t *testing.T) {
	en, fr := catalogue["en"], catalogue["fr"]
	if got := slices.Sorted(maps.Keys(catalogue)); !slices.Equal(got, []string{"en", "fr"}) {
		t.Errorf("catalogues %q, want en and fr", got)
	}
	for _, pair := range [][2]map[string]string{{en, fr}, {fr, en}} {
		for k := range pair[0] {
			if _, ok := pair[1][k]; !ok {
				t.Errorf("key %q is in one language only", k)
			}
		}
	}
	bot := regexp.MustCompile(`(?i)\bbots?\b`)
	for code, c := range catalogue {
		for k, v := range c {
			switch {
			case strings.TrimSpace(v) == "":
				t.Errorf("%s %q is empty", code, k)
			case strings.ContainsRune(v, '\u2014'):
				t.Errorf("%s %q holds an em dash", code, k)
			case bot.MatchString(v):
				t.Errorf("%s %q says bot: %q", code, k, v)
			}
			got := slices.Sorted(slices.Values(placeholder.FindAllString(v, -1)))
			want := slices.Sorted(slices.Values(placeholder.FindAllString(en[k], -1)))
			if !slices.Equal(got, want) {
				t.Errorf("%s %q has placeholders %q, English %q", code, k, got, want)
			}
		}
	}
}
