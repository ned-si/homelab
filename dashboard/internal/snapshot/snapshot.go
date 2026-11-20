// Package snapshot defines snapshot.json, the public figures of the homelab
// dashboard: its types, its embedded JSON Schema, the compiled list of shown
// apps and the checks both roles run on every document
// (.kiro/specs/homelab-dashboard/design.md, "The snapshot").
package snapshot

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/santhosh-tekuri/jsonschema/v6"
	// The binary runs on a distroless base: Europe/Zurich must not depend
	// on the image's zoneinfo.
	_ "time/tzdata"
)

// Version is the schema version this package writes and accepts.
const Version = 1

// MaxSize is the largest snapshot body accepted, in bytes.
const MaxSize = 64 << 10

// DateLayout is the layout of daily.covers.
const DateLayout = "2006-01-02"

// Days is the number of daily availability values per app.
const Days = 30

// ErrNotShown marks a document that names an app outside the shown apps.
var ErrNotShown = errors.New("not the shown apps")

//go:embed snapshot.schema.json
var schemaJSON []byte

// Zurich is the time zone the days are counted in.
var Zurich = mustLoad("Europe/Zurich")

func mustLoad(name string) *time.Location {
	loc, err := time.LoadLocation(name)
	if err != nil {
		// time/tzdata is linked in, so this cannot fail at run time.
		panic(err)
	}
	return loc
}

// Snapshot is the document the collector signs and the web role serves.
type Snapshot struct {
	SchemaVersion int     `json:"schema_version"`
	GeneratedAt   string  `json:"generated_at"`
	Daily         Daily   `json:"daily"`
	Cluster       Cluster `json:"cluster"`
	Project       Project `json:"project"`
}

// Daily is the per-finished-day block: availability and error budget.
type Daily struct {
	Covers     string `json:"covers"`
	ComputedAt string `json:"computed_at"`
	Apps       []App  `json:"apps"`
}

// App is one shown app's availability over the 30 days to Daily.Covers.
type App struct {
	ID                      string     `json:"id"`
	Name                    string     `json:"name"`
	Availability30d         float64    `json:"availability_30d"`
	ErrorBudgetRemaining30d int        `json:"error_budget_remaining_30d"`
	AvailabilityDaily       []*float64 `json:"availability_daily"`
}

// Cluster is the live block of cluster facts.
type Cluster struct {
	AsOf              string `json:"as_of"`
	Nodes             int    `json:"nodes"`
	Apps              int    `json:"apps"`
	TalosVersion      string `json:"talos_version"`
	KubernetesVersion string `json:"kubernetes_version"`
}

// Project is the live block of repository figures over the last 30 days.
type Project struct {
	AsOf               string `json:"as_of"`
	PRsMerged30d       int    `json:"prs_merged_30d"`
	RenovateShare30d   int    `json:"renovate_share_30d"`
	CIMedianSeconds30d int    `json:"ci_median_seconds_30d"`
}

// FormatTime formats t as the snapshot's timestamps: RFC 3339, second
// precision, Zurich offset.
func FormatTime(t time.Time) string {
	return t.In(Zurich).Truncate(time.Second).Format(time.RFC3339)
}

// ParseTime parses a snapshot timestamp.
func ParseTime(s string) (time.Time, error) {
	return time.Parse(time.RFC3339, s)
}

// ParseDate parses daily.covers as midnight in Zurich.
func ParseDate(s string) (time.Time, error) {
	return time.ParseInLocation(DateLayout, s, Zurich)
}

// Day returns the Zurich midnight that starts the day t falls on.
func Day(t time.Time) time.Time {
	l := t.In(Zurich)
	return time.Date(l.Year(), l.Month(), l.Day(), 0, 0, 0, 0, Zurich)
}

// AddDays returns the Zurich midnight n days after the midnight day.
func AddDays(day time.Time, n int) time.Time {
	l := day.In(Zurich)
	return time.Date(l.Year(), l.Month(), l.Day()+n, 0, 0, 0, 0, Zurich)
}

var compiled = sync.OnceValues(func() (*jsonschema.Schema, error) {
	doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(schemaJSON))
	if err != nil {
		return nil, fmt.Errorf("read the schema: %w", err)
	}
	c := jsonschema.NewCompiler()
	if err := c.AddResource("snapshot.schema.json", doc); err != nil {
		return nil, fmt.Errorf("add the schema: %w", err)
	}
	return c.Compile("snapshot.schema.json")
})

// Validate parses body and checks it: the size, the schema, then the rules
// a schema cannot express (the shown apps in order, no hidden app, covers
// before the day it was computed, no block newer than generated_at). An
// error about the apps wraps ErrNotShown.
func Validate(body []byte) (*Snapshot, error) {
	if len(body) > MaxSize {
		return nil, fmt.Errorf("%d bytes, more than %d", len(body), MaxSize)
	}
	sch, err := compiled()
	if err != nil {
		return nil, err
	}
	inst, err := jsonschema.UnmarshalJSON(bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("parse: %w", err)
	}
	if err := sch.Validate(inst); err != nil {
		return nil, fmt.Errorf("schema: %w", err)
	}
	var s Snapshot
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&s); err != nil {
		return nil, fmt.Errorf("decode: %w", err)
	}
	if err := s.check(); err != nil {
		return nil, err
	}
	return &s, nil
}

func (s *Snapshot) check() error {
	var errs []error
	want := Shown()
	if len(s.Daily.Apps) != len(want) {
		errs = append(errs, fmt.Errorf("%w: daily.apps has %d apps, want %d", ErrNotShown, len(s.Daily.Apps), len(want)))
	}
	for i, a := range s.Daily.Apps {
		if Hidden(a.ID) {
			errs = append(errs, fmt.Errorf("%w: daily.apps[%d] %q is download or indexer tooling", ErrNotShown, i, a.ID))
		}
		if i < len(want) && (a.ID != want[i].ID || a.Name != want[i].Name) {
			errs = append(errs, fmt.Errorf("%w: daily.apps[%d] is %q (%q), want %q (%q)",
				ErrNotShown, i, a.ID, a.Name, want[i].ID, want[i].Name))
		}
	}
	generated, err := ParseTime(s.GeneratedAt)
	if err != nil {
		return errors.Join(append(errs, fmt.Errorf("generated_at: %w", err))...)
	}
	times := []struct{ name, value string }{
		{"daily.computed_at", s.Daily.ComputedAt},
		{"cluster.as_of", s.Cluster.AsOf},
		{"project.as_of", s.Project.AsOf},
	}
	for _, t := range times {
		v, err := ParseTime(t.value)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", t.name, err))
			continue
		}
		if v.After(generated) {
			errs = append(errs, fmt.Errorf("%s %s is after generated_at %s", t.name, t.value, s.GeneratedAt))
		}
	}
	covers, err := ParseDate(s.Daily.Covers)
	if err != nil {
		errs = append(errs, fmt.Errorf("daily.covers: %w", err))
	} else if computed, err := ParseTime(s.Daily.ComputedAt); err == nil && !covers.Before(Day(computed)) {
		errs = append(errs, fmt.Errorf("daily.covers %s is not before the day of daily.computed_at %s",
			s.Daily.Covers, s.Daily.ComputedAt))
	}
	return errors.Join(errs...)
}
