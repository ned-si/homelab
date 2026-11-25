package radar

import (
	"fmt"
	"math"
	"os"
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"
)

// realEntries are the entries of techradar/entries.yaml.
func realEntries(t *testing.T) []Entry {
	t.Helper()
	root, err := RepoFS("../../..")
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile("../../entries.yaml")
	if err != nil {
		t.Fatal(err)
	}
	r, err := Parse(data, root)
	if err != nil {
		t.Fatalf("entries.yaml: %v", err)
	}
	return r.Entries
}

func synthetic(quadrant, ring string, n int) []Entry {
	var es []Entry
	for i := range n {
		es = append(es, Entry{Name: fmt.Sprintf("Entry %02d", i), Quadrant: quadrant, Ring: ring, Reason: "Test."})
	}
	return es
}

func TestPlace(t *testing.T) {
	tests := []struct {
		name    string
		entries func(*testing.T) []Entry
	}{
		{"entries.yaml", realEntries},
		{"30 in one Adopt segment", func(*testing.T) []Entry { return synthetic("platform", "adopt", 30) }},
		{"40 in one Hold segment", func(*testing.T) []Entry { return synthetic("infrastructure", "hold", 40) }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			entries := tt.entries(t)
			blips, err := Place(entries)
			if err != nil {
				t.Fatalf("Place: %v", err)
			}
			if len(blips) != len(entries) {
				t.Fatalf("%d blips for %d entries", len(blips), len(entries))
			}
			for i, a := range blips {
				if a.Number != i+1 {
					t.Errorf("blip %d numbered %d", i+1, a.Number)
				}
				q, r := index(Quadrants, a.Entry.Quadrant), index(Rings, a.Entry.Ring)
				if !Inside(a.X, a.Y, q, r) {
					t.Errorf("%q at (%v, %v) is outside %s/%s with its margins", a.Entry.Name, a.X, a.Y, a.Entry.Quadrant, a.Entry.Ring)
				}
				for _, b := range blips[i+1:] {
					if d := math.Hypot(a.X-b.X, a.Y-b.Y); d < MinDistance {
						t.Errorf("%q and %q are %.1f apart, want at least %d", a.Entry.Name, b.Entry.Name, d, MinDistance)
					}
				}
			}
			again, err := Place(entries)
			if err != nil {
				t.Fatalf("second Place: %v", err)
			}
			if diff := cmp.Diff(blips, again); diff != "" {
				t.Errorf("two runs differ (-first +second):\n%s", diff)
			}
		})
	}
}

func TestPlaceFull(t *testing.T) {
	_, err := Place(synthetic("techniques", "adopt", 200))
	if err == nil {
		t.Fatal("Place fitted 200 blips into one Adopt segment, want an error")
	}
	if want := "techniques/adopt: no room"; !strings.Contains(err.Error(), want) {
		t.Errorf("error %q, want it to name the segment (%q)", err, want)
	}
}
